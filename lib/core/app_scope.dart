import 'package:flutter/material.dart';
import 'package:on_dev_llm/core/engine_router.dart';
import 'package:on_dev_llm/core/interface/inference_interface.dart';
import 'package:on_dev_llm/platform/on_device_engine.dart';

class AppScope extends InheritedWidget {
  final EngineRouter router;
  final OnDeviceEngine onDevice;

  const AppScope({
    super.key,
    required this.router,
    required this.onDevice,
    required super.child,
  });

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope found in context');
    return scope!;
  }

  InferenceEngine get cloud => router.cloud;

  @override
  bool updateShouldNotify(AppScope old) =>
      router != old.router || onDevice != old.onDevice;
}