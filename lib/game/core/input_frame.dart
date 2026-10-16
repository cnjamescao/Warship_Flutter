// ================================================================
// lib/game/core/input_frame.dart —— 单帧输入快照
//
// **架构位置**：Core（运行时骨架） —— 按固定顺序驱动 Domain、结算伤害与实体增删、产出**不可变快照**与事件。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：仅 `Playing` 推进逻辑 · 实体增删经待提交队列统一提交（避免遍历中改集合）· 快照不可变。
//
// **本文件定义"一个逻辑步能看到的全部输入"** —— 输入契约的唯一权威。
//
// **要点与易错点**：
//   * **每个逻辑步只接受一个不可变 `InputFrame`**：
//     同一渲染帧若跑多个逻辑步，**同一步的输入会被复用** ——
//     这是"输入与帧率解耦"的实现方式，不要改成每步重新采样设备。
//   * **边沿字段（`dashPressed`/`pausePressed`）只在"按下的那一步"为 true**：
//     若在别处把它当"按住状态"用，会出现连发或重复触发。
//     **持续输入用 `moveX`/`moveY`，一次性动作用边沿字段。**
//   * **失焦 / 页面隐藏 / 离开 Playing 时必须清空所有持续与边沿输入**：
//     否则恢复后会"粘键"—— 玩家松手了但角色还在移动或射击。
//     暂停路径已显式 `input.clear()`，新增"离开 Playing"的路径时
//     务必同样处理。
//   * **移动向量必须归一化**：键盘对角不得比单轴更快（产品基线）。
//   * 键盘 Space 与 Shift **都**映射冲刺，但**同一步只触发一次**。
//   * 本结构**不可变**：表现层可以读，不得改。
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
