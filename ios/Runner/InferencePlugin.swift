import Flutter
import Foundation
import MediaPipeTasksGenAI
import Darwin

#if canImport(FoundationModels)
import FoundationModels
#endif

private protocol OnDeviceBackend: Sendable  {
    func prewarm() async
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error>
    func close()
}

// ─── InferencePlugin ─────────────────────────────────────────────────────────
@MainActor
public class InferencePlugin: NSObject, FlutterPlugin {

    static let methodChannelName   = "com.poc.ondevicellm/inference"
    static let eventChannelName    = "com.poc.ondevicellm/inference_stream"
    static let progressChannelName = "com.poc.ondevicellm/model_progress"

    private var methodChannel:   FlutterMethodChannel?
    private var eventChannel:    FlutterEventChannel?
    private var progressChannel: FlutterEventChannel?

    private var tokenSink:    FlutterEventSink?
    private var progressSink: FlutterEventSink?

    // Active backend — either AppleIntelligenceBackend or MediaPipeBackend
    private var activeBackend: OnDeviceBackend?
    private var generationTask: Task<Void, Never>?
    private var progressDelegate: ProgressDelegate?
    private var isGenerating = false

    // ─── Registration ──────────────────────────────────────────────────────

    public static func register(with registrar: FlutterPluginRegistrar) {
        print("InferencePlugin registered")
        let instance = InferencePlugin()
        let messenger = registrar.messenger()

        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak instance] _ in
            // Log it — EngineRouter will re-check on next request automatically
            let state = ProcessInfo.processInfo.thermalState
            print("[InferencePlugin] Thermal state changed: \(state)")
        }

        instance.methodChannel = FlutterMethodChannel(
            name: methodChannelName, binaryMessenger: messenger)
        instance.methodChannel?.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }

        instance.eventChannel = FlutterEventChannel(
            name: eventChannelName, binaryMessenger: messenger)
        instance.eventChannel?.setStreamHandler(
            SinkHandler { instance.tokenSink = $0 })

        instance.progressChannel = FlutterEventChannel(
            name: progressChannelName, binaryMessenger: messenger)
        instance.progressChannel?.setStreamHandler(
            SinkHandler { instance.progressSink = $0 })
    }

    // ─── Method dispatch ───────────────────────────────────────────────────

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("Received method call: \(call.method)")
        switch call.method {
        case "initialize":      handleInitialize(call, result: result)
        case "startGeneration": handleStartGeneration(call, result: result)
        case "dispose":         teardown(); result(nil)
        case "getFreeRam":      result(getFreeRam())
        case "isLowMemory":     result(isLowMemory())
        case "getThermalStatus":result(getThermalStatus())
        default:                result(FlutterMethodNotImplemented)
        }
    }

    // ─── initialize ────────────────────────────────────────────────────────

    private func handleInitialize(_ call: FlutterMethodCall,
                                  result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "ARGS", message: "arguments missing", details: nil))
            return
        }

        let source      = args["source"]      as? String ?? "download"
        let downloadUrl = args["downloadUrl"] as? String ?? ""
        let hfToken     = args["hf_token"]    as? String ?? ""
        let modelId     = args["modelId"]     as? String ?? "gemma3-1b-it-int4"
        let modelPath   = args["modelPath"]   as? String ?? ""

        Task {
            // ── Tier 1: Apple Intelligence (iOS 26+) ──────────────────────
            if #available(iOS 26.0, *) {
                if let backend = await AppleIntelligenceBackend.makeIfAvailable() {
                    await backend.prewarm()
                    self.activeBackend = backend
                    self.sendProgress(1.0, phase: "loading")
                    await MainActor.run { result(nil) }
                    return
                }
                // Apple Intelligence not enabled/eligible — fall through
            }

            // ── Tier 2: MediaPipe + downloaded .task file ─────────────────
            do {
                let taskFile = try await resolveModel(
                    modelId: modelId,
                    source: source,
                    downloadUrl: downloadUrl,
                    hfToken: hfToken,
                    adbPath: modelPath
                )
                let backend = try MediaPipeBackend(modelPath: taskFile.path)
                self.activeBackend = backend
                self.sendProgress(1.0, phase: "loading")
                await MainActor.run { result(nil) }
            } catch {
                await MainActor.run {
                    result(FlutterError(
                        code: "INIT_FAILED",
                        message: error.localizedDescription,
                        details: nil))
                }
            }
        }
    }

    // ─── startGeneration ───────────────────────────────────────────────────

    private func handleStartGeneration(_ call: FlutterMethodCall,
                                    result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let prompt = args["prompt"] as? String else {
            result(FlutterError(code: "ARGS", message: "prompt missing", details: nil))
            return
        }
        guard let backend = activeBackend else {
            result(FlutterError(code: "NOT_READY",
                                message: "No backend initialised", details: nil))
            return
        }
        guard !isGenerating else {
            result(FlutterError(code: "BUSY",
                                message: "Generation already in progress",
                                details: nil))
            return
        }

        result(nil) // acknowledge immediately
        isGenerating = true
        generationTask?.cancel()
        generationTask = Task { [backend] in
            do {
                for try await partial in backend.streamResponse(to: prompt) {
                    guard !Task.isCancelled else { break }
                    sendToken(partial, done: false)
                }
                if !Task.isCancelled {
                    sendToken("", done: true)
                }
            } catch is CancellationError {
                // cancelled — no-op
            } catch {
                sendError("Generation failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                self.isGenerating = false
            }
        }
    }

    // ─── Model resolution ──────────────────────────────────────────────────
    // Mirrors Android's resolveModel — same sources, same progress events.

    private func resolveModel(
        modelId: String,
        source: String,
        downloadUrl: String,
        hfToken: String,
        adbPath: String
    ) async throws -> URL {
        let modelsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)

        try FileManager.default.createDirectory(
            at: modelsDir, withIntermediateDirectories: true)

        let dest = modelsDir.appendingPathComponent("\(modelId).task")

        if FileManager.default.fileExists(atPath: dest.path) {
            sendProgress(1.0, phase: "loading")
            return dest
        }

        switch source {

        case "adb":
            // Model placed manually — same as Android adb push but via
            // the simulator's file sharing or Xcode's device file transfer
            let manual = URL(fileURLWithPath: adbPath)
            guard FileManager.default.fileExists(atPath: manual.path) else {
                throw NSError(domain: "InferencePlugin", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Model not found at \(adbPath). Transfer via Xcode → Devices → App container."])
            }
            return manual

        case "download":
            guard !downloadUrl.isEmpty else {
                throw NSError(domain: "InferencePlugin", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "downloadUrl required"])
            }
            return try await downloadModel(
                from: downloadUrl,
                to: dest,
                hfToken: hfToken)

        case "bundle":
            guard let bundled = Bundle.main.url(
                forResource: modelId, withExtension: "task") else {
                throw NSError(domain: "InferencePlugin", code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Model \(modelId).task not found in bundle"])
            }
            return bundled

        default:
            throw NSError(domain: "InferencePlugin", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unknown source: \(source)"])
        }
    }

   private func downloadModel(
        from urlString: String,
        to dest: URL,
        hfToken: String
    ) async throws -> URL {

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)

        if !hfToken.isEmpty {
            request.setValue(
                "Bearer \(hfToken)",
                forHTTPHeaderField: "Authorization"
            )
        }

        request.setValue(
            "Mozilla/5.0",
            forHTTPHeaderField: "User-Agent"
        )

        return try await withCheckedThrowingContinuation {
            continuation in

            self.progressDelegate = ProgressDelegate(
                onProgress: { [weak self] progress, downloaded, total in
                    self?.sendProgress(
                        progress,
                        phase: "downloading",
                        downloadedBytes: downloaded,
                        totalBytes: total
                    )
                },
                onComplete: { [weak self] location, response, error in

                    if let error = error {
                        continuation.resume(throwing: error)
                        self?.progressDelegate = nil
                        return
                    }

                    guard
                        let location = location,
                        let http = response as? HTTPURLResponse
                    else {
                        self?.progressDelegate = nil
                        continuation.resume(
                            throwing: NSError(
                                domain: "InferencePlugin",
                                code: -1
                            )
                        )
                        return
                    }

                    guard http.statusCode == 200 else {
                        self?.progressDelegate = nil
                        continuation.resume(
                            throwing: NSError(
                                domain: "InferencePlugin",
                                code: http.statusCode,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "HTTP \(http.statusCode)"
                                ]
                            )
                        )
                        return
                    }

                    do {

                        if FileManager.default.fileExists(
                            atPath: dest.path
                        ) {
                            try FileManager.default.removeItem(
                                at: dest
                            )
                        }

                        try FileManager.default.moveItem(
                            at: location,
                            to: dest
                        )

                        self?.sendProgress(
                            1.0,
                            phase: "loading"
                        )

                        continuation.resume(
                            returning: dest
                        )
                        self?.progressDelegate = nil

                    } catch {
                        self?.progressDelegate = nil
                        continuation.resume(
                            throwing: error
                        )
                    }
                }
            )

            let session = URLSession(
                configuration: .default,
                delegate: self.progressDelegate,
                delegateQueue: nil
            )

            let task = session.downloadTask(with: request)

            task.resume()
        }
    }

    // ─── Teardown ──────────────────────────────────────────────────────────

    private func teardown() {
        generationTask?.cancel()
        // Don't nil activeBackend here — let the task observe cancellation first
        Task { @MainActor in
            await generationTask?.value   // wait for cooperative exit
            activeBackend?.close()
            activeBackend = nil
            generationTask = nil
        }
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    private func sendToken(_ text: String, done: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.tokenSink?(["token": text, "done": done])
        }
    }

    private func sendError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.tokenSink?(FlutterError(
                code: "GENERATION_ERROR", message: message, details: nil))
        }
    }

    private func sendProgress(_ value: Double, phase: String, downloadedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        DispatchQueue.main.async { [weak self] in
            self?.progressSink?(["progress": value, "phase": phase,
            "downloadedBytes" : downloadedBytes,
            "totalBytes"      : totalBytes
        ])
        }
    }

    private func getFreeRam() -> Int64 {
        var pagesize: vm_size_t = 0
        let hostPort = mach_host_self()
        host_page_size(hostPort, &pagesize)

        // vm_statistics_data_t gives system-wide page counts
        var vmStat = vm_statistics_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics_data_t>.size / MemoryLayout<integer_t>.size)

        let kr = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_VM_INFO, $0, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return 0 }

        // free_count = pages immediately available
        // inactive_count = pages holding old data, reclaimable under pressure
        let freePages     = Int64(vmStat.free_count)
        let inactivePages = Int64(vmStat.inactive_count)
        let pageBytes     = Int64(pagesize)

        return (freePages + inactivePages) * pageBytes
    }

    private func getMemoryPressureLevel() -> Int {
        var pagesize: vm_size_t = 0
        let hostPort = mach_host_self()
        host_page_size(hostPort, &pagesize)

        var vmStat = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let kr = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return 0 }

        let pageBytes      = UInt64(pagesize)
        let freeBytes      = UInt64(vmStat.free_count) * pageBytes
        let compressedBytes = UInt64(vmStat.compressor_page_count) * pageBytes
        let totalBytes     = UInt64(ProcessInfo.processInfo.physicalMemory)

        // Pressure ratio: how much is compressed + used vs total
        let usedRatio = 1.0 - (Double(freeBytes) / Double(totalBytes))
        let compressionRatio = Double(compressedBytes) / Double(totalBytes)

        if usedRatio > 0.90 || compressionRatio > 0.30 { return 2 }  // critical
        if usedRatio > 0.75 || compressionRatio > 0.15 { return 1 }  // warning
        return 0                                                        // normal
    }

    // ─── isLowMemory — uses pressure level now ────────────────────────────────────

    private func isLowMemory() -> Bool {
        return getMemoryPressureLevel() >= 1
    }

    private func getThermalStatus() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}

// ─── Tier 1 — Apple Intelligence backend ─────────────────────────────────────

@available(iOS 26.0, *)
private class AppleIntelligenceBackend: OnDeviceBackend {
    private let session: LanguageModelSession

    private init(session: LanguageModelSession) {
        self.session = session
    }

    /// Returns nil if Apple Intelligence is not available on this device.
    static func makeIfAvailable() async -> AppleIntelligenceBackend? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        return AppleIntelligenceBackend(session: LanguageModelSession())
    }

    func prewarm() async {
        session.prewarm()
    }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated func close() {}
}

// ─── Tier 2 — MediaPipe backend ───────────────────────────────────────────────

actor MediaPipeBackend: OnDeviceBackend {
    private let inference: LlmInference

    init(modelPath: String) throws {
        let options = LlmInference.Options(modelPath: modelPath)
        options.maxTokens = 1024
        self.inference = try LlmInference(options: options)
    }

    func prewarm() async {}

    // nonisolated so it satisfies the protocol without crossing isolation boundary.
    // The actor hop happens inside the Task via `await self.runInference(...)`.
    nonisolated func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let stream = await self.generateStream(for: prompt)
                    for try await partial in stream {
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // Actor-isolated helper — this is where LlmInference is safely called
    private func generateStream(for prompt: String) -> AsyncThrowingStream<String, Error> {
        inference.generateResponseAsync(inputText: prompt)
    }

    nonisolated func close() {}
}

// ─── Download progress delegate ───────────────────────────────────────────────

private class ProgressDelegate:
    NSObject,
    URLSessionDownloadDelegate {

    private let onProgress: (Double, Int64, Int64) -> Void  

    private let onComplete:
        (URL?, URLResponse?, Error?) -> Void

    init(
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (
            URL?,
            URLResponse?,
            Error?
        ) -> Void
    ) {

        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {

        guard totalBytesExpectedToWrite > 0 else {
            return
        }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress, totalBytesWritten, totalBytesExpectedToWrite) 
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {

        onComplete(
            location,
            downloadTask.response,
            nil
        )
    }

   func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {

        guard let error = error else {
            return
        }

        onComplete(
            nil,
            task.response,
            error
        )
    }
}

// ─── Reusable stream handler ──────────────────────────────────────────────────

private class SinkHandler: NSObject, FlutterStreamHandler {
    private let assign: (FlutterEventSink?) -> Void
    init(_ assign: @escaping (FlutterEventSink?) -> Void) { self.assign = assign }

    func onListen(withArguments _: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        assign(events); return nil
    }
    func onCancel(withArguments _: Any?) -> FlutterError? {
        assign(nil); return nil
    }
}
