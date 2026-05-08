// The data that flows out of the model token by token
import 'package:on_dev_llm/core/enums.dart';

class TokenChunk {
  final String text;
  final bool isDone;

  const TokenChunk(this.text, {this.isDone = false});
}

// Full response with timing metadata — used by the benchmark harness
class InferenceResult {
  final String fullText;
  final Duration timeToFirstToken;
  final double tokensPerSecond;
  final int promptTokens;
  final int completionTokens;
  final InferenceBackend backend;

  const InferenceResult({
    required this.fullText,
    required this.timeToFirstToken,
    required this.tokensPerSecond,
    required this.promptTokens,
    required this.completionTokens,
    required this.backend,
  });
}

// The contract every backend must satisfy
abstract class InferenceEngine {
  InferenceBackend get backend;
  ModelStatus get status;

  // Load the model — call once at startup
  Future<void> initialize();

  // Clean up resources
  Future<void> dispose();

  // Stream tokens as they arrive (what the chat UI uses)
  Stream<TokenChunk> generateStream(String prompt, {int maxTokens = 512});

  // Collect the full stream + attach metrics (what the benchmark uses)
  Future<InferenceResult> generate(String prompt, {int maxTokens = 512});

  Future<bool> isModelDownloaded();

  Future<void> deleteModel();

  String get modelId;

  Future<int?> modelSizeBytes();
}