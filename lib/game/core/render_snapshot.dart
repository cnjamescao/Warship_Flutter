// ================================================================
// lib/game/core/render_snapshot.dart —— 表现层只读快照
//
// **架构位置**：Core（运行时骨架） —— 按固定顺序驱动 Domain、结算伤害与实体增删、产出**不可变快照**与事件。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：仅 `Playing` 推进逻辑 · 实体增删经待提交队列统一提交（避免遍历中改集合）· 快照不可变。
//
// **本文件是 Core 与 Presentation 之间唯一的契约面** ——
//   表现层能看到的**全部**信息都在这里，它看不到任何可变实体。
//
// **要点与易错点**：
//   * **`RenderSnapshot.phase` 是 `String` 而不是 `GamePhase` 枚举** ——
//     这是刻意的：快照要能跨层传递且不泄漏 Core 类型。
//     比较时请用 `GamePhase.playing.name`，不要硬编码字面量。
//   * **快照必须不可变**：表现层只读，**不得持有可变引用**。
//     列表一律用 `List.unmodifiable` 包装。
//   * **`TelegraphView` 是独立不可变结构，禁止折叠进 `EntityView`**
//     （协议 §3.2 明文）。原因：预警是"**事件视觉**"，而实体是"**外观**"，
//     二者混用会导致实体被事件的资源替换（F-28 / F-31 的事故）。
//     由 `telegraph_view_test.dart` 静态断言 `EntityView` 内**不得**出现
//     `telegraph`/`aimTarget`/`remainingSeconds` 等字段。
//   * **预警几何由 Domain 在 t=0 锁定**（`TelegraphView.origin`/`aimTarget`），
//     表现层**不得**自行推算目标 —— 那会让预警逐帧跟随玩家，
//     玩家就失去了躲避机会。
//   * 新增快照字段时：**先确认它属于实体外观还是事件视觉** ——
//     这决定了它该进 `EntityView` 还是独立视图。
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §6
//   「Flame Component 以 entityId 绑定 Domain 实体；每帧只读取
//     RenderSnapshot 更新位置、动画、可见性和视觉状态。」
//   「HUD 由 Flutter ValueListenable / Stream 或等价不可变 ViewModel 驱动；
//     禁止 Widget 直接读取 Flame Component 私有字段。」
//
// 因此快照是**不可变**的、每帧重建的纯数据；表现层只读它，
// 不持有 Domain 对象的引用，也绝不回写。
// ================================================================

import '../domain/values.dart';

/// 渲染用的单个实体视图。
class EntityView {
  const EntityView({
    required this.id,
    required this.position,
    required this.radius,
    this.enemyId,
    this.hpRatio = 1.0,
    this.isElite = false,
    this.affixId,
    this.isBoss = false,
    this.isWeakpoint = false,
    this.isPlayerProjectile = false,
    this.rotationRadians = 0,
    this.assetId,
    this.visualState,
  });

  final EntityId id;
  final Vec2 position;
  final double radius;

  /// 敌人种类 ID（`EN-SCOUT` 等），用于事件路由的 `enemyId` 条件。
  final String? enemyId;

  final double hpRatio;
  final bool isElite;

  /// 精英词缀 ID（普通敌人为 null）。
  ///
  /// F-21 的渲染必需项：素材侧把词缀图标与词缀特有外环按
  /// `isElite + affixId` 路由。此前表现层只能拿到 `isElite`，
  /// 于是**三个词缀画成同一个金色圆** —— 颜色正是色弱场景下
  /// 不可靠的那一维，而词缀的差异恰恰是玩法信息。
  final String? affixId;
  final bool isBoss;
  final bool isWeakpoint;
  final bool isPlayerProjectile;

  /// 朝向（弧度）。资源默认机头向上，由表现层负责旋转。
  final double rotationRadians;

  /// 由资源路由表解析出的 Asset ID（可能为 null，表示用回退资源）。
  final String? assetId;

  /// 当前语义状态（`idle` / `hit` / `critical` / …）。
  final String? visualState;
}

/// 危险区视图。
class HazardView {
  const HazardView({
    required this.id,
    required this.position,
    required this.radius,
    required this.isWarning,
    required this.remainingRatio,
    this.assetId,
  });

  final EntityId id;
  final Vec2 position;
  final double radius;

  /// **F-36**：危险区的正式素材 ID（如 `GFX-HAZARD-BOMBER-ACTIVE`）。
  final String? assetId;

  /// true 表示还处于延迟预警（未生效），false 表示正在造成伤害。
  final bool isWarning;
  final double remainingRatio;
}

/// HUD 视图模型。
class HudView {
  const HudView({
    required this.hp,
    required this.hpMax,
    required this.shield,
    required this.shieldMax,
    required this.xp,
    required this.upgradeLevel,
    required this.score,
    required this.comboMultiplier,
    required this.combatSeconds,
    required this.dashCharges,
    required this.dashMaxCharges,
    required this.comboCount,
    this.bossHpRatio,
    this.bossPhase,
    this.objectiveWarning = false,
  });

  final int hp;
  final int hpMax;
  final int shield;
  final int shieldMax;
  final int xp;

  /// HUD 显示的 Lv（**不是**产品基线 §6 里的"升级数"）。
  final int upgradeLevel;

  final int score;
  final double comboMultiplier;
  final int comboCount;

  /// 有效战斗时间（不含暂停与升级选择）。
  final double combatSeconds;

  final int dashCharges;
  final int dashMaxCharges;

  final double? bossHpRatio;
  final String? bossPhase;

  /// 是否应显示"敌人正在逃逸"预警。
  final bool objectiveWarning;

  double get hpRatio => hpMax == 0 ? 0 : hp / hpMax;
  double get shieldRatio => shieldMax == 0 ? 0 : shield / shieldMax;

  /// 血量的语义状态（对应 `UI-HUD-HP-FILL` 的 normal/low/critical）。
  String get hpVisualState {
    if (hpRatio <= 0.25) {
      return 'critical';
    }
    if (hpRatio <= 0.35) {
      return 'low';
    }
    return 'normal';
  }

  /// 护盾的语义状态。
  String get shieldVisualState {
    if (shieldRatio <= 0.25) {
      return 'critical';
    }
    if (shieldRatio <= 0.5) {
      return 'low';
    }
    return 'normal';
  }

  String get dashVisualState => dashCharges > 0 ? 'ready' : 'cooldown';
}

/// 一张升级卡的显示数据。
class DraftCardView {
  const DraftCardView({
    required this.cardId,
    required this.nameKey,
    required this.descKey,
    required this.iconAssetId,
    required this.rarity,
    required this.series,
    required this.currentLevel,
    required this.maxLevel,
    this.isGuaranteed = false,
  });

  final String cardId;
  final String nameKey;
  final String descKey;
  final String iconAssetId;

  /// 稀有度（`common` / `rare` / `epic`）。
  ///
  /// F-12 需要它来合成稀有度的色弱叠层（`UI-COLORBLIND-PATTERN-RARITY`）——
  /// 裁决要求「草案稀有度」也必须有**颜色之外**的第二识别维度。
  final String rarity;
  final String series;
  final int currentLevel;
  final int maxLevel;

  /// 是否为本次的保证卡。
  final bool isGuaranteed;

  /// 选择后达到的等级。
  int get nextLevel => currentLevel + 1;
}

/// 升级草案的显示数据。
class DraftView {
  const DraftView({required this.draftIndex, required this.cards});

  final int draftIndex;
  final List<DraftCardView> cards;
}

/// 风险门的显示数据。
class RiskGateView {
  const RiskGateView({
    required this.gateId,
    required this.remainingSeconds,
    required this.availableOptionIds,
    required this.lockedOptionIds,
  });

  final String gateId;
  final double remainingSeconds;

  /// 可选项（顺序即 UI 顺序）。过载不可用时**不在此列表**。
  final List<String> availableOptionIds;

  /// 显示为锁定、不可选的项（HP ≤35 时的过载）。
  final List<String> lockedOptionIds;
}

/// **F-36：预警的独立不可变视图**（协议 §3.2）。
///
/// 协议明确要求：
/// * 渲染快照以**独立不可变 `TelegraphView`** 公开预警；
/// * **禁止**将其折叠为 `EntityView`；
/// * **禁止**由表现层猜测目标 —— 因此 `origin` / `aimTarget` / `shape`
///   全部由 Domain 在 t=0 锁定的原值直接给出。
///
/// 资产（`assetId`）**不在**这里解析：素材绑定属 manifest 路由，
/// 由表现层按 `attackId` 查绑定表取得 —— 这不是"猜目标"。
class TelegraphView {
  const TelegraphView({
    required this.attackId,
    required this.shape,
    required this.origin,
    required this.aimTarget,
    required this.remainingSeconds,
    required this.totalSeconds,
    this.enemyId,
    this.assetId,
  });

  /// 稳定枚举的招式 ID（`sniper_line` / `bomber_drop` / …）。
  final String attackId;

  /// 预警形状：`line` | `circle`（来自 t=0 锁定的 `telegraphShape`）。
  final String shape;

  /// t=0 锁定的源点。
  final Vec2 origin;

  /// t=0 锁定的瞄准点。
  /// * `line`：预警线沿 `origin → aimTarget` 射线，裁切到逻辑世界边界；
  /// * `circle`：落点即 `origin`（`bomber_drop` 的落点固定为 t=0 的 origin）。
  final Vec2 aimTarget;

  /// 预警剩余时间（秒）；≤0 表示已到期。
  final double remainingSeconds;

  /// 预警总时长（秒）。
  final double totalSeconds;

  /// 发出预警的敌机 ID（表现层用于层级/调试，不用于猜测几何）。
  final String? enemyId;

  /// **该招式配置的**预警素材 —— 由 Domain 在 t=0 一并锁定。
  ///
  /// 表现层**直接使用**它，不按 attackId 猜 manifest 绑定。
  final String? assetId;
}

/// 一帧的完整只读快照。
class RenderSnapshot {
  const RenderSnapshot({
    required this.frameIndex,
    required this.phase,
    required this.player,
    required this.enemies,
    required this.projectiles,
    required this.hazards,
    required this.telegraphs,
    required this.hud,
    this.upgradeDraft,
    this.riskGate,
    required this.isPlayerInvulnerable,
    required this.activeEnemyCount,
    required this.isBossActive,
  });

  /// 空快照（未开局时使用）。
  static const RenderSnapshot empty = RenderSnapshot(
    frameIndex: 0,
    phase: 'home',
    player: null,
    enemies: <EntityView>[],
    projectiles: <EntityView>[],
    hazards: <HazardView>[],
    telegraphs: <TelegraphView>[],
    hud: null,
    upgradeDraft: null,
    riskGate: null,
    isPlayerInvulnerable: false,
    activeEnemyCount: 0,
    isBossActive: false,
  );

  final int frameIndex;
  final String phase;
  final EntityView? player;
  final List<EntityView> enemies;
  final List<EntityView> projectiles;
  final List<HazardView> hazards;

  /// **F-36**：当前生效的预警（独立于 `enemies`，禁止折叠）。
  final List<TelegraphView> telegraphs;

  final HudView? hud;

  /// 当前的升级草案；null 表示不在选卡状态。
  final DraftView? upgradeDraft;

  /// 当前的风险门；null 表示不在风险门状态。
  final RiskGateView? riskGate;

  final bool isPlayerInvulnerable;
  final int activeEnemyCount;
  final bool isBossActive;
}
