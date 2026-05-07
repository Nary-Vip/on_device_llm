import 'dart:async';
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:logger/logger.dart';
import 'package:on_dev_llm/core/enums.dart';
import 'package:on_dev_llm/core/interface/inference_interface.dart';

/// Decides which backend to use for each request.
///
/// Strategy (in order):
///   1. If on-device engine is [ModelStatus.ready] AND device tier allows it → use on-device
///   2. If on-device fails mid-stream → transparently re-issue to cloud
///   3. If caller forces cloud (e.g. benchmark comparison) → use cloud directly
class EngineRouter {
  final InferenceEngine onDevice;
  final InferenceEngine cloud;

  final int minFreeRamBytes;
  final int minBatteryPercent;
  final bool respectLowPowerMode;

  final _log = Logger();
  final _battery = Battery();

  EngineRouter({
    required this.onDevice,
    required this.cloud,
    this.minFreeRamBytes = 10000 * 1024 * 1024,
    this.minBatteryPercent = 20,
    this.respectLowPowerMode = true,
  });

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Stream tokens; falls back to cloud if on-device errors.
  Stream<TokenChunk> generateStream(
    String prompt, {
    int maxTokens = 512,
    bool forceCloud = false,
  }) async* {
    if (!forceCloud && await _shouldUseOnDevice()) {
      try {
        yield* onDevice.generateStream(prompt, maxTokens: maxTokens);
        return;
      } catch (e) {
        _log.w('OnDevice stream failed, falling back to cloud: $e');
      }
    }
    yield* cloud.generateStream(prompt, maxTokens: maxTokens);
  }

  /// Full result with metrics (used by benchmark).
  Future<InferenceResult> generate(
    String prompt, {
    int maxTokens = 512,
    bool forceCloud = false,
  }) async {
    if (!forceCloud && await _shouldUseOnDevice()) {
      try {
        return await onDevice.generate(prompt, maxTokens: maxTokens);
      } catch (e) {
        _log.w('OnDevice generate failed, falling back to cloud: $e');
      }
    }
    return cloud.generate(prompt, maxTokens: maxTokens);
  }

  // ─── Decision logic ────────────────────────────────────────────────────────

  Future<bool> _shouldUseOnDevice() async {
    // 1. Model must be ready
    if (onDevice.status != ModelStatus.ready) {
      _log.d('Routing to cloud: model not ready');
      return false;
    }

    // 2. RAM check
    if (!_hasEnoughRam()) {
      _log.d('Routing to cloud: insufficient RAM');
      return false;
    }

    // 3. Thermal / heat check
    if (_isDeviceThrottling()) {
      _log.d('Routing to cloud: device throttling');
      return false;
    }

    // 4. Battery check
    if (!await _hasSufficientBattery()) {
      _log.d('Routing to cloud: low battery');
      return false;
    }

    // 5. Low power mode check
    if (respectLowPowerMode && await _isLowPowerMode()) {
      _log.d('Routing to cloud: low power mode active');
      return false;
    }

    return true;
  }

  bool _hasEnoughRam() {
    try {
      final freeRam = ProcessInfo.currentRss;
      // TODO(optimisation): Better approach to choose Native Method get exact free RAM.
      return freeRam < minFreeRamBytes;
    } catch (e) {
      _log.w('RAM check failed, assuming sufficient: $e');
      return true;
    }
  }

  bool _isDeviceThrottling() {
    try {
      if (Platform.isIOS) {
        return false; // handled in _hasSufficientBattery
      }
      // TODO(optimisation): Better approach to choose Native Method get exact free RAM. (read /sys/class/thermal/thermal_zone*/temp)
      return false;
    } catch (e) {
      _log.w('Thermal check failed, assuming ok: $e');
      return false;
    }
  }

  Future<bool> _hasSufficientBattery() async {
      try {
        final level = await _battery.batteryLevel;
        final state = await _battery.batteryState;

        final isCharging =
            state == BatteryState.charging || state == BatteryState.full;

        if (isCharging) return true;
        return level >= minBatteryPercent;
      } catch (e) {
        _log.w('Battery check failed, assuming sufficient: $e');
        return true;
      }
  }

  Future<bool> _isLowPowerMode() async {
    try {
      return await _battery.isInBatterySaveMode;
    } catch (e) {
      _log.w('Low power mode check failed, assuming off: $e');
      return false;
    }
  }
}
