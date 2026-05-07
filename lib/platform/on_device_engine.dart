import 'dart:async';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/core/interface/inference_interface.dart';
import 'package:on_dev_llm/core/models/model_progress.dart';


class OnDeviceEngine implements InferenceEngine {
  // These names must exactly match what the Kotlin side registers
  static const _methodChannel = MethodChannel('com.poc.ondevicellm/inference');
  static const _eventChannel  = EventChannel('com.poc.ondevicellm/inference_stream');
  static const _progressChannel = EventChannel('com.poc.ondevicellm/model_progress');

  final _log = Logger();
  ModelStatus _status = ModelStatus.notLoaded;

  @override
  InferenceBackend get backend => InferenceBackend.onDevice;

  @override
  ModelStatus get status => _status;

  // ─── Initialize ────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    _status = ModelStatus.loading;
    try {
      await _methodChannel.invokeMethod<Map>('initialize', {
        'modelId'     : _modelId(),
        'source'      : 'download',
        'downloadUrl' : _downloadUrl(),
        'hf_token': '***REMOVED_HF_TOKEN***'
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
      'prompt'   : prompt,
      'maxTokens': maxTokens,
    });

    return _eventChannel
        .receiveBroadcastStream()
        .map((event) {
          if (event is! Map) return TokenChunk('', isDone: true);
          final text = event['token'] as String? ?? '';
          final done = event['done']  as bool?   ?? false;
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
      ttft ??= sw.elapsed;   // first token
      buffer.write(chunk.text);
      tokenCount++;
    }

    final elapsed = sw.elapsed;
    return InferenceResult(
      fullText          : buffer.toString(),
      timeToFirstToken  : ttft ?? elapsed,
      tokensPerSecond   : tokenCount / elapsed.inSeconds.clamp(1, 99999),
      promptTokens      : _estimateTokens(prompt),
      completionTokens  : tokenCount,
      backend           : InferenceBackend.onDevice,
    );
  }

  // ─── Dispose ───────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    await _methodChannel.invokeMethod('dispose');
    _status = ModelStatus.notLoaded;
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  String _modelId() => 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048';

  String _downloadUrl() =>
    'https://huggingface.co/litert-community/Gemma3-1B-IT'
    '/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task';

  // Rough token count — 1 token ≈ 4 characters
  int _estimateTokens(String text) => (text.length / 4).round();

  Stream<ModelProgress> get progressStream =>
    _progressChannel.receiveBroadcastStream().map((event) {
      if (event is! Map) return const ModelProgress(0, ModelPhase.downloading);
      return ModelProgress(
        (event['progress'] as num?)?.toDouble() ?? 0.0,
        event['phase'] == 'loading' ? ModelPhase.loading : ModelPhase.downloading,
      );
    });

}