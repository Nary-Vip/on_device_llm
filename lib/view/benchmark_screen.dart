// lib/view/benchmark_screen.dart

import 'package:flutter/material.dart';
import 'package:on_dev_llm/core/app_scope.dart';
import 'package:on_dev_llm/core/benchmark_harness.dart';
import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/core/interface/inference_interface.dart';

// ─── Screen ───────────────────────────────────────────────────────────────────

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen>
    with TickerProviderStateMixin {
  _RunState _state = _RunState.idle;
  InferenceBackend _selectedBackend = InferenceBackend.onDevice;

  int _doneCount = 0;
  final int _total = kBenchmarkPrompts.length;
  BenchmarkResult? _latestResult;

  final Map<InferenceBackend, BenchmarkRun> _runs = {};

  late AnimationController _pulseCtrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  InferenceEngine _engineFor(InferenceBackend b) {
    final scope = AppScope.of(context);
    return b == InferenceBackend.onDevice ? scope.onDevice : scope.cloud;
  }

  Future<void> _startRun() async {
    if (_state == _RunState.running) return;
    setState(() {
      _state = _RunState.running;
      _doneCount = 0;
      _latestResult = null;
    });
    final harness = BenchmarkHarness(engine: _engineFor(_selectedBackend));
    final run = await harness.run(
      onProgress: (done, total, latest) {
        if (mounted) setState(() { _doneCount = done; _latestResult = latest; });
      },
    );
    if (mounted) setState(() { _runs[_selectedBackend] = run; _state = _RunState.done; });
  }

  Future<void> _runBoth() async {
    if (_state == _RunState.running) return;
    for (final b in [InferenceBackend.onDevice, InferenceBackend.cloud]) {
      setState(() {
        _selectedBackend = b;
        _state = _RunState.running;
        _doneCount = 0;
        _latestResult = null;
      });
      final harness = BenchmarkHarness(engine: _engineFor(b));
      final run = await harness.run(
        onProgress: (done, total, latest) {
          if (mounted) setState(() { _doneCount = done; _latestResult = latest; });
        },
      );
      if (mounted) setState(() => _runs[b] = run);
    }
    if (mounted) setState(() => _state = _RunState.done);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final onDeviceReady =
        AppScope.of(context).onDevice.status == ModelStatus.ready;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text('Benchmark'),
        centerTitle: false,
        actions: [
          if (_state != _RunState.running && onDeviceReady)
            TextButton.icon(
              onPressed: _runBoth,
              icon: const Icon(Icons.compare_arrows_rounded, size: 18),
              label: const Text('Run both'),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // Config
          SliverToBoxAdapter(
            child: _ConfigCard(
              cloudModel: scope.cloud.modelId,
              onDeviceModel: scope.onDevice.modelId,
              selected: _selectedBackend,
              onDeviceReady: onDeviceReady,
              running: _state == _RunState.running,
              onSelect: (b) => setState(() => _selectedBackend = b),
              onRun: _startRun,
            ),
          ),

          // Live progress
          if (_state == _RunState.running)
            SliverToBoxAdapter(
              child: _ProgressCard(
                done: _doneCount,
                total: _total,
                latest: _latestResult,
                pulse: _pulse,
                backend: _selectedBackend,
              ),
            ),

          // Results
          if (_runs.isNotEmpty) ...[
            SliverToBoxAdapter(child: _SummaryRow(runs: _runs)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'PER-PROMPT RESULTS',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.4),
                        letterSpacing: 1.2,
                      ),
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final p = kBenchmarkPrompts[i];
                  final od = _runs[InferenceBackend.onDevice]
                      ?.results
                      .where((r) => r.prompt.id == p.id)
                      .firstOrNull;
                  final cl = _runs[InferenceBackend.cloud]
                      ?.results
                      .where((r) => r.prompt.id == p.id)
                      .firstOrNull;
                  return _PromptResultRow(
                      prompt: p, onDevice: od, cloud: cl);
                },
                childCount: kBenchmarkPrompts.length,
              ),
            ),
          ],

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}

enum _RunState { idle, running, done }

// Config card

class _ConfigCard extends StatelessWidget {
  final InferenceBackend selected;
  final bool onDeviceReady;
  final bool running;
  final ValueChanged<InferenceBackend> onSelect;
  final VoidCallback onRun;
  final String onDeviceModel;
  final String cloudModel;

  const _ConfigCard({
    required this.selected,
    required this.onDeviceReady,
    required this.running,
    required this.onSelect,
    required this.onRun,
    required this.onDeviceModel,
    required this.cloudModel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Backend', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 10),
            Row(children: [
              _BackendChip(
                label: '📱 On-device',
                sublabel: onDeviceModel,
                active: selected == InferenceBackend.onDevice,
                enabled: onDeviceReady,
                onTap: onDeviceReady
                    ? () => onSelect(InferenceBackend.onDevice)
                    : null,
                scheme: scheme,
              ),
              const SizedBox(width: 8),
              _BackendChip(
                label: '☁️ Cloud',
                sublabel: cloudModel,
                active: selected == InferenceBackend.cloud,
                enabled: true,
                onTap: () => onSelect(InferenceBackend.cloud),
                scheme: scheme,
              ),
            ]),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: running ? null : onRun,
                icon: running
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(running ? 'Running…' : 'Run benchmark'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackendChip extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool active;
  final bool enabled;
  final VoidCallback? onTap;
  final ColorScheme scheme;

  const _BackendChip({
    required this.label,
    required this.sublabel,
    required this.active,
    required this.enabled,
    required this.onTap,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active
        ? scheme.onPrimaryContainer
        : enabled
            ? scheme.onSurface.withValues(alpha: 0.7)
            : scheme.onSurface.withValues(alpha: 0.3);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: active
              ? Border.all(color: scheme.primary.withValues(alpha: 0.5))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        active ? FontWeight.w600 : FontWeight.normal,
                    color: fg)),
            Text(sublabel,
                style:
                    TextStyle(fontSize: 10, color: fg.withValues(alpha: 0.7))),
          ],
        ),
      ),
    );
  }
}

// ─── Progress card ────────────────────────────────────────────────────────────

class _ProgressCard extends StatelessWidget {
  final int done;
  final int total;
  final BenchmarkResult? latest;
  final Animation<double> pulse;
  final InferenceBackend backend;

  const _ProgressCard({
    required this.done,
    required this.total,
    required this.latest,
    required this.pulse,
    required this.backend,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = total == 0 ? 0.0 : done / total;
    final color = backend == InferenceBackend.onDevice
        ? const Color(0xFF34A853)
        : const Color(0xFF4285F4);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            FadeTransition(
              opacity: pulse,
              child: Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: color)),
            ),
            const SizedBox(width: 8),
            Text(
              backend == InferenceBackend.onDevice
                  ? 'Running on-device…'
                  : 'Running cloud…',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const Spacer(),
            Text('$done / $total',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.55))),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
              color: color,
            ),
          ),
          if (latest != null) ...[
            const SizedBox(height: 10),
            _LatestChip(result: latest!),
          ],
        ]),
      ),
    );
  }
}

class _LatestChip extends StatelessWidget {
  final BenchmarkResult result;
  const _LatestChip({required this.result});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (result.error != null) {
      return Text('✗ ${result.prompt.label}: ${result.error}',
          style: TextStyle(fontSize: 12, color: scheme.error));
    }
    final ttft = result.result.timeToFirstToken.inMilliseconds;
    final tps = result.result.tokensPerSecond.toStringAsFixed(1);
    final grade = result.quality.grade;
    return Text(
      '✓ ${result.prompt.label} · TTFT ${ttft}ms · $tps tok/s · Quality $grade',
      style: TextStyle(
          fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.6)),
    );
  }
}

// ─── Summary row ──────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final Map<InferenceBackend, BenchmarkRun> runs;
  const _SummaryRow({required this.runs});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(children: [
        if (runs.containsKey(InferenceBackend.onDevice))
          Expanded(
              child: _SummaryCard(
                  run: runs[InferenceBackend.onDevice]!,
                  color: const Color(0xFF34A853),
                  label: '📱 On-device')),
        if (runs.length == 2) const SizedBox(width: 10),
        if (runs.containsKey(InferenceBackend.cloud))
          Expanded(
              child: _SummaryCard(
                  run: runs[InferenceBackend.cloud]!,
                  color: const Color(0xFF4285F4),
                  label: '☁️ Cloud')),
      ]),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final BenchmarkRun run;
  final Color color;
  final String label;

  const _SummaryCard(
      {required this.run, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final qualityPct = (run.avgQuality * 100).round();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        const SizedBox(height: 8),
        _StatLine('Avg TTFT', '${run.avgTtftMs.toStringAsFixed(0)}ms',
            scheme.onSurface),
        _StatLine('Avg tok/s', run.avgTps.toStringAsFixed(1), scheme.onSurface),
        _StatLine(
            'Avg quality', '$qualityPct%', scheme.onSurface),
        _StatLine(
            'Total tokens', '${run.totalTokens}', scheme.onSurface),
        _StatLine(
            'Wall time', '${run.totalDuration.inSeconds}s', scheme.onSurface),
      ]),
    );
  }
}

class _StatLine extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatLine(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label,
            style:
                TextStyle(fontSize: 11, color: color.withValues(alpha: 0.55))),
        Text(value,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color.withValues(alpha: 0.85))),
      ]),
    );
  }
}

// ─── Per-prompt result row ────────────────────────────────────────────────────

class _PromptResultRow extends StatefulWidget {
  final BenchmarkPrompt prompt;
  final BenchmarkResult? onDevice;
  final BenchmarkResult? cloud;

  const _PromptResultRow(
      {required this.prompt, this.onDevice, this.cloud});

  @override
  State<_PromptResultRow> createState() => _PromptResultRowState();
}

class _PromptResultRowState extends State<_PromptResultRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final od = widget.onDevice;
    final cl = widget.cloud;
    final hasBoth = od != null && cl != null;

    bool? onDeviceFasterTtft;
    bool? onDeviceFasterTps;
    bool? onDeviceBetterQuality;

    if (hasBoth && od.error == null && cl.error == null) {
      onDeviceFasterTtft =
          od.result.timeToFirstToken < cl.result.timeToFirstToken;
      onDeviceFasterTps = od.result.tokensPerSecond > cl.result.tokensPerSecond;
      onDeviceBetterQuality = od.quality.overall > cl.quality.overall;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(children: [
        // ── Header row ──────────────────────────────────────────────────
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              // Title bar
              Row(children: [
                _CategoryBadge(label: widget.prompt.category, scheme: scheme),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(widget.prompt.label,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
              ]),
              const SizedBox(height: 10),

              // Speed + quality columns
              Row(children: [
                if (od != null)
                  Expanded(
                    child: _ResultColumn(
                      result: od,
                      color: const Color(0xFF34A853),
                      emoji: '📱',
                      winnerTtft: onDeviceFasterTtft == true,
                      winnerTps: onDeviceFasterTps == true,
                      winnerQuality: onDeviceBetterQuality == true,
                    ),
                  ),
                if (hasBoth)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('vs',
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                scheme.onSurface.withValues(alpha: 0.3))),
                  ),
                if (cl != null)
                  Expanded(
                    child: _ResultColumn(
                      result: cl,
                      color: const Color(0xFF4285F4),
                      emoji: '☁️',
                      winnerTtft: onDeviceFasterTtft == false,
                      winnerTps: onDeviceFasterTps == false,
                      winnerQuality: onDeviceBetterQuality == false,
                    ),
                  ),
              ]),
            ]),
          ),
        ),

        // ── Expanded: quality detail + output preview ────────────────────
        if (_expanded) ...[
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              if (od != null)
                _QualityDetail(
                    result: od,
                    color: const Color(0xFF34A853),
                    label: '📱 On-device quality breakdown'),
              if (hasBoth) const SizedBox(height: 12),
              if (cl != null)
                _QualityDetail(
                    result: cl,
                    color: const Color(0xFF4285F4),
                    label: '☁️ Cloud quality breakdown'),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ─── Result column (speed + quality badge) ────────────────────────────────────

class _ResultColumn extends StatelessWidget {
  final BenchmarkResult result;
  final Color color;
  final String emoji;
  final bool winnerTtft;
  final bool winnerTps;
  final bool winnerQuality;

  const _ResultColumn({
    required this.result,
    required this.color,
    required this.emoji,
    required this.winnerTtft,
    required this.winnerTps,
    required this.winnerQuality,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (result.error != null) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('$emoji ${result.error}',
            style: TextStyle(fontSize: 11, color: scheme.error)),
      );
    }

    final ttft = result.result.timeToFirstToken.inMilliseconds;
    final tps = result.result.tokensPerSecond.toStringAsFixed(1);
    final tokens = result.result.completionTokens;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header with emoji + grade badge
        Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 12)),
          const Spacer(),
          _GradeBadge(quality: result.quality),
        ]),
        const SizedBox(height: 6),

        _MetricLine('TTFT', '${ttft}ms', winnerTtft, color, scheme),
        _MetricLine('tok/s', tps, winnerTps, color, scheme),
        _MetricLine('tokens', '$tokens', false, color, scheme),
      ]),
    );
  }
}

// ─── Grade badge ─────────────────────────────────────────────────────────────

class _GradeBadge extends StatelessWidget {
  final QualityScore quality;
  const _GradeBadge({required this.quality});

  static const _colors = {
    QualityGrade.excellent: Color(0xFF34A853),
    QualityGrade.good: Color(0xFF7CB342),
    QualityGrade.fair: Color(0xFFF9A825),
    QualityGrade.poor: Color(0xFFE64A19),
    QualityGrade.failing: Color(0xFFB71C1C),
  };

  @override
  Widget build(BuildContext context) {
    final c = _colors[quality.gradeLevel] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Text(
        quality.grade,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: c),
      ),
    );
  }
}

// ─── Quality detail (expanded section) ───────────────────────────────────────

class _QualityDetail extends StatelessWidget {
  final BenchmarkResult result;
  final Color color;
  final String label;

  const _QualityDetail(
      {required this.result, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = result.quality;
    final pct = (q.overall * 100).round();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Label + score bar
        Row(children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ),
          Text('$pct%',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: q.overall,
            minHeight: 4,
            backgroundColor: scheme.surfaceContainerHighest,
            color: color,
          ),
        ),
        const SizedBox(height: 10),

        // Check rows
        if (q.correct != null)
          _CheckRow('Correct answer', q.correct!, scheme),
        _CheckRow(
            'No repetition',
            q.repetitionRate < 0.25,
            scheme,
            detail: q.repetitionRate > 0
                ? '${(q.repetitionRate * 100).round()}% repeated 4-grams'
                : null),
        if (q.lengthCompliant != null)
          _CheckRow('Length on target', q.lengthCompliant!, scheme),
        if (q.itemCountCompliant != null)
          _CheckRow('All list items present', q.itemCountCompliant!, scheme),
        if (q.instructionFollowed != null)
          _CheckRow('Followed instructions', q.instructionFollowed!, scheme),

        // Flags
        if (q.flags.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...q.flags.map((f) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 13,
                        color: scheme.error.withValues(alpha: 0.8)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(f,
                          style: TextStyle(
                              fontSize: 11,
                              color: scheme.error.withValues(alpha: 0.8))),
                    ),
                  ],
                ),
              )),
        ],

        // Output preview
        if (result.result.fullText.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Output preview',
              style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                  letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              // result.result.fullText.length > 220
              //     ? '${result.result.fullText.substring(0, 220)}…'
              //     : 
                  result.result.fullText,
              style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.75),
                  height: 1.5),
            ),
          ),
        ],
      ]),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final String label;
  final bool passed;
  final ColorScheme scheme;
  final String? detail;

  const _CheckRow(this.label, this.passed, this.scheme, {this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(
          passed ? Icons.check_circle_rounded : Icons.cancel_rounded,
          size: 14,
          color: passed
              ? const Color(0xFF34A853)
              : scheme.error.withValues(alpha: 0.8),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.75))),
        if (detail != null) ...[
          const SizedBox(width: 4),
          Text('· $detail',
              style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurface.withValues(alpha: 0.4))),
        ],
      ]),
    );
  }
}

// ─── Shared small widgets ─────────────────────────────────────────────────────

class _CategoryBadge extends StatelessWidget {
  final String label;
  final ColorScheme scheme;
  const _CategoryBadge({required this.label, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10,
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600)),
    );
  }
}

class _MetricLine extends StatelessWidget {
  final String label;
  final String value;
  final bool winner;
  final Color color;
  final ColorScheme scheme;

  const _MetricLine(
      this.label, this.value, this.winner, this.color, this.scheme);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurface.withValues(alpha: 0.5))),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (winner) ...[
                Icon(Icons.emoji_events_rounded, size: 10, color: color),
                const SizedBox(width: 2),
              ],
              Text(value,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight:
                          winner ? FontWeight.w700 : FontWeight.normal,
                      color: winner
                          ? color
                          : scheme.onSurface.withValues(alpha: 0.75))),
            ]),
          ]),
    );
  }
}