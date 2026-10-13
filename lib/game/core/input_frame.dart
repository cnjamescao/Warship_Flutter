// ================================================================
// lib/game/core/input_frame.dart —— 单帧输入快照
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §2.1
//   `InputGateway` 的输入 → `InputFrame`；「不保留已失焦按键」。
//   02_运行时与数据协议.md §4
//   「每个逻辑步接收并锁定本步 InputFrame。」
//
// 关键设计：InputFrame 是**不可变快照**，而不是对输入设备的引用。
// 逻辑步一开头就锁定它，之后无论玩家怎么操作都不影响本步计算 ——
// 这是"同一 seed + 同一输入序列可回放"的前提。
// ================================================================

import '../domain/values.dart';

/// 一个逻辑步内锁定的输入。
class InputFrame {
  const InputFrame({
    this.moveDirection = Vec2.zero,
    this.dashRequested = false,
    this.pauseRequested = false,
    this.cardSelection,
    this.riskSelection,
  });

  /// 无输入的中性帧（用于非 Playing 状态与测试）。
  static const InputFrame idle = InputFrame();

  /// 期望的移动方向。
  ///
  /// 未单位化：键盘传 `(±1, ±1)` 表示八向，触摸传「目标点 - 当前位置」。
  /// 由 `PlayerSystem` 负责单位化，因此斜向不会因未归一化而变快。
  final Vec2 moveDirection;

  /// 本步是否请求冲刺（按下瞬间为 true，只在一帧有效）。
  final bool dashRequested;

  /// 本步是否请求暂停。
  final bool pauseRequested;

  /// 本步选择的升级卡索引（0/1/2），null 表示未选择。
  final int? cardSelection;

  /// 本步选择的风险门选项 ID，null 表示未选择。
  final String? riskSelection;

  bool get hasMoveInput =>
      moveDirection.x != 0 || moveDirection.y != 0;

  /// 单位化后的移动方向；无输入时为 [Vec2.zero]。
  Vec2 get normalizedMove =>
      hasMoveInput ? moveDirection.normalized : Vec2.zero;

  InputFrame copyWith({
    Vec2? moveDirection,
    bool? dashRequested,
    bool? pauseRequested,
    int? cardSelection,
    String? riskSelection,
  }) => InputFrame(
    moveDirection: moveDirection ?? this.moveDirection,
    dashRequested: dashRequested ?? this.dashRequested,
    pauseRequested: pauseRequested ?? this.pauseRequested,
    cardSelection: cardSelection ?? this.cardSelection,
    riskSelection: riskSelection ?? this.riskSelection,
  );

  /// 清空移动与冲刺（失焦时使用）。
  ///
  /// 技术架构 §3.2：「GameScreen.dispose 负责…清空输入」；
  /// 失焦必须清空，否则玩家切回来会发现战机一直在往一个方向飘。
  InputFrame cleared() => InputFrame(
    cardSelection: cardSelection,
    riskSelection: riskSelection,
  );

  @override
  bool operator ==(Object other) =>
      other is InputFrame &&
      other.moveDirection == moveDirection &&
      other.dashRequested == dashRequested &&
      other.pauseRequested == pauseRequested &&
      other.cardSelection == cardSelection &&
      other.riskSelection == riskSelection;

  @override
  int get hashCode => Object.hash(
    moveDirection,
    dashRequested,
    pauseRequested,
    cardSelection,
    riskSelection,
  );

  @override
  String toString() =>
      'InputFrame(move=$moveDirection, dash=$dashRequested, '
      'pause=$pauseRequested, card=$cardSelection, risk=$riskSelection)';
}
