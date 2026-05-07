import 'package:flutter/material.dart';
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
  final cloud    = CloudEngine(apiKey: _apiKey);

  await cloud.initialize();

  try {
    await onDevice.initialize();
  } catch (e) {
    debugPrint('[main] OnDevice init failed (will use cloud): $e');
  }

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
      title: 'On-Device LLM',
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
      home: _HomeGate(router: router, onDevice: onDevice),
    );
  }
}

class _HomeGate extends StatelessWidget {
  final EngineRouter router;
  final OnDeviceEngine onDevice;
  const _HomeGate({required this.router, required this.onDevice});

  @override
  Widget build(BuildContext context) {
    if (onDevice.status == ModelStatus.ready ||
        onDevice.status == ModelStatus.failed) {
      return ChatScreen(router: router);
    }
    
    return ModelLoadingScreen(onDevice: onDevice, router: router);
  }
}