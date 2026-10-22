// ================================================================
// lib/game/presentation/web_audio_unlock.dart —— Web 音频手势解锁（幂等）
//
// **架构位置**：Presentation 层。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**：（不变量、时序、平台限制、易错点）
// ================================================================

// **关键约束**（WEB-T-04）：
//   * **只 unlock 一次** —— 后续手势必须无副作用（否则会重复起 BGM ✗）；
//   * 用户**拒绝**（策略禁止/静音）时，**对局与输入照常** ✓ ——
//     音频失败绝不能阻断玩法（架构 §7）；
//   * unlock 后**不得重复播放 BGM**（"BGM 不叠加"是验收项 ✓）。
//
// **为什么需要它**：浏览器有自动播放策略 —— 页面**未经用户手势**
// 不允许发声。首次有效指针/键盘手势必须被用来"解锁"，
// 否则整局静音而**不报错** ✗（这正是我在 F-44 踩过的"静默无声"）。

import 'dart:ui' show VoidCallback;

/// **Web 音频解锁状态机**（幂等、纯逻辑、可单测）。
///
/// 生命周期：`locked` --首个有效手势--> `unlocked`（此后**永不**再变）
class WebAudioUnlock {
  /// 是否已解锁。
  bool get isUnlocked => _unlocked;
  bool _unlocked = false;

  /// 调用过多少次 `onGesture`（无论是否真的触发解锁）。
  ///
  /// 用于断言"只 unlock 一次"：**触发解锁**只会在第一次有效手势发生 ✓。
  int get gestureCount => _gestureCount;
  int _gestureCount = 0;

  /// **收到一次用户手势**。
  ///
  /// 返回 `true` 表示**本次**触发了真正的解锁动作（调用方据此执行
  /// "起播 BGM"之类的副作用）；返回 `false` 表示被忽略
  /// （已解锁过，或本次手势无效）。
  ///
  /// [isValid] 允许调用方过滤"无效手势"（例如 hover、按住不动），
  /// 默认任何手势都算有效。
  bool onGesture({bool isValid = true}) {
    _gestureCount++;
    if (_unlocked || !isValid) {
      return false; // 幂等：已解锁或无效手势，都不再触发副作用 ✓
    }
    _unlocked = true;
    return true;
  }

  /// 重置（仅测试/重开页面用；正常对局**不得**调用）。
  void resetForTest() {
    _unlocked = false;
    _gestureCount = 0;
  }
}

/// 解锁成功后要执行的副作用（起播 BGM 等）。
///
/// 单独抽出来是为了让调用点**只表达意图**："解锁了就起播"，
/// 而"只起播一次"由 [WebAudioUnlock] 保证 ✓。
typedef OnAudioUnlocked = void Function();

/// 便于测试的便捷封装：把手势喂给状态机，首次解锁时执行副作用。
VoidCallback bindUnlockCallback({
  required WebAudioUnlock unlock,
  required OnAudioUnlocked onFirstUnlock,
}) {
  return () {
    if (unlock.onGesture()) {
      onFirstUnlock();
    }
  };
}

