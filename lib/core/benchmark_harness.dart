import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/core/interface/inference_interface.dart';

class BenchmarkPrompt {
  final String id;
  final String label;
  final String prompt;
  final String category;

  final List<String> correctnessKeywords;

  final int expectedItemCount;

  final int? expectedMinWords;
  final int? expectedMaxWords;

  final int? maxSentences;

  const BenchmarkPrompt({
    required this.id,
    required this.label,
    required this.prompt,
    required this.category,
    this.correctnessKeywords = const [],
    this.expectedItemCount = 0,
    this.expectedMinWords,
    this.expectedMaxWords,
    this.maxSentences,
  });
}

class QualityScore {
  /// 0.0 – 1.0 overall quality score
  final double overall;

  /// null = not applicable for this prompt
  final bool? correct;

  /// 0.0 = no repetition, 1.0 = entirely repetitive
  final double repetitionRate;

  /// null = not applicable
  final bool? lengthCompliant;

  /// null = not applicable
  final bool? itemCountCompliant;

  /// null = not applicable
  final bool? instructionFollowed;

  /// Human-readable flags explaining score deductions
  final List<String> flags;

  const QualityScore({
    required this.overall,
    this.correct,
    required this.repetitionRate,
    this.lengthCompliant,
    this.itemCountCompliant,
    this.instructionFollowed,
    required this.flags,
  });

  String get grade {
    if (overall >= 0.90) return 'A';
    if (overall >= 0.75) return 'B';
    if (overall >= 0.55) return 'C';
    if (overall >= 0.35) return 'D';
    return 'F';
  }

  QualityGrade get gradeLevel {
    if (overall >= 0.90) return QualityGrade.excellent;
    if (overall >= 0.75) return QualityGrade.good;
    if (overall >= 0.55) return QualityGrade.fair;
    if (overall >= 0.35) return QualityGrade.poor;
    return QualityGrade.failing;
  }
}

enum QualityGrade { excellent, good, fair, poor, failing }

class QualityScorer {
  static QualityScore score(BenchmarkPrompt prompt, String output) {
    if (output.trim().isEmpty) {
      return const QualityScore(
        overall: 0.0,
        repetitionRate: 0.0,
        flags: ['Empty output'],
      );
    }

    final flags = <String>[];
    double penalty = 0.0;

    // 1. Correctness - Deducting 40% incase of missing keywords.
    bool? correct;
    if (prompt.correctnessKeywords.isNotEmpty) {
      final lower = output.toLowerCase();
      correct = prompt.correctnessKeywords
          .every((kw) => lower.contains(kw.toLowerCase()));
      if (!correct) {
        penalty += 0.40;
        final missing = prompt.correctnessKeywords
            .where((kw) => !lower.contains(kw.toLowerCase()))
            .join(', ');
        flags.add('Missing answer: $missing');
      }
    }

    // 2. Repetition rate (4-gram overlap)
    final repRate = _repetitionRate(output);
    if (repRate > 0.5) {
      penalty += 0.35;
      flags.add('Severe repetition (${(repRate * 100).round()}%)');
    } else if (repRate > 0.25) {
      penalty += 0.15;
      flags.add('Moderate repetition (${(repRate * 100).round()}%)');
    }

    // ── 3. Length compliance ───────────────────────────────────────────────
    bool? lengthOk;
    if (prompt.expectedMinWords != null || prompt.expectedMaxWords != null) {
      final wordCount = _wordCount(output);
      final min = prompt.expectedMinWords ?? 0;
      final max = prompt.expectedMaxWords ?? 999999;
      lengthOk = wordCount >= min && wordCount <= max;
      if (!lengthOk) {
        if (wordCount < min) {
          final shortfall = ((min - wordCount) / min * 100).round();
          penalty += 0.20;
          flags.add('Too short by ~$shortfall% ($wordCount words, expected $min–$max)');
        } else {
          penalty += 0.05;
          flags.add('Verbose ($wordCount words, expected ≤$max)');
        }
      }
    }

    // ── 4. List item count ────────────────────────────────────────────────
    bool? itemCountOk;
    if (prompt.expectedItemCount > 0) {
      final found = _countListItems(output);
      itemCountOk = found >= prompt.expectedItemCount;
      if (!itemCountOk) {
        penalty += 0.20;
        flags.add('Only $found / ${prompt.expectedItemCount} list items found');
      }
    }

    // ── 5. Instruction following (sentence limit) ─────────────────────────
    bool? instructionOk;
    if (prompt.maxSentences != null) {
      final sentCount = _sentenceCount(output);
      instructionOk = sentCount <= prompt.maxSentences!;
      if (!instructionOk) {
        penalty += 0.15;
        flags.add('Ignored sentence limit ($sentCount sentences found)');
      }
    }

    final overall = (1.0 - penalty).clamp(0.0, 1.0);
    return QualityScore(
      overall: overall,
      correct: correct,
      repetitionRate: repRate,
      lengthCompliant: lengthOk,
      itemCountCompliant: itemCountOk,
      instructionFollowed: instructionOk,
      flags: flags,
    );
  }

  // Helpers

  static double _repetitionRate(String text) {
    final words = text.toLowerCase().split(RegExp(r'\s+')).toList();
    if (words.length < 5) return 0.0;
    final ngrams = <String>[];
    for (var i = 0; i <= words.length - 4; i++) {
      ngrams.add('${words[i]} ${words[i+1]} ${words[i+2]} ${words[i+3]}');
    }
    final seen = <String>{};
    var dupes = 0;
    for (final ng in ngrams) {
      if (!seen.add(ng)) dupes++;
    }
    return dupes / ngrams.length;
  }

  static int _wordCount(String text) =>
      text.trim().split(RegExp(r'\s+')).length;

  static int _countListItems(String text) {
    var count = 0;
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (RegExp(r'^\d+[\.\)]').hasMatch(t) ||
          t.startsWith('- ') ||
          t.startsWith('* ') ||
          t.startsWith('• ')) {
        count++;
      }
    }
    return count;
  }

  static int _sentenceCount(String text) =>
      RegExp(r'[.!?]+\s').allMatches(text).length + 1;
}

// Result & Run

class BenchmarkResult {
  final BenchmarkPrompt prompt;
  final InferenceResult result;
  final QualityScore quality;
  final bool timedOut;
  final String? error;

  const BenchmarkResult({
    required this.prompt,
    required this.result,
    required this.quality,
    this.timedOut = false,
    this.error,
  });
}

class BenchmarkRun {
  final InferenceBackend backend;
  final List<BenchmarkResult> results;
  final DateTime startedAt;
  final Duration totalDuration;

  const BenchmarkRun({
    required this.backend,
    required this.results,
    required this.startedAt,
    required this.totalDuration,
  });

  double get avgTtftMs => results.isEmpty
      ? 0
      : results.map((r) => r.result.timeToFirstToken.inMilliseconds)
              .reduce((a, b) => a + b) /
          results.length;

  double get avgTps => results.isEmpty
      ? 0
      : results.map((r) => r.result.tokensPerSecond).reduce((a, b) => a + b) /
          results.length;

  int get totalTokens =>
      results.fold(0, (sum, r) => sum + r.result.completionTokens);

  double get avgQuality => results.isEmpty
      ? 0
      : results.map((r) => r.quality.overall).reduce((a, b) => a + b) /
          results.length;
}

// Prompts

const kBenchmarkPrompts = [
  BenchmarkPrompt(
    id: 'short_factual',
    label: 'Short factual',
    prompt: 'What is the capital of India? Answer in one sentence.',
    category: 'Short',
    correctnessKeywords: ['Delhi'],
    maxSentences: 2,
  ),
  BenchmarkPrompt(
    id: 'short_math',
    label: 'Simple math',
    prompt: 'What is 17 multiplied by 13? Show your working.',
    category: 'Short',
    correctnessKeywords: ['221'],
  ),
  BenchmarkPrompt(
    id: 'medium_explain',
    label: 'Explain concept',
    prompt:
        'Explain how a transformer neural network works in 3 concise paragraphs.',
    category: 'Medium',
    correctnessKeywords: ['attention', 'encoder'],
    expectedMinWords: 80,
    expectedMaxWords: 350,
  ),
  BenchmarkPrompt(
    id: 'medium_list',
    label: 'Structured list',
    prompt:
        'List 8 best practices for writing clean, maintainable Dart code with a one-sentence explanation for each.',
    category: 'Medium',
    expectedItemCount: 8,
    expectedMinWords: 80,
  ),
  BenchmarkPrompt(
    id: 'long_story',
    label: 'Creative writing',
    prompt:
        'Write a short story (around 200 words) about Rohit Sharma who was the successful captain in MI and Indians Team',
    category: 'Long',
    correctnessKeywords: ['mumbai indians', 'five', 'leader', 'calm'],
    expectedMinWords: 120,
    expectedMaxWords: 350,
  ),
];


class BenchmarkHarness {
  final InferenceEngine engine;
  final int maxTokens;
  final Duration timeout;

  BenchmarkHarness({
    required this.engine,
    this.maxTokens = 512,
    this.timeout = const Duration(seconds: 90),
  });

  Future<BenchmarkRun> run({
    List<BenchmarkPrompt>? prompts,
    void Function(int done, int total, BenchmarkResult latest)? onProgress,
  }) async {
    final suite = prompts ?? kBenchmarkPrompts;
    final results = <BenchmarkResult>[];
    final started = DateTime.now();

    for (var i = 0; i < suite.length; i++) {
      final p = suite[i];
      BenchmarkResult result;

      try {
        final inferenceResult = await engine
            .generate(p.prompt, maxTokens: maxTokens)
            .timeout(timeout);
        final quality = QualityScorer.score(p, inferenceResult.fullText);
        result = BenchmarkResult(
            prompt: p, result: inferenceResult, quality: quality);
      } catch (e) {
        final timedOut = e.toString().contains('TimeoutException');
        result = BenchmarkResult(
          prompt: p,
          result: InferenceResult(
            fullText: '',
            timeToFirstToken: timedOut ? timeout : Duration.zero,
            tokensPerSecond: 0,
            promptTokens: 0,
            completionTokens: 0,
            backend: engine.backend,
            modelId: engine.modelId
          ),
          quality: const QualityScore(
              overall: 0.0, repetitionRate: 0.0, flags: ['No output']),
          timedOut: timedOut,
          error: timedOut ? 'Timed out' : e.toString(),
        );
      }

      results.add(result);
      onProgress?.call(i + 1, suite.length, result);
    }

    return BenchmarkRun(
      backend: engine.backend,
      results: results,
      startedAt: started,
      totalDuration: DateTime.now().difference(started),
    );
  }
}