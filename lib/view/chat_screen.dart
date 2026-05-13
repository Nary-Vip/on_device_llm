import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:on_dev_llm/core/app_scope.dart';
import 'package:on_dev_llm/core/engine_router.dart';
import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/platform/on_device_engine.dart';
import 'package:on_dev_llm/view/benchmark_screen.dart';
import 'package:on_dev_llm/view/model_loading_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_Message> _messages = [];
  bool _generating = false;
  bool _forceCloud = false;
  bool _modelDownloaded = false;
  bool _modelActionInProgress = false;

  late final EngineRouter _router;
  late final OnDeviceEngine _onDevice;

  OnDeviceRuntime _activeRuntime = OnDeviceRuntime.mediaPipe;
  bool _runtimeSwitching = false;
  StreamSubscription<bool>? _routingSub;
  bool _actuallyUsingCloud = false;

  @override
  void dispose() {
    _routingSub?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _router = context.getInheritedWidgetOfExactType<AppScope>()!.router;
    _onDevice = context.getInheritedWidgetOfExactType<AppScope>()!.onDevice;
    _activeRuntime = _onDevice.currentRuntime;
    _checkModelStatus();
    _waitForDeviceReady();
    _routingSub = _router.onRoutingDecision.listen((usingOnDevice) {
      if (mounted) {
        setState(() => _actuallyUsingCloud = !usingOnDevice);
      }
    });
  }

  Future<void> _waitForDeviceReady() async {
    while (mounted && _router.onDevice.status == ModelStatus.loading) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (mounted) setState(() {});
  }

  Future<void> _checkModelStatus() async {
    final mediaPipe = await _router.onDevice.isModelDownloaded(
      runtime: OnDeviceRuntime.mediaPipe,
    );
    final liteRt = await _router.onDevice.isModelDownloaded(
      runtime: OnDeviceRuntime.litert,
    );
    if (mounted) setState(() => _modelDownloaded = mediaPipe || liteRt);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _deleteModel() async {
    final mediaPipeExists = await _onDevice.isModelDownloaded(
      runtime: OnDeviceRuntime.mediaPipe,
    );
    final liteRtExists = await _onDevice.isModelDownloaded(
      runtime: OnDeviceRuntime.litert,
    );

    if (!mediaPipeExists && !liteRtExists) {
      _showSnack('No models downloaded');
      return;
    }

    bool deleteMediaPipe = false;
    bool deleteLiteRt = false;

    final mediaPipeSize = await _onDevice.modelSizeBytes(
      runtime: OnDeviceRuntime.mediaPipe,
    );
    final liteRtSize = await _onDevice.modelSizeBytes(
      runtime: OnDeviceRuntime.litert,
    );

    if (!mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Delete models'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select models to remove:',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    ctx,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 12),

              // MediaPipe — Gemma 3 1B
              if (mediaPipeExists)
                CheckboxListTile(
                  value: deleteMediaPipe,
                  onChanged: (v) =>
                      setDialogState(() => deleteMediaPipe = v ?? false),
                  title: const Text('Gemma 3 1B'),
                  subtitle: Text('MediaPipe · ${mediaPipeSize != null ? _formatBytes(mediaPipeSize) : "~530 MB"}'),
                  secondary: const Icon(Icons.memory_rounded),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),

              // LiteRT-LM — Gemma 4 E2B
              if (liteRtExists)
                CheckboxListTile(
                  value: deleteLiteRt,
                  onChanged: (v) =>
                      setDialogState(() => deleteLiteRt = v ?? false),
                  title: const Text('Gemma 4 E2B'),
                  subtitle: Text('LiteRT-LM · ${liteRtSize != null ? _formatBytes(liteRtSize) : "~2.5 GB"}'),
                  secondary: const Icon(Icons.auto_awesome_rounded),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),

              const SizedBox(height: 8),
              Text(
                'You can re-download them anytime.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    ctx,
                  ).colorScheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: (deleteMediaPipe || deleteLiteRt)
                  ? () => Navigator.pop(ctx, true)
                  : null, // ← disabled until at least one is selected
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    setState(() => _modelActionInProgress = true);

    final futures = <Future>[];
    if (deleteMediaPipe) {
      futures.add(_onDevice.deleteModel(runtime: OnDeviceRuntime.mediaPipe));
    }
    if (deleteLiteRt) {
      futures.add(_onDevice.deleteModel(runtime: OnDeviceRuntime.litert));
    }
    await Future.wait(futures);

    if (mounted) {
      final activeDeleted =
          (_activeRuntime == OnDeviceRuntime.mediaPipe && deleteMediaPipe) ||
          (_activeRuntime == OnDeviceRuntime.litert && deleteLiteRt);

      final mediaPipeStillExists = await _onDevice.isModelDownloaded(
        runtime: OnDeviceRuntime.mediaPipe,
      );
      final liteRtStillExists = await _onDevice.isModelDownloaded(
        runtime: OnDeviceRuntime.litert,
      );

      final anyRemaining = mediaPipeStillExists || liteRtStillExists;

      setState(() {
        _modelDownloaded = anyRemaining;
        _modelActionInProgress = false;
        if (activeDeleted) _forceCloud = true;
      });

      final names = [
        if (deleteMediaPipe) 'Gemma 3 1B',
        if (deleteLiteRt) 'Gemma 4 E2B',
      ].join(' & ');
      _showSnack('$names deleted');
    }
  }

  Future<void> _downloadModel() async {
    setState(() => _modelActionInProgress = true);

    _onDevice.initialize().catchError((e) {
      debugPrint('[main] OnDevice init failed (will use cloud): $e');
    });

    // Navigate to loading screen to re-download
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, a1, a2) => ModelLoadingScreen(),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );

    // Re-check status when we come back
    await _checkModelStatus();
    if (mounted) setState(() => _modelActionInProgress = false);
  }

  void _switchBackend(bool toCloud) {
    if (_generating) return;

    setState(() {
      _forceCloud = toCloud;
    });
  }

  String _buildConversationPrompt(String latestUserMessage) {
    final sb = StringBuffer();

    sb.writeln('You are a helpful AI assistant in an ongoing conversation.');

    sb.writeln();

    for (final m in _messages) {
      sb.writeln(m.isUser ? 'User: ${m.text}' : 'Assistant: ${m.text}');
    }

    sb.writeln('User: $latestUserMessage');
    sb.writeln('Assistant:');

    return sb.toString();
  }

  // ─── Send ───────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _generating) return;
    _controller.clear();

    setState(() {
      _messages.add(_Message(text: text, isUser: true));
      _messages.add(_Message(text: '', isUser: false));
      _generating = true;
    });
    _scrollToBottom();

    final sw = Stopwatch()..start();
    Duration? ttft;
    final buffer = StringBuffer();
    InferenceBackend? backend;
    bool routedMidStream = false;
    final prompt = _buildConversationPrompt(text);

    InferenceBackend? routedBackend;
    final routingSub = _router.onRoutingDecision.listen((usingOnDevice) {
      routedBackend = usingOnDevice
          ? InferenceBackend.onDevice
          : InferenceBackend.cloud;
    });

    try {
      await for (final chunk in _router.generateStream(
        prompt,
        forceCloud: _forceCloud,
      )) {
        ttft ??= sw.elapsed;
        if (backend == null) {
          backend =
              routedBackend ??
              (_forceCloud
                  ? InferenceBackend.cloud
                  : InferenceBackend.onDevice);
        } else if (routedBackend != null && routedBackend != backend) {
          routedMidStream = true;
          backend = routedBackend;
        }
        buffer.write(chunk.text);
        setState(() {
          _messages.last = _Message(
            text: buffer.toString(),
            isUser: false,
            ttft: ttft,
            backend: backend,
            routedMidStream: routedMidStream,
          );
        });
        _scrollToBottom();
      }
    } finally {
      routingSub.cancel();
      setState(() => _generating = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _switchRuntime(OnDeviceRuntime runtime) async {
    if (_runtimeSwitching || _generating || runtime == _activeRuntime) return;

    // Check if the target model is already downloaded
    final alreadyDownloaded = await _onDevice.isModelDownloaded(
      runtime: runtime,
    );

    setState(() {
      _activeRuntime = runtime;
      _runtimeSwitching = true;
      _forceCloud = true; // use cloud while new engine loads
    });

    if (alreadyDownloaded) {
      // Model cached — just reinitialise, no loading screen needed
      try {
        await _onDevice.initialize(runtime: runtime);
        if (mounted) {
          setState(() {
            _runtimeSwitching = false;
            _modelDownloaded = true;
            _forceCloud = _router.onDevice.status != ModelStatus.ready;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _runtimeSwitching = false;
            _forceCloud = true;
          });
          _showSnack('Failed to switch runtime: $e');
        }
      }
    } else {
      // Model not cached — reinitialise (starts download) then go to loading screen
      _onDevice.initialize(runtime: runtime).catchError((e) {
        debugPrint('[runtime switch] init failed: $e');
      });

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, a1, a2) => ModelLoadingScreen(),
          transitionsBuilder: (_, anim, _, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );
    }
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final onDeviceAvailable = _router.onDevice.status == ModelStatus.ready;
    final effectiveCloud = _forceCloud || _actuallyUsingCloud;
    return Scaffold(
      appBar: AppBar(
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            Platform.isAndroid && !_forceCloud ? 96 : 48,
          ),
          child: Column(
            children: [
              _BackendSwitcher(
                forceCloud: effectiveCloud,
                onDeviceAvailable: onDeviceAvailable,
                onChanged: _switchBackend,
                onLocal: _router.onDevice.modelId,
                onCloud: _router.cloud.modelId,
              ),
              if (Platform.isAndroid && !_forceCloud)
                _RuntimeSwitcher(
                  activeRuntime: _activeRuntime,
                  switching: _runtimeSwitching,
                  onChanged: _switchRuntime,
                ),
            ],
          ),
        ),
        title: const Text('Nary LLM'),
        actions: [
          // ── Model delete / download toggle ──
          if (_modelActionInProgress)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_modelDownloaded)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: 'Delete on-device model',
              onPressed: _generating ? null : _deleteModel,
            )
          else
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'Download on-device model',
              onPressed: _generating ? null : _downloadModel,
            ),
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded),
            tooltip: 'Benchmark',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BenchmarkScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Add this above the ListView in body Column:
          if (_actuallyUsingCloud && !_forceCloud) ...[
            Material(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Routed to cloud — device conditions not met',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(
                          context,
                        ).colorScheme.onTertiaryContainer,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _actuallyUsingCloud = false),
                      child: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: Theme.of(
                          context,
                        ).colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (_, i) => _MessageBubble(message: _messages[i]),
            ),
          ),
          _InputBar(
            controller: _controller,
            generating: _generating,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

// ─── Data ───────────────────────────────────────────────────────────────────

class _Message {
  final String text;
  final bool isUser;
  final Duration? ttft;
  final InferenceBackend? backend;
  final bool routedMidStream;

  const _Message({
    required this.text,
    required this.isUser,
    this.ttft,
    this.backend,
    this.routedMidStream = false,
  });
}

// ─── Widgets ────────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final _Message message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final color = isUser
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.text.isEmpty && !isUser)
              const _TypingIndicator()
            else
              Text(message.text, style: const TextStyle(fontSize: 15)),
            if (!isUser && message.ttft != null) ...[
              const SizedBox(height: 6),
              _MetaBadge(
                ttft: message.ttft!,
                backend: message.backend,
                routedMidStream: message.routedMidStream,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaBadge extends StatelessWidget {
  final Duration ttft;
  final InferenceBackend? backend;
  final bool routedMidStream;
  const _MetaBadge({
    required this.ttft,
    this.backend,
    this.routedMidStream = false,
  });

  @override
  Widget build(BuildContext context) {
    String label;
    if (routedMidStream) {
      label = '📱→☁️ fallback';
    } else {
      label = backend == InferenceBackend.onDevice
          ? '📱 on-device'
          : '☁️ cloud';
    }

    final ms = ttft.inMilliseconds;
    return Text(
      '$label · TTFT ${ms}ms',
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      ),
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (i) => _Dot(delay: Duration(milliseconds: i * 160)),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final Duration delay;
  const _Dot({required this.delay});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _ac;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    Future.delayed(widget.delay, () {
      if (mounted) _ac.forward();
    });
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ac,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool generating;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.generating,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                maxLines: null,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: 'Message…',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: generating ? null : onSend,
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(14),
              ),
              child: generating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackendSwitcher extends StatelessWidget {
  final bool forceCloud;
  final bool onDeviceAvailable;
  final ValueChanged<bool> onChanged;
  final String onLocal;
  final String onCloud;

  const _BackendSwitcher({
    required this.forceCloud,
    required this.onDeviceAvailable,
    required this.onChanged,
    required this.onLocal,
    required this.onCloud,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCloud = forceCloud || !onDeviceAvailable;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          // On-device pill
          _BackendPill(
            icon: Icons.memory_rounded,
            label: 'On-device',
            active: !isCloud,
            available: onDeviceAvailable,
            scheme: scheme,
            onTap: onDeviceAvailable ? () => onChanged(false) : null,
          ),
          const SizedBox(width: 8),

          // Animated sync arrow between the two pills
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Icon(
              key: const ValueKey('arrow'),
              isCloud ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
              size: 16,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
          ),

          const SizedBox(width: 8),

          // Cloud pill
          _BackendPill(
            icon: Icons.cloud_outlined,
            label: 'Cloud',
            active: isCloud,
            available: true,
            scheme: scheme,
            onTap: () => onChanged(true),
          ),
          const Spacer(),
          // Live indicator dot
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isCloud
                  ? const Color(0xFF4285F4) // Google blue for cloud
                  : const Color(0xFF34A853), // Google green for on-device
            ),
          ),
          const SizedBox(width: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              key: ValueKey(isCloud ? 'cloud' : 'local'),
              isCloud
                  ? onCloud.substring(0, onLocal.length.clamp(0, 15))
                  : onLocal.substring(0, onLocal.length.clamp(0, 15)),
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BackendPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool available;
  final ColorScheme scheme;
  final VoidCallback? onTap;

  const _BackendPill({
    required this.icon,
    required this.label,
    required this.active,
    required this.available,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active
        ? scheme.onPrimaryContainer
        : available
        ? scheme.onSurface.withValues(alpha: 0.55)
        : scheme.onSurface.withValues(alpha: 0.25);
    final bg = active
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: active
              ? Border.all(color: scheme.primary.withValues(alpha: 0.4))
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                color: fg,
              ),
            ),
            if (!available) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.block_rounded,
                size: 11,
                color: scheme.onSurface.withValues(alpha: 0.25),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RuntimeSwitcher extends StatelessWidget {
  final OnDeviceRuntime activeRuntime;
  final bool switching;
  final ValueChanged<OnDeviceRuntime> onChanged;

  const _RuntimeSwitcher({
    required this.activeRuntime,
    required this.switching,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(
            Icons.swap_horiz_rounded,
            size: 14,
            color: scheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 6),
          Text(
            'Runtime:',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 8),

          // MediaPipe pill
          _RuntimePill(
            label: 'MediaPipe',
            sublabel: 'Gemma 3 1B',
            active: activeRuntime == OnDeviceRuntime.mediaPipe,
            switching: switching,
            color: const Color(0xFF1A73E8), // Google blue
            onTap: switching
                ? null
                : () => onChanged(OnDeviceRuntime.mediaPipe),
            scheme: scheme,
          ),
          const SizedBox(width: 6),

          // LiteRT pill
          _RuntimePill(
            label: 'LiteRT-LM',
            sublabel: 'Gemma 4 E2B',
            active: activeRuntime == OnDeviceRuntime.litert,
            switching: switching,
            color: const Color(0xFF34A853), // Google green
            onTap: switching ? null : () => onChanged(OnDeviceRuntime.litert),
            scheme: scheme,
          ),

          const Spacer(),

          // Spinning indicator while switching
          if (switching)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: scheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}

class _RuntimePill extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool active;
  final bool switching;
  final Color color;
  final VoidCallback? onTap;
  final ColorScheme scheme;

  const _RuntimePill({
    required this.label,
    required this.sublabel,
    required this.active,
    required this.switching,
    required this.color,
    required this.onTap,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.12)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? color : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Coloured dot
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? color
                    : scheme.onSurface.withValues(alpha: 0.25),
              ),
            ),
            const SizedBox(width: 5),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    color: active
                        ? color
                        : scheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                Text(
                  sublabel,
                  style: TextStyle(
                    fontSize: 9,
                    color: active
                        ? color.withValues(alpha: 0.7)
                        : scheme.onSurface.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
