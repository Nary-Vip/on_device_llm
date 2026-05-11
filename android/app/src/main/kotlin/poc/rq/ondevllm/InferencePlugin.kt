package poc.rq.ondevllm

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession.LlmInferenceSessionOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import okhttp3.OkHttpClient
import okhttp3.Request
import android.util.Log
import android.app.ActivityManager
import android.os.Build
import android.os.PowerManager
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.Contents

class InferencePlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL   = "com.poc.ondevicellm/inference"
        const val EVENT_CHANNEL    = "com.poc.ondevicellm/inference_stream"
        const val PROGRESS_CHANNEL = "com.poc.ondevicellm/model_progress"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var progressChannel: EventChannel
    private lateinit var context: Context

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inferenceDispatcher = Dispatchers.IO.limitedParallelism(1)
    private val mainHandler = Handler(Looper.getMainLooper())

    // LlmInference = engine (created once per model load)
    // LlmInferenceSession = per-conversation session (recreated each request)
    private var llmInference: LlmInference? = null
    private var session: LlmInferenceSession? = null
    private var liteRtEngine: Engine? = null

    private var activeRuntime: String = "mediapipe"

    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile private var progressSink: EventChannel.EventSink? = null

    // ─── FlutterPlugin ──────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        progressChannel = EventChannel(binding.binaryMessenger, PROGRESS_CHANNEL)
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                progressSink = sink
            }
            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        teardown()
    }

    // ─── MethodCallHandler ──────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize"      -> handleInitialize(call, result)
            "startGeneration" -> handleStartGeneration(call, result)
            "dispose"         -> { teardown(); result.success(null) }
            "getFreeRam"      -> handleGetFreeRam(result)
            "isLowMemory"     -> handleIsLowMemory(result)
            "getThermalStatus" -> handleGetThermalStatus(result)
            else              -> result.notImplemented()
        }
    }

    // ─── initialize ─────────────────────────────────────────────────────────

    private fun handleInitialize(call: MethodCall, result: MethodChannel.Result) {
        val modelId     = call.argument<String>("modelId")     ?: return result.error("ARGS", "modelId missing", null)
        val source      = call.argument<String>("source")      ?: "download"
        val downloadUrl = call.argument<String>("downloadUrl") ?: ""
        val hfToken = call.argument<String>("hf_token") ?: ""
        val runtime     = call.argument<String>("runtime")     ?: "mediapipe" 

        scope.launch {
            try {
                activeRuntime = runtime 
                val modelFile = resolveModel(modelId, source, downloadUrl, hfToken, runtime)
                when (runtime) {
                    "litert"    -> buildLiteRtEngine(modelFile.absolutePath)
                    else        -> buildMediaPipeEngine(modelFile.absolutePath)
                }
                withContext(Dispatchers.Main) { result.success(null) }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("INIT_FAILED", e.message, null)
                }
            }
        }
    }

    // ─── startGeneration ────────────────────────────────────────────────────

    private fun handleStartGeneration(call: MethodCall, result: MethodChannel.Result) {
        val prompt    = call.argument<String>("prompt")    ?: return result.error("ARGS", "prompt missing", null)
        val maxTokens = call.argument<Int>("maxTokens")    ?: 512

        result.success(null)

        scope.launch(inferenceDispatcher) {
            when (activeRuntime) {
                "litert" -> handleLiteRtGeneration(prompt)
                else     -> handleMediaPipeGeneration(prompt, maxTokens)
            }
        }
    }

    private fun handleMediaPipeGeneration(prompt: String, maxTokens: Int) {
        val engine = llmInference ?: run { sendError("MediaPipe engine not initialised"); return }
        try {
            session?.close()
            session = LlmInferenceSession.createFromOptions(
                engine,
                LlmInferenceSessionOptions.builder()
                    .setTopK(40)
                    .setTemperature(0.8f)
                    .setTopP(0.95f)
                    .setRandomSeed(42)
                    .build()
            )
            session!!.addQueryChunk(prompt)
            session!!.generateResponseAsync { partialResult: String, done: Boolean ->
                mainHandler.post {
                    eventSink?.success(mapOf("token" to partialResult, "done" to done))
                }
            }
        } catch (e: Exception) {
            sendError(e.message ?: "MediaPipe generation failed")
        }
    }

    private fun handleLiteRtGeneration(prompt: String) {
        val eng = liteRtEngine ?: run { sendError("LiteRT engine not initialised"); return }
        try {
            val latch = java.util.concurrent.CountDownLatch(1)
            eng.createConversation(
                ConversationConfig(
                    samplerConfig = SamplerConfig(topK = 40, topP = 0.95, temperature = 0.8)
                )
            ).use { conversation ->
                conversation.sendMessageAsync(
                    Message.of(prompt),
                    object : MessageCallback {
                        override fun onMessage(message: Message) {
                            val text = message.toString()
                            mainHandler.post {
                                eventSink?.success(mapOf("token" to text, "done" to false))
                            }
                        }
                        override fun onDone() {
                            mainHandler.post {
                                eventSink?.success(mapOf("token" to "", "done" to true))
                            }
                            latch.countDown()
                        }
                        override fun onError(throwable: Throwable) {
                            sendError(throwable.message ?: "LiteRT generation failed")
                            latch.countDown()
                        }
                    }
                )
                latch.await()
            }
        } catch (e: Exception) {
            sendError(e.message ?: "LiteRT generation failed")
        }
    }

    // ─── Model resolution ───────────────────────────────────────────────────

    private suspend fun resolveModel(
        modelId: String,
        source: String,
        downloadUrl: String,
        hfToken: String,
        runtime: String, 
    ): File = withContext(Dispatchers.IO) {
        val ext = if (runtime == "litert") "litertlm" else "task"
        val modelsDir = File(context.filesDir, "models").also { it.mkdirs() }
        val dest = File(modelsDir, "$modelId.$ext")

        if (dest.exists()) {
            sendProgress(1.0, "loading")
            return@withContext dest
        }

        when (source) {
            "bundle" -> {
                sendProgress(0.0, "downloading")
                context.assets.open("models/$modelId.task").use { inp ->
                    dest.outputStream().use { out -> inp.copyTo(out) }
                }
                sendProgress(1.0, "loading")
            }
            "download" -> {
                if (downloadUrl.isBlank()) {
                    throw IllegalArgumentException(
                        "downloadUrl required for source=download"
                    )
                }

                val tmp = File(modelsDir, "$modelId.$ext.tmp")

                val client = OkHttpClient.Builder()
                    .followRedirects(true)
                    .followSslRedirects(true)
                    .build()

                val request = Request.Builder()
                    .url(downloadUrl)
                    .addHeader("Authorization", "Bearer $hfToken")
                    .addHeader("User-Agent", "Mozilla/5.0")
                    .build()

                val response = client.newCall(request).execute()

                if (!response.isSuccessful) {
                    val errorBody = response.peekBody(Long.MAX_VALUE).string()
                    Log.e("HF_DEBUG", "HF ERROR CODE = ${response.code}")
                    Log.e("HF_DEBUG", "HF ERROR BODY = $errorBody")
                    throw Exception( "HTTP ${response.code} : $errorBody")
                }

                val body = response.body
                    ?: throw Exception("Empty response body")

                val total = body.contentLength()
                var downloaded = 0L

                try {
                    body.byteStream().use { inp ->
                        tmp.outputStream().use { out ->

                            val buf = ByteArray(8 * 1024)
                            var n: Int

                            while (inp.read(buf).also { n = it } != -1) {
                                out.write(buf, 0, n)
                                downloaded += n

                                if (total > 0) {
                                    sendProgress(
                                        downloaded.toDouble() / total,
                                        "downloading",
                                        downloaded,
                                        total
                                    )
                                }
                            }
                        }
                    }

                    if (!tmp.renameTo(dest)) {
                        throw Exception("Failed to move model file")
                    }

                    sendProgress(1.0, "loading")

                } catch (e: Exception) {
                    tmp.delete()
                    throw e
                }
            }

            else -> throw IllegalArgumentException("Unknown source: $source")
        }
        dest
    }

    // ─── Engine build ────────────────────────────────────────────────────────
    private suspend fun buildMediaPipeEngine(modelPath: String) = withContext(inferenceDispatcher) {
        session?.close(); session = null
        llmInference?.close()
        llmInference = LlmInference.createFromOptions(
            context,
            LlmInferenceOptions.builder()
                .setModelPath(modelPath)
                .setMaxTokens(1024)
                .setPreferredBackend(LlmInference.Backend.CPU)
                .build()
        )
    }

    private suspend fun buildLiteRtEngine(modelPath: String) = withContext(inferenceDispatcher) {
        liteRtEngine?.close()
        liteRtEngine = Engine(EngineConfig(modelPath = modelPath, backend = Backend.CPU()))
            .also { it.initialize() }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────
    private fun sendProgress(progress: Double, phase: String, downloadedBytes: Long = 0, totalBytes: Long = 0) {
        mainHandler.post {
            progressSink?.success(mapOf("progress" to progress, "phase" to phase, "downloadedBytes" to downloadedBytes, "totalBytes" to totalBytes))
        }
    }

    private fun sendError(message: String) {
        mainHandler.post {
            eventSink?.error("GENERATION_ERROR", message, null)
        }
    }

    private fun teardown() {
        scope.launch(inferenceDispatcher) {
            session?.close()
            session = null
            llmInference?.close()
            llmInference = null
            liteRtEngine?.close(); liteRtEngine = null
        }
    }

    private fun handleGetFreeRam(result: MethodChannel.Result) {
        try {
            val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memInfo = ActivityManager.MemoryInfo()
            activityManager.getMemoryInfo(memInfo)
            result.success(memInfo.availMem) 
        } catch (e: Exception) {
            result.error("RAM_ERROR", e.message, null)
        }
    }

    private fun handleIsLowMemory(result: MethodChannel.Result) {
        try {
            val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memInfo = ActivityManager.MemoryInfo()
            activityManager.getMemoryInfo(memInfo)
            result.success(memInfo.lowMemory)
        } catch (e: Exception) {
            result.error("RAM_ERROR", e.message, null)
        }
    }

    // ─── Thermal check ───────────────────────────────────────────────────────────
    private fun handleGetThermalStatus(result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {  // Android 10+
                val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(powerManager.currentThermalStatus)
            } else {
                result.success(0)
            }
        } catch (e: Exception) {
            result.error("THERMAL_ERROR", e.message, null)
        }
    }
}