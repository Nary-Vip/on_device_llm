import 'dart:io';

import 'package:flutter/material.dart';
import 'package:on_dev_llm/core/app_scope.dart';
import 'package:on_dev_llm/core/engine_router.dart';
import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/platform/on_device_engine.dart';
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

  @override
  void initState() {
    super.initState();
    _router = context.getInheritedWidgetOfExactType<AppScope>()!.router;
    _onDevice = context.getInheritedWidgetOfExactType<AppScope>()!.onDevice;
    _activeRuntime = _onDevice.currentRuntime;
    _checkModelStatus();
    _waitForDeviceReady();
  }

  Future<void> _waitForDeviceReady() async {
    while (mounted && _router.onDevice.status == ModelStatus.loading) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (mounted) setState(() {});
  }

  Future<void> _checkModelStatus() async {
    final downloaded = await _router.onDevice.isModelDownloaded();
    if (mounted) setState(() => _modelDownloaded = downloaded);
  }

  Future<void> _deleteModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          'This will remove the ${_activeRuntime == OnDeviceRuntime.litert ? "Gemma 4 E2B (~2.5 GB)" : "Gemma 3 1B (~700 MB)"} '
          'You can re-download it anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _modelActionInProgress = true);
    await _router.onDevice.deleteModel();
    if (mounted) {
      setState(() {
        _modelDownloaded = false;
        _modelActionInProgress = false;
        // Force cloud if on-device was active
        _forceCloud = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Model deleted')));
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
      _messages.add(_Message(text: '', isUser: false)); // placeholder
      _generating = true;
    });
    _scrollToBottom();

    final sw = Stopwatch()..start();
    Duration? ttft;
    final buffer = StringBuffer();
    InferenceBackend? backend;
    final prompt = _buildConversationPrompt(text);

    try {
      await for (final chunk in _router.generateStream(
        prompt,
        forceCloud: _forceCloud,
      )) {
        ttft ??= sw.elapsed;
        backend ??= _forceCloud
            ? InferenceBackend.cloud
            : InferenceBackend.onDevice;
        buffer.write(chunk.text);
        setState(() {
          _messages.last = _Message(
            text: buffer.toString(),
            isUser: false,
            ttft: ttft,
            backend: backend,
          );
        });
        _scrollToBottom();
      }
    } finally {
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
          transitionsBuilder: (_, anim, __, child) =>
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
    return Scaffold(
      appBar: AppBar(
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            Platform.isAndroid && !_forceCloud ? 96 : 48,
          ),
          child: Column(
            children: [
              _BackendSwitcher(
                forceCloud: _forceCloud,
                onDeviceAvailable: onDeviceAvailable,
                onChanged: _switchBackend,
                onLocal: _router.onDevice.modelId,
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

          // ── Benchmark ──
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded),
            tooltip: 'Benchmark',
            onPressed: () => Navigator.pushNamed(context, '/benchmark'),
          ),
        ],
      ),
      body: Column(
        children: [
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

  const _Message({
    required this.text,
    required this.isUser,
    this.ttft,
    this.backend,
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
              _MetaBadge(ttft: message.ttft!, backend: message.backend),
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
  const _MetaBadge({required this.ttft, this.backend});

  @override
  Widget build(BuildContext context) {
    final label = backend == InferenceBackend.onDevice
        ? '📱 on-device'
        : '☁️ cloud';
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

  const _BackendSwitcher({
    required this.forceCloud,
    required this.onDeviceAvailable,
    required this.onChanged,
    required this.onLocal,
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
                  ? 'Gemini Flash'
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

// ─── Switching banner ─────────────────────────────────────────────────────────

class _SwitchingBanner extends StatelessWidget {
  final OnDeviceRuntime runtime;
  const _SwitchingBanner({required this.runtime});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = runtime == OnDeviceRuntime.litert
        ? 'Switching to LiteRT-LM (Gemma 4)…'
        : 'Switching to MediaPipe (Gemma 3)…';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: scheme.tertiaryContainer.withValues(alpha: 0.6),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: scheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
          ),
        ],
      ),
    );
  }
}
