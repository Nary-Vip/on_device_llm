// lib/engines/cloud_engine.dart

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/core/interface/inference_interface.dart';


class CloudEngine implements InferenceEngine {
  final String apiKey;
  final String model;

  static const _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  final _log = Logger();
  ModelStatus _status = ModelStatus.notLoaded;

  CloudEngine({
    required this.apiKey,
    this.model = 'gemini-2.0-flash',
  });

  @override
  InferenceBackend get backend => InferenceBackend.cloud;

  @override
  ModelStatus get status => _status;

  @override
  Future<void> initialize() async {
    _status = apiKey.isNotEmpty ? ModelStatus.ready : ModelStatus.failed;
    if (_status == ModelStatus.failed) {
      _log.e('CloudEngine: apiKey is empty — get a free key at aistudio.google.com');
    }
  }

  @override
  Future<void> dispose() async {
    _status = ModelStatus.notLoaded;
  }

  // ─── Streaming ─────────────────────────────────────────────────────────────

  @override
  Stream<TokenChunk> generateStream(String prompt, {int maxTokens = 512}) async* {
    if (_status != ModelStatus.ready) {
      yield TokenChunk('[Cloud engine not ready — check your API key]', isDone: true);
      return;
    }

    final uri = Uri.parse(
      '$_baseUrl/$model:streamGenerateContent?key=$apiKey&alt=sse',
    );

    final request = http.Request('POST', uri)
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt}
            ],
          }
        ],
        'generationConfig': {
          'maxOutputTokens': maxTokens,
          'temperature': 0.7,
        },
      });

    final client = http.Client();
    try {
      final response = await client.send(request);

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        _log.e('Gemini API error ${response.statusCode}: $body');
        yield TokenChunk('[API error ${response.statusCode}]', isDone: true);
        return;
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final chunk = _parseSseLine(line);
        if (chunk != null) {
          yield chunk;
          if (chunk.isDone) break;
        }
      }
    } catch (e) {
      _log.e('CloudEngine stream error: $e');
      yield TokenChunk('[Network error: $e]', isDone: true);
    } finally {
      client.close();
    }
  }

  // ─── Full result (used by benchmark) ───────────────────────────────────────

  @override
  Future<InferenceResult> generate(String prompt, {int maxTokens = 512}) async {
    final sw = Stopwatch()..start();
    Duration? ttft;
    final buffer = StringBuffer();
    int tokenCount = 0;

    await for (final chunk in generateStream(prompt, maxTokens: maxTokens)) {
      if (ttft == null && chunk.text.isNotEmpty) {
        ttft = sw.elapsed;
      }
      buffer.write(chunk.text);
      if (chunk.text.isNotEmpty) tokenCount++;
    }

    final elapsed = sw.elapsed;
    return InferenceResult(
      fullText: buffer.toString(),
      timeToFirstToken: ttft ?? elapsed,
      tokensPerSecond: tokenCount / elapsed.inSeconds.clamp(1, 99999),
      promptTokens: _estimateTokens(prompt),
      completionTokens: tokenCount,
      backend: InferenceBackend.cloud,
    );
  }

  // ─── SSE parsing ───────────────────────────────────────────────────────────

  // Gemini SSE format:
  //   data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},
  //          "finishReason":"STOP","index":0}],...}

  TokenChunk? _parseSseLine(String line) {
    if (!line.startsWith('data: ')) return null;
    final data = line.substring(6).trim();
    if (data.isEmpty || data == '[DONE]') return null;

    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final candidates = json['candidates'] as List<dynamic>?;
      if (candidates == null || candidates.isEmpty) return null;

      final candidate = candidates.first as Map<String, dynamic>;
      final content = candidate['content'] as Map<String, dynamic>?;
      final parts = content?['parts'] as List<dynamic>?;
      final text = (parts?.isNotEmpty == true)
          ? (parts!.first as Map<String, dynamic>)['text'] as String? ?? ''
          : '';

      final finishReason = candidate['finishReason'] as String?;
      final isDone = finishReason == 'STOP' ||
          finishReason == 'MAX_TOKENS' ||
          finishReason == 'SAFETY';

      return TokenChunk(text, isDone: isDone);
    } catch (e) {
      _log.t('SSE parse skip: $e  line: $line');
      return null;
    }
  }

  int _estimateTokens(String text) => (text.length / 4).round();
}