import 'dart:async';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/core/interface/inference_interface.dart';
import 'package:on_dev_llm/core/models/model_progress.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class OnDeviceEngine implements InferenceEngine {
  // These names must exactly match what the Kotlin side registers
  static const _methodChannel = MethodChannel('com.poc.ondevicellm/inference');
  static const _eventChannel = EventChannel(
    'com.poc.ondevicellm/inference_stream',
  );
  static const _progressChannel = EventChannel(
    'com.poc.ondevicellm/model_progress',
  );

  final _log = Logger();
  ModelStatus _status = ModelStatus.notLoaded;

  @override
  InferenceBackend get backend => InferenceBackend.onDevice;

  @override
  ModelStatus get status => _status;

  OnDeviceRuntime _currentRuntime = OnDeviceRuntime.mediaPipe;

  OnDeviceRuntime get currentRuntime => _currentRuntime;

  // ─── Initialize ────────────────────────────────────────────────────────────

  @override
  Future<void> initialize({
    OnDeviceRuntime runtime = OnDeviceRuntime.mediaPipe,
  }) async {
    _status = ModelStatus.loading;
    _currentRuntime = runtime;
    try {
      await _methodChannel.invokeMethod<Map>('initialize', {
        'modelId': _modelIdFor(runtime),
        'source': 'download',
        'downloadUrl': _downloadUrlFor(runtime),
        'hf_token': '***REMOVED_HF_TOKEN***',
        'runtime': runtime == OnDeviceRuntime.litert ? 'litert' : 'mediapipe',
      });
      _status = ModelStatus.ready;
      _log.i('OnDeviceEngine: model ready');
    } on PlatformException catch (e) {
      _status = ModelStatus.failed;
      _log.e('OnDeviceEngine init failed: ${e.message}');
      rethrow;
    }
  }

  // ─── Streaming ─────────────────────────────────────────────────────────────

  @override
  Stream<TokenChunk> generateStream(String prompt, {int maxTokens = 512}) {
    // Tell native to start generating — fire and forget, tokens come
    // back through the EventChannel below
    _methodChannel.invokeMethod('startGeneration', {
      'prompt': prompt,
      'maxTokens': maxTokens,
    });

    return _eventChannel
        .receiveBroadcastStream()
        .map((event) {
          if (event is! Map) return TokenChunk('', isDone: true);
          final text = event['token'] as String? ?? '';
          final done = event['done'] as bool? ?? false;
          return TokenChunk(text, isDone: done);
        })
        .takeWhile((chunk) => !chunk.isDone);
  }

  // ─── Full result (used by benchmark) ───────────────────────────────────────

  @override
  Future<InferenceResult> generate(String prompt, {int maxTokens = 512}) async {
    final sw = Stopwatch()..start();
    Duration? ttft;
    final buffer = StringBuffer();
    int tokenCount = 0;

    await for (final chunk in generateStream(prompt, maxTokens: maxTokens)) {
      ttft ??= sw.elapsed; // first token
      buffer.write(chunk.text);
      tokenCount++;
    }

    final elapsed = sw.elapsed;
    return InferenceResult(
      fullText: buffer.toString(),
      timeToFirstToken: ttft ?? elapsed,
      tokensPerSecond: tokenCount / elapsed.inSeconds.clamp(1, 99999),
      promptTokens: _estimateTokens(prompt),
      completionTokens: tokenCount,
      backend: InferenceBackend.onDevice,
      modelId: modelId,
    );
  }

  // ─── Dispose ───────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    await _methodChannel.invokeMethod('dispose');
    _status = ModelStatus.notLoaded;
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  String _modelIdFor(OnDeviceRuntime runtime) =>
      runtime == OnDeviceRuntime.litert
      ? 'gemma-4-E2B-it'
      : 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048';

  @override
  String get modelId => _modelIdFor(_currentRuntime);

  String _downloadUrlFor(OnDeviceRuntime runtime) =>
      runtime == OnDeviceRuntime.litert
      ? 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm'
            '/resolve/main/gemma-4-E2B-it.litertlm'
      : 'https://huggingface.co/litert-community/Gemma3-1B-IT'
            '/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task';

  // Rough token count — 1 token ≈ 4 characters
  int _estimateTokens(String text) => (text.length / 4).round();

  Stream<ModelProgress> get progressStream =>
      _progressChannel.receiveBroadcastStream().map((event) {
        if (event is! Map) {
          return const ModelProgress(0, ModelPhase.downloading);
        }
        return ModelProgress(
          (event['progress'] as num?)?.toDouble() ?? 0.0,
          event['phase'] == 'loading'
              ? ModelPhase.loading
              : ModelPhase.downloading,
          downloadedBytes: (event['downloadedBytes'] as num?)?.toInt() ?? 0,
          totalBytes: (event['totalBytes'] as num?)?.toInt() ?? 0,
        );
      });

  Future<File> _modelFile(OnDeviceRuntime runtime) async {
    final Directory dir;
    if (Platform.isIOS) {
      dir = await getApplicationDocumentsDirectory();
    } else {
      dir = await getApplicationSupportDirectory();
    }
    final ext = runtime == OnDeviceRuntime.litert ? 'litertlm' : 'task';

    return File('${dir.path}/models/${_modelIdFor(runtime)}.$ext');
  }

  @override
  Future<bool> isModelDownloaded({OnDeviceRuntime? runtime}) async {
    final file = await _modelFile(runtime ?? _currentRuntime);
    return file.existsSync();
  }

  @override
  Future<void> deleteModel({OnDeviceRuntime? runtime}) async {
    final target = runtime ?? _currentRuntime;
    final file = await _modelFile(target);
    if (file.existsSync()) file.deleteSync();
    if (target == _currentRuntime) _status = ModelStatus.notLoaded;
  }

  @override
  Future<int?> modelSizeBytes({OnDeviceRuntime? runtime}) async {
    final file = await _modelFile(runtime ?? _currentRuntime);
    return file.existsSync() ? file.lengthSync() : null;
  }
}
