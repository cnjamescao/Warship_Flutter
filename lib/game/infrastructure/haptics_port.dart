// ================================================================
// lib/game/infrastructure/haptics_port.dart
// ================================================================
// F-10 裁决：
//   「`settings.hapticsEnabled`：支持触感的原生移动端首次默认开；
//     Web/macOS 默认关；用户设置持久化。仅在 `hpDamage>0` 时触发
//     medium impact、确认风险门时 light impact、Boss 击败时
//     success/heavy pattern；**护盾独立受击、普通击杀、射击、
//     每发子弹均不得触发**。平台不支持时必须静默 no-op。」
//
// 设计对齐 `AudioPort`：抽象端口 + 服务 + 平台实现，
// 使"该触发"与"绝不该触发"两类都能被**正反向测试**覆盖。
// ================================================================

import 'package:flutter/foundation.dart';

/// 触感强度。
enum HapticStrength {
  /// 轻——用于"确认"类反馈（风险门确认）。
  light,

  /// 中——用于"受创"类反馈（受 HP 伤害）。
  medium,

  /// 重——用于"重大节点"（Boss 击败）。
  heavy,
}

/// 触感输出端口。平台实现与测试替身都实现它。
abstract class HapticsPort {
  /// 平台是否具备触感能力。**不支持时必须静默 no-op，不得抛异常。**
  bool get isSupported;

  Future<void> impact(HapticStrength strength);

  /// 成功模式（Boss 击败）。
  Future<void> success();
}

/// 静默实现：平台不支持触感时使用（Web / macOS / 桌面）。
///
/// 它**永不抛异常**——裁决要求"平台不支持时必须静默 no-op"。
class NoopHapticsPort implements HapticsPort {
  const NoopHapticsPort();

  @override
  bool get isSupported => false;

  @override
  Future<void> impact(HapticStrength strength) async {}

  @override
  Future<void> success() async {}
}

/// 平台能力判定（Web 安全：不使用 `dart:io`）。
///
/// 裁决：**支持触感的原生移动端**默认开；**Web/macOS 默认关**。
bool platformSupportsHaptics({
  bool? isWebOverride,
  TargetPlatform? platformOverride,
}) {
  final isWeb = isWebOverride ?? kIsWeb;
  if (isWeb) {
    return false;
  }
  final platform = platformOverride ?? defaultTargetPlatform;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.android;
}

/// 触感服务：把"用户开关"与"平台能力"合成为最终是否发声。
///
/// 两重门：**用户设置** 且 **平台支持**。任一不满足即静默 no-op。
class HapticsService {
  HapticsService(this._port, {bool enabled = true}) {
    _enabled = enabled;
  }

  final HapticsPort _port;
  bool _enabled = true;

  bool get isEnabled => _enabled;

  /// 实际会不会产生触感（用户开 且 平台支持）。
  bool get willFire => _enabled && _port.isSupported;

  set enabled(bool value) => _enabled = value;

  Future<void> impact(HapticStrength strength) async {
    if (!willFire) {
      return;
    }
    // 端口异常绝不影响对局（与音频同一原则）。
    try {
      await _port.impact(strength);
    } catch (_) {
      // 静默：触感失败不得中断游戏逻辑。
    }
  }

  Future<void> success() async {
    if (!willFire) {
      return;
    }
    try {
      await _port.success();
    } catch (_) {
      // 静默。
    }
  }
}

/// 记录调用的测试替身。
class RecordingHapticsPort implements HapticsPort {
  RecordingHapticsPort({this.isSupported = true});

  @override
  final bool isSupported;

  final List<HapticStrength> impacts = <HapticStrength>[];
  int successCount = 0;

  /// 设为 true 时所有调用抛异常——用于验证"端口异常不影响对局"。
  bool throwOnCall = false;

  @override
  Future<void> impact(HapticStrength strength) async {
    if (throwOnCall) {
      throw StateError('haptics port failure');
    }
    impacts.add(strength);
  }

  @override
  Future<void> success() async {
    if (throwOnCall) {
      throw StateError('haptics port failure');
    }
    successCount++;
  }
}
