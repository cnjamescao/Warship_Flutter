// ================================================================
// lib/game/infrastructure/haptics_platform.dart
// ================================================================
// 真实平台触感实现（`flutter/services` 的 `HapticFeedback`）。
// Web / macOS 上 `HapticFeedback` 本身即 no-op，因此这里额外用
// `platformSupportsHaptics()` 明确表达"不支持"，便于上层判定与测试。
// ================================================================

import 'package:flutter/services.dart';

import 'haptics_port.dart';

class PlatformHapticsPort implements HapticsPort {
  PlatformHapticsPort({bool? isWebOverride, TargetPlatform? platformOverride})
    : _supported = platformSupportsHaptics(
        isWebOverride: isWebOverride,
        platformOverride: platformOverride,
      );

  final bool _supported;

  @override
  bool get isSupported => _supported;

  @override
  Future<void> impact(HapticStrength strength) async {
    if (!_supported) {
      return;
    }
    switch (strength) {
      case HapticStrength.light:
        await HapticFeedback.lightImpact();
      case HapticStrength.medium:
        await HapticFeedback.mediumImpact();
      case HapticStrength.heavy:
        await HapticFeedback.heavyImpact();
    }
  }

  @override
  Future<void> success() async {
    if (!_supported) {
      return;
    }
    // 裁决写的是「success/heavy pattern」；Flutter 没有跨平台 success API，
    // 用 heavy 表达"重大节点"。
    await HapticFeedback.heavyImpact();
  }
}
