import 'package:flutter/material.dart';
import 'package:on_dev_llm/core/engine_router.dart';
import 'package:on_dev_llm/core/enums.dart';

class ChatScreen extends StatefulWidget {
  final EngineRouter router;
  const ChatScreen({super.key, required this.router});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<_Message> _messages = [];
  bool _generating = false;

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

    try {
      await for (final chunk in widget.router.generateStream(text)) {
        ttft ??= sw.elapsed;
        backend ??= widget.router.onDevice.status == ModelStatus.ready
            ? InferenceBackend.onDevice
            : InferenceBackend.cloud;
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

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('On-Device LLM'),
        actions: [
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
              _MetaBadge(
                ttft: message.ttft!,
                backend: message.backend,
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
  const _MetaBadge({required this.ttft, this.backend});

  @override
  Widget build(BuildContext context) {
    final label = backend == InferenceBackend.onDevice ? '📱 on-device' : '☁️ cloud';
    final ms = ttft.inMilliseconds;
    return Text(
      '$label · TTFT ${ms}ms',
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
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