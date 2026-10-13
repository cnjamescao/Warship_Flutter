// ================================================================
// lib/game/core/phase_controller.dart —— 相位状态机
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §3.1
//   「AppLifecycleState.inactive/paused/detached、浏览器
//     visibilitychange(hidden)、窗口失焦均必须提交同一个
//     PauseRequested(source) 命令。重复 Pause 命令必须幂等。
//     恢复时不自动继续，玩家点击"继续"才回 Playing。」
//
// 设计：控制器**不**依赖事件总线，只返回迁移结果（PhaseChanged?），
// 由 Runtime 负责盖章发出。这样控制器可以在纯 Dart 测试中直接驱动。
// ================================================================

import 'domain_event.dart';
import 'game_phase.dart';

/// 暂停请求的来源。
///
/// 三个平台来源必须是**同一个命令**：调用方只传入来源标签，
/// 不改变行为，因此不存在"某个平台忘了暂停"的分支。
enum PauseSource {
  /// Flutter `AppLifecycleState.inactive/paused/detached`。
  appLifecycle,

  /// 浏览器 `visibilitychange(hidden)`。
  browserHidden,

  /// 窗口失去焦点（桌面/Web）。
  windowBlur,

  /// 玩家主动按 Esc / 点击暂停。
  userRequest,
}

/// 相位迁移被拒绝的原因（诊断用）。
class PhaseRejection {
  const PhaseRejection({
    required this.from,
    required this.to,
    required this.reason,
  });

  final GamePhase from;
  final GamePhase to;
  final String reason;

  @override
  String toString() => 'PhaseRejection(${from.name} -> ${to.name}: $reason)';
}

/// 相位状态机。
class PhaseController {
  PhaseController({GamePhase initialPhase = GamePhase.home})
    : _phase = initialPhase;

  GamePhase _phase;
  PhaseRejection? _lastRejection;

  GamePhase get phase => _phase;

  /// 上一次被拒绝的迁移；成功迁移后清空。
  PhaseRejection? get lastRejection => _lastRejection;

  bool get isPaused => _phase == GamePhase.paused;

  /// 是否处于「冻结全部逻辑时钟」的状态。
  bool get freezesLogic => _phase.freezesAllClocks;

  /// 尝试迁移到 [to]。
  ///
  /// 成功返回可直接发出的 [PhaseChanged]；非法迁移返回 null，
  /// 并通过 [lastRejection] 记录具体原因（不抛异常，以免在帧循环里崩溃）。
  PhaseChanged? transitionTo(GamePhase to, {required String reason}) {
    if (to == _phase) {
      // 幂等地视为成功但无需广播，避免重复事件污染回放。
      _lastRejection = null;
      return null;
    }
    if (!isPhaseTransitionAllowed(_phase, to)) {
      _lastRejection = PhaseRejection(
        from: _phase,
        to: to,
        reason: '不在合法迁移表中：$reason',
      );
      return null;
    }
    final from = _phase;
    _phase = to;
    _lastRejection = null;
    return PhaseChanged(from: from.name, to: to.name, reason: reason);
  }

  /// 统一的暂停命令。
  ///
  /// 语义（技术架构 §3.1）：
  ///   * 只在 [GamePhase.playing] 生效 —— 其余状态下逻辑时钟本就被冻结
  ///     （见 [GamePhaseSemantics.freezesAllClocks]），再进暂停没有意义，
  ///     而且会丢失"从哪个界面暂停"的信息；
  ///   * 已经在 [GamePhase.paused] 时**幂等**返回 null，
  ///     不产生第二条事件 —— 平台可能连续上报失焦；
  ///   * 恢复必须由玩家显式触发（[requestResume]），不做自动继续。
  PhaseChanged? requestPause(PauseSource source) {
    if (_phase == GamePhase.paused) {
      return null; // 幂等
    }
    if (_phase != GamePhase.playing) {
      _lastRejection = PhaseRejection(
        from: _phase,
        to: GamePhase.paused,
        reason: '当前相位不推进战斗逻辑，无需暂停',
      );
      return null;
    }
    return transitionTo(
      GamePhase.paused,
      reason: 'pause:${source.name}',
    );
  }

  /// 玩家显式恢复。
  PhaseChanged? requestResume() {
    if (_phase != GamePhase.paused) {
      _lastRejection = PhaseRejection(
        from: _phase,
        to: GamePhase.playing,
        reason: '只有暂停中才能继续',
      );
      return null;
    }
    return transitionTo(GamePhase.playing, reason: 'resume:user');
  }

  /// 复位到首页（释放一局时调用）。
  void resetToHome() {
    _phase = GamePhase.home;
    _lastRejection = null;
  }
}
