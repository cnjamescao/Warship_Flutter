// ================================================================
// lib/game/core/domain_event.dart —— 领域事件基类与 Core 事件
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §3
//   「事件必须不可变、有 runId、frameIndex、递增 eventIndex。」
//   「同一帧排序以系统顺序再以实体 ID 排序，确保回放一致。」
//
// 工作包纪律（03_实施工作包与交付标准.md §3）：
//   「任何新 DomainEvent 必须同时提交：事件定义、至少一个生产者、
//     至少一个表现/测试消费者。」
// 因此本文件只声明**已经在 Core 内有生产者与消费者**的事件；
// 战斗事件随对应系统（WP-03 起）逐个加入。
// ================================================================

import '../domain/values.dart';

/// 领域事件负载。
///
/// 只包含业务字段；`runId` / `frameIndex` / `eventIndex` 由 [EventBus] 盖章，
/// 生产者不需要（也不应该）自己维护这些元数据。
abstract class DomainEvent {
  const DomainEvent();

  /// 稳定的事件类型名，用于调试面板、回放比较与测试断言。
  ///
  /// 与协议 §3 表格中的事件名一致，不得随意改名。
  String get eventType;
}

/// 相位迁移完成。
///
/// 生产者：`PhaseController`。消费者：调试面板、生命周期测试。
class PhaseChanged extends DomainEvent {
  const PhaseChanged({required this.from, required this.to, required this.reason});

  final String from;
  final String to;
  final String reason;

  @override
  String get eventType => 'PhaseChanged';

  @override
  String toString() => 'PhaseChanged($from -> $to, $reason)';
}

/// 一局开始（Briefing 结束、进入 Playing 的那一刻）。
///
/// 生产者：`PhaseController`。消费者：回放记录、调试、测试。
class RunStarted extends DomainEvent {
  const RunStarted({
    required this.seed,
    required this.prngAlgorithm,
    required this.contentVersion,
  });

  final int seed;
  final String prngAlgorithm;
  final String contentVersion;

  @override
  String get eventType => 'RunStarted';

  @override
  String toString() =>
      'RunStarted(seed=$seed, prng=$prngAlgorithm, content=$contentVersion)';
}

/// 一局结束。
///
/// 生产者：`PhaseController`（进入 Result）。
/// 消费者：结算界面、本地记录、回放校验。
class RunEnded extends DomainEvent {
  const RunEnded({
    required this.result,
    required this.durationSeconds,
    required this.score,
    required this.seed,
    required this.bossHpRatio,
    required this.resultTier,
  });

  /// `victory` 或 `defeat`。
  final String result;
  final double durationSeconds;
  final int score;
  final int seed;
  final double bossHpRatio;

  /// 结算奖牌：`gold` / `silver` / `bronze` / `none`。
  ///
  /// 算法由协议 §3.1 固定：胜利 gold；失败但曾进入 Boss P3（bossHpRatio < 0.35）
  /// silver；失败且存活 ≥120 s bronze；其余 none。优先级 gold > silver > bronze > none。
  final String resultTier;

  @override
  String get eventType => 'RunEnded';
}

// ================================================================
// 战斗事件（WP-07 加入）
// ================================================================
// 工作包纪律（03_实施工作包与交付标准.md §3）：
//   「任何新 DomainEvent 必须同时提交：事件定义、至少一个生产者、
//     至少一个表现/测试消费者。」
//
// 消费者：`AssetBindingTable`（lib/game/infrastructure/asset_loader.dart）
// 已为下列每个事件建立了精确的 `event + when` 路由，见 manifest.json。
// 本文件的字段名必须与 manifest 的 `when` 条件键保持一致 ——
// 这正是资源路由能工作的前提。
// ================================================================

/// 玩家受到伤害。
class PlayerDamaged extends DomainEvent {
  const PlayerDamaged({
    required this.sourceType,
    required this.shieldDamage,
    required this.hpDamage,
    required this.hpAfter,
    required this.shieldAfter,
    this.direction,
  });

  final String sourceType;
  final int shieldDamage;
  final int hpDamage;
  final int hpAfter;
  final int shieldAfter;

  /// 8 向受击指示（`north`/`northEast`/…）。
  final String? direction;

  @override
  String get eventType => 'PlayerDamaged';
}

/// 玩家数值或阈值状态实际变化。
class PlayerVitalStateChanged extends DomainEvent {
  const PlayerVitalStateChanged({
    required this.hp,
    required this.hpMax,
    required this.shield,
    required this.shieldMax,
    required this.cause,
  });

  final int hp;
  final int hpMax;
  final int shield;
  final int shieldMax;
  final String cause;

  double get hpRatio => hpMax == 0 ? 0 : hp / hpMax;
  double get shieldRatio => shieldMax == 0 ? 0 : shield / shieldMax;

  @override
  String get eventType => 'PlayerVitalStateChanged';
}

/// 敌人生成。
class EnemySpawned extends DomainEvent {
  const EnemySpawned({
    required this.entityId,
    required this.enemyId,
    required this.position,
    required this.isElite,
  });

  final EntityId entityId;
  final String enemyId;
  final Vec2 position;
  final bool isElite;

  @override
  String get eventType => 'EnemySpawned';
}

/// 敌人被击毁。
class EnemyDestroyed extends DomainEvent {
  const EnemyDestroyed({
    required this.entityId,
    required this.enemyId,
    required this.position,
    required this.isElite,
  });

  final EntityId entityId;
  final String enemyId;
  final Vec2 position;
  final bool isElite;

  @override
  String get eventType => 'EnemyDestroyed';
}

/// 敌人受伤（用于 `hit` 临时状态与 `hpRatioLte` 的临界状态）。
class EnemyDamaged extends DomainEvent {
  const EnemyDamaged({
    required this.entityId,
    required this.enemyId,
    required this.damage,
    required this.hpAfter,
    required this.hpMax,
  });

  final EntityId entityId;
  final String enemyId;
  final int damage;
  final int hpAfter;
  final int hpMax;

  double get hpRatio => hpMax == 0 ? 0 : hpAfter / hpMax;

  @override
  String get eventType => 'EnemyDamaged';
}

/// 敌人越过 y=1140 发生突破（`isWarningOnly` 为 true 时是 y=920 的预警）。
class EnemyBreached extends DomainEvent {
  const EnemyBreached({
    required this.entityId,
    required this.enemyId,
    required this.isElite,
    required this.breachHpDamage,
    required this.position,
    this.isWarningOnly = false,
  });

  final EntityId entityId;
  final String enemyId;
  final bool isElite;
  final int breachHpDamage;
  final Vec2 position;
  final bool isWarningOnly;

  @override
  String get eventType => 'EnemyBreached';
}

/// 敌方招式预警（必须先于伤害）。
class EnemyAttackTelegraphed extends DomainEvent {
  const EnemyAttackTelegraphed({
    required this.entityId,
    required this.enemyId,
    required this.attackId,
    required this.position,
    required this.telegraphSeconds,
  });

  final EntityId entityId;
  final String enemyId;
  final String attackId;
  final Vec2 position;
  final double telegraphSeconds;

  @override
  String get eventType => 'EnemyAttackTelegraphed';
}

/// 敌方招式发射。
class EnemyAttackFired extends DomainEvent {
  const EnemyAttackFired({
    required this.entityId,
    required this.enemyId,
    required this.attackId,
    required this.position,
    required this.telegraphSeconds,
  });

  final EntityId entityId;
  final String enemyId;
  final String attackId;
  final Vec2 position;
  final double telegraphSeconds;

  @override
  String get eventType => 'EnemyAttackFired';
}

/// 我方武器发射。
class WeaponFired extends DomainEvent {
  const WeaponFired({
    required this.weaponId,
    required this.sourceId,
    required this.position,
    required this.direction,
  });

  final String weaponId;
  final EntityId sourceId;
  final Vec2 position;
  final Vec2 direction;

  @override
  String get eventType => 'WeaponFired';
}

/// 命中。
class WeaponHit extends DomainEvent {
  const WeaponHit({
    required this.weaponId,
    required this.sourceId,
    required this.targetId,
    required this.critical,
    required this.damage,
    this.targetEnemyId,
  });

  final String weaponId;
  final EntityId sourceId;
  final EntityId targetId;
  final bool critical;
  final int damage;
  final String? targetEnemyId;

  @override
  String get eventType => 'WeaponHit';
}
