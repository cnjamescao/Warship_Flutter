// ================================================================
// lib/game/infrastructure/haptics_platform.dart
//
// **架构位置**：Infrastructure（平台与 IO 适配） —— 把平台能力（音频/触觉/存档/性能）包成**可替换的端口**，便于测试注入替身。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：在假异步测试环境中须可注入替身 · 失败不得影响规则 · 平台不支持时静默 no-op。
// 本文件是触感的平台实现层：
//   * 平台不支持必须静默 no-op，不得抛错、不得影响规则
//   * 默认值：支持触感的原生移动端首次默认开；Web / macOS 默认关
//   * 测试不得走真实平台通道（会失败或挂起），应注入替身
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
