import 'package:on_dev_llm/core/engine_router.dart';
import 'package:on_dev_llm/core/interface/inference_interface.dart';

/// A single row in the benchmark results table.
class BenchmarkRow {
  final String prompt;
  final InferenceResult onDevice;
  final InferenceResult cloud;

  const BenchmarkRow({
    required this.prompt,
    required this.onDevice,
    required this.cloud,
  });

  /// Ratio: on-device tokens/sec ÷ cloud tokens/sec
  double get speedRatio => onDevice.tokensPerSecond / cloud.tokensPerSecond.clamp(0.01, 99999);

  /// Rough quality proxy: how close is the length? (A real harness would use ROUGE/BERTScore)
  double get lengthSimilarity {
    final a = onDevice.fullText.length;
    final b = cloud.fullText.length;
    if (b == 0) return 0;
    return (a / b).clamp(0.0, 2.0);
  }
}

class BenchmarkHarness {
  final EngineRouter router;

  /// Standard prompts that stress different capability dimensions.
  static const defaultPrompts = [
    // Factual recall
    'In one sentence, what is photosynthesis?',
    // Reasoning
    'If a train travels 60 km/h for 2.5 hours, how far does it go? Show your working.',
    // Instruction following
    'List exactly 3 benefits of regular exercise. Use a numbered list.',
    // Creative
    'Write a two-sentence micro-story about a lighthouse keeper.',
    // Long context stress
    'Summarize the key differences between REST and GraphQL in under 100 words.',
  ];

  BenchmarkHarness(this.router);

  /// Runs every prompt on both backends and returns one [BenchmarkRow] per prompt.
  Stream<BenchmarkRow> run({List<String>? prompts}) async* {
    final targets = prompts ?? defaultPrompts;
    for (final prompt in targets) {
      final onDeviceResult = await router.generate(
        prompt,
        maxTokens: 256,
        forceCloud: false,
      );
      final cloudResult = await router.generate(
        prompt,
        maxTokens: 256,
        forceCloud: true,
      );
      yield BenchmarkRow(
        prompt: prompt,
        onDevice: onDeviceResult,
        cloud: cloudResult,
      );
    }
  }
}