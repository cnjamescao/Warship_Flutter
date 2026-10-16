// ================================================================
// lib/game/core/game_phase.dart —— 运行状态机
//
// **架构位置**：Core（运行时骨架） —— 按固定顺序驱动 Domain、结算伤害与实体增删、产出**不可变快照**与事件。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：仅 `Playing` 推进逻辑 · 实体增删经待提交队列统一提交（避免遍历中改集合）· 快照不可变。
//
// **本文件是"什么时候规则在跑"的唯一权威**。
//
// **要点与易错点**：
//   * **只有 `playing` 推进逻辑** —— `GameRuntime._stepOnce()` 在相位门禁处
//     对非 `playing` **提前返回**。这一条同时实现了两件事：
//       ① 暂停/草案/风险门/结算期间，**所有逻辑时钟冻结**；
//       ② **预警在暂停时被"冻结"而非取消**（协议 §3.2 要求）——
//          逻辑时钟不前进，到期时间自然不推移。
//     若要新增"冻结语义"，请先确认它是否自动由此机制满足，
//     **不要另写一套暂停逻辑**。
//   * **死亡优先于同帧击杀**；同帧 Boss 击败与玩家死亡时**判胜**。
//   * 相位切换必须经 `PhaseController`，**不得直接改字段** ——
//     切换会带 `reason` 并触发事件，供生命周期测试断言。
//   * 新增相位时需同步：① `advancesLogic` 语义；② 各相位的视觉与音频；
//     ③ 是否应清空待执行攻击/危险区（取消语义）。
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §3.1
//
// 唯一状态集合：
//   Home → Loading → Briefing → Playing ↔ UpgradeDraft/RiskGate/Paused → Result
//
// 冻结语义（产品基线 §3.1）：
//   UpgradeDraft / RiskGate / Paused 冻结**全部逻辑时钟** ——
//   实体更新、投射物、生成、Buff、无敌以及动画帧以外的计时全部停止。
// ================================================================

/// 运行状态。
///
/// 名称与产品基线 §3.1 的状态集合一一对应，不得增删。
enum GamePhase {
  /// 首页：逻辑停止，只接受 UI。
  home,

  /// 加载中：逻辑停止；失败只能回 Home。
  loading,

  /// 开局简报：只有表现时钟；移动/攻击无效。
  briefing,

  /// 战斗进行中：全部逻辑时钟推进。
  playing,

  /// 升级三选一：**全部逻辑冻结**，只接受选卡。
  upgradeDraft,

  /// 风险门：**全部逻辑冻结**，只接受选项；超时执行保底。
  riskGate,

  /// 暂停：**全部逻辑冻结**，不清除局内对象。
  paused,

  /// 结算：逻辑停止，只接受结算操作。
  result,
}

/// 相位相关的语义查询，集中放置以免各处自行判断出错。
extension GamePhaseSemantics on GamePhase {
  /// 是否推进战斗逻辑。
  ///
  /// 只有 [GamePhase.playing] 会改变逻辑帧、坐标、冷却、Buff 与 Director。
  bool get advancesLogic => this == GamePhase.playing;

  /// 是否为「冻结全部逻辑时钟」的状态。
  ///
  /// 这些状态下 Domain 不得推进任何 Timer（含无敌、冷却、护盾恢复、连击衰减）。
  bool get freezesAllClocks =>
      this == GamePhase.upgradeDraft ||
      this == GamePhase.riskGate ||
      this == GamePhase.paused;

  /// 是否允许接受战斗输入（移动 / 冲刺）。
  bool get acceptsCombatInput => this == GamePhase.playing;

  /// 是否处于一次对局之内（用于判断是否需要 RunSession）。
  bool get isInRun =>
      this == GamePhase.briefing ||
      this == GamePhase.playing ||
      this == GamePhase.upgradeDraft ||
      this == GamePhase.riskGate ||
      this == GamePhase.paused ||
      this == GamePhase.result;
}

/// 非法的相位迁移。
class InvalidPhaseTransition implements Exception {
  const InvalidPhaseTransition(this.from, this.to);

  final GamePhase from;
  final GamePhase to;

  @override
  String toString() => 'InvalidPhaseTransition: ${from.name} -> ${to.name}';
}

/// 状态机的合法迁移表。
///
/// 依据产品基线 §3.1「`Loading` 失败只能回 `Home`；`Result` 只能重开或返回 `Home`」，
/// 以及产品设计文档 §4.2 的交互状态机。
const Map<GamePhase, Set<GamePhase>> kAllowedPhaseTransitions =
    <GamePhase, Set<GamePhase>>{
      GamePhase.home: <GamePhase>{GamePhase.loading},
      GamePhase.loading: <GamePhase>{GamePhase.briefing, GamePhase.home},
      GamePhase.briefing: <GamePhase>{GamePhase.playing, GamePhase.home},
      GamePhase.playing: <GamePhase>{
        GamePhase.upgradeDraft,
        GamePhase.riskGate,
        GamePhase.paused,
        GamePhase.result,
      },
      GamePhase.upgradeDraft: <GamePhase>{GamePhase.playing, GamePhase.paused},
      GamePhase.riskGate: <GamePhase>{GamePhase.playing, GamePhase.paused},
      GamePhase.paused: <GamePhase>{
        GamePhase.playing,
        // 暂停菜单允许「重新开始」与「返回首页」：
        GamePhase.loading,
        GamePhase.home,
        GamePhase.result,
      },
      GamePhase.result: <GamePhase>{GamePhase.loading, GamePhase.home},
    };

/// 校验一次迁移是否合法。
bool isPhaseTransitionAllowed(GamePhase from, GamePhase to) {
  if (from == to) {
    return true;
  }
  return kAllowedPhaseTransitions[from]?.contains(to) ?? false;
}
