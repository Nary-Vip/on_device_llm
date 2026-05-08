// lib/ui/screens/model_loading_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:on_dev_llm/core/app_scope.dart';
import 'package:on_dev_llm/core/models/model_progress.dart';
import 'package:on_dev_llm/platform/on_device_engine.dart';
import 'package:on_dev_llm/view/chat_screen.dart';

class ModelLoadingScreen extends StatefulWidget {
  const ModelLoadingScreen({super.key});

  @override
  State<ModelLoadingScreen> createState() => _ModelLoadingScreenState();
}

class _ModelLoadingScreenState extends State<ModelLoadingScreen>
    with SingleTickerProviderStateMixin {
  double _progress = 0;
  ModelPhase _phase = ModelPhase.downloading;
  String? _errorMessage;
  StreamSubscription<ModelProgress>? _sub;
  int _downloadedBytes = 0;
  int _totalBytes = 0;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  late final OnDeviceEngine _onDevice;

  @override
  void initState() {
    super.initState();
    final scope = context.getInheritedWidgetOfExactType<AppScope>()!;
    _onDevice = scope.onDevice;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _startListening();
  }

  void _startListening() {
    _sub = _onDevice.progressStream.listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _progress = event.value;
          _phase = event.phase;
          _downloadedBytes = event.downloadedBytes;
          _totalBytes = event.totalBytes;
        });

        // When loading phase hits 1.0, model is in memory — go to chat
        if (event.phase == ModelPhase.loading && event.value >= 1.0) {
          _navigateToChat();
        }
      },
      onError: (e) {
        if (!mounted) return;
        setState(() => _errorMessage = e.toString());
      },
    );
  }

  void _navigateToChat() {
    _sub?.cancel();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, a1, a2) => ChatScreen(),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  void _retryOrSkip() {
    // On error: skip on-device, go straight to chat with cloud-only router
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen()),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),
              _buildIcon(scheme),
              const SizedBox(height: 40),
              _buildTitle(),
              const SizedBox(height: 12),
              _buildSubtitle(scheme),
              const SizedBox(height: 48),
              if (_errorMessage == null) ...[
                _buildProgressBar(scheme),
                const SizedBox(height: 16),
                _buildProgressLabel(scheme),
              ] else ...[
                _buildError(scheme),
              ],
              const Spacer(flex: 3),
              _buildFooter(scheme),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Sub-widgets ────────────────────────────────────────────────────────────

  Widget _buildIcon(ColorScheme scheme) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, _) => Opacity(
        opacity: _errorMessage != null ? 1.0 : _pulseAnim.value,
        child: Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: _errorMessage != null
                ? scheme.errorContainer
                : scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            _errorMessage != null
                ? Icons.error_outline_rounded
                : Icons.memory_rounded,
            size: 38,
            color: _errorMessage != null
                ? scheme.onErrorContainer
                : scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }

  Widget _buildTitle() {
    return Text(
      _errorMessage != null
          ? 'Download failed'
          : _phase == ModelPhase.downloading
          ? 'Downloading model'
          : 'Loading into memory',
      style: Theme.of(
        context,
      ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildSubtitle(ColorScheme scheme) {
    String sizeLabel = 'Gemma 3 1B';
    if (_totalBytes > 0) {
      sizeLabel += ' · ${_formatBytes(_totalBytes)}';
      if (_phase == ModelPhase.downloading) {
        sizeLabel += ' · one-time download';
      }
    }
    return Text(
      _phase == ModelPhase.downloading
          ? sizeLabel
          : 'Initialising on-device inference…',
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: scheme.onSurface.withValues(alpha: 0.6),
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildProgressBar(ColorScheme scheme) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: _phase == ModelPhase.loading && _progress < 1.0
                ? null // indeterminate while loading into memory
                : _progress,
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(scheme.primary),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressLabel(ColorScheme scheme) {
    if (_phase == ModelPhase.loading) {
      return Text(
        'Warming up…',
        style: TextStyle(
          fontSize: 13,
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
      );
    }

    final pct = (_progress * 100).toStringAsFixed(0);
    final sizeLabel = _totalBytes > 0
        ? '${_formatBytes(_downloadedBytes)} / ${_formatBytes(_totalBytes)}'
        : _estimateRemaining();

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          '$pct%',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
        Text(
          sizeLabel,
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Widget _buildError(ColorScheme scheme) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _errorMessage!,
            style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _retryOrSkip,
          icon: const Icon(Icons.cloud_outlined, size: 18),
          label: const Text('Continue with cloud'),
        ),
      ],
    );
  }

  Widget _buildFooter(ColorScheme scheme) {
    if (_errorMessage != null) return const SizedBox.shrink();
    return Column(
      children: [
        TextButton(
          onPressed: _retryOrSkip,
          child: Text(
            'Skip — use cloud for now',
            style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.5)),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'The model will finish downloading in the background',
          style: TextStyle(
            fontSize: 11,
            color: scheme.onSurface.withValues(alpha: 0.35),
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  // Very rough estimate — ~1.5 GB file, assume ~5 MB/s mobile connection
  String _estimateRemaining() {
    if (_progress <= 0.01) return 'estimating…';
    const totalMb = 1500.0;
    const speedMbs = 5.0;
    final remainingMb = totalMb * (1 - _progress);
    final seconds = (remainingMb / speedMbs).round();
    if (seconds < 60) return '~${seconds}s left';
    return '~${(seconds / 60).ceil()} min left';
  }
}
