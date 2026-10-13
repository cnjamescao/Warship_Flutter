// ================================================================
// lib/game/core/render_snapshot.dart —— 表现层只读快照
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
  });

  final EntityId id;
  final Vec2 position;
  final double radius;

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
    required this.series,
    required this.currentLevel,
    required this.maxLevel,
    this.isGuaranteed = false,
  });

  final String cardId;
  final String nameKey;
  final String descKey;
  final String iconAssetId;
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

/// 一帧的完整只读快照。
class RenderSnapshot {
  const RenderSnapshot({
    required this.frameIndex,
    required this.phase,
    required this.player,
    required this.enemies,
    required this.projectiles,
    required this.hazards,
    required this.hud,
    this.upgradeDraft,
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
    hud: null,
    upgradeDraft: null,
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
  final HudView? hud;

  /// 当前的升级草案；null 表示不在选卡状态。
  final DraftView? upgradeDraft;

  final bool isPlayerInvulnerable;
  final int activeEnemyCount;
  final bool isBossActive;
}
