import 'dart:io';

import 'package:flutter/material.dart';
import 'package:on_dev_llm/core/app_scope.dart';
import 'package:on_dev_llm/core/engine_router.dart';
import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/engine/cloud_engine.dart';
import 'package:on_dev_llm/platform/on_device_engine.dart';
import 'package:on_dev_llm/view/chat_screen.dart';
import 'package:on_dev_llm/view/model_loading_screen.dart';

const _apiKey = String.fromEnvironment('API_KEY', defaultValue: '');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final onDevice = OnDeviceEngine();
  final cloud = CloudEngine(apiKey: _apiKey);

  await cloud.initialize();

  onDevice.initialize(runtime: Platform.isAndroid? OnDeviceRuntime.litert: OnDeviceRuntime.mediaPipe).catchError((e) {
    debugPrint('[main] OnDevice init failed (will use cloud): $e');
  });

  final router = EngineRouter(onDevice: onDevice, cloud: cloud);

  runApp(OnDevLlmApp(router: router, onDevice: onDevice));
}

class OnDevLlmApp extends StatelessWidget {
  final EngineRouter router;
  final OnDeviceEngine onDevice;
  const OnDevLlmApp({super.key, required this.router, required this.onDevice});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nary LLM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      builder: (context, child) =>
          AppScope(router: router, onDevice: onDevice, child: child!),
      home: HomeGate(),
    );
  }
}

class HomeGate extends StatefulWidget {
  const HomeGate({super.key});

  @override
  State<HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends State<HomeGate> {
  bool? _isDownloaded;
  bool _checked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checked) return;
    _checked = true;
    final onDevice = AppScope.of(context).onDevice;
    onDevice.isModelDownloaded().then((downloaded) {
      if (mounted) setState(() => _isDownloaded = downloaded);
    });
  }

  @override
  Widget build(BuildContext context) {
    return (_isDownloaded ?? false) ? const ChatScreen() : ModelLoadingScreen();
  }
}
