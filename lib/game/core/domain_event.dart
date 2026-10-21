// ================================================================
// lib/game/core/domain_event.dart —— 领域事件基类与 Core 事件
//
// **架构位置**：Core（运行时骨架） —— 按固定顺序驱动 Domain、结算伤害与实体增删、产出**不可变快照**与事件。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：仅 `Playing` 推进逻辑 · 实体增删经待提交队列统一提交（避免遍历中改集合）· 快照不可变。
//
// **本文件定义"Core 对外广播什么"** —— 音频、触觉、表现层都只是**消费者**。
//
// **要点与易错点**：
//   * **事件不可变**，且事件总线内**最多保留最近 256 条**（供调试与回放）。
//     这意味着：**不要把事件当持久状态用** —— 需要历史就写入 recorder。
//   * **音频与 VFX 只能消费事件，不得反向改变 Domain**（架构 §7）。
//     这条是"表现不影响规则"在事件层的体现。
//   * **状态阈值以"事件完成结算后的 `*After` / `*Ratio`"为准**，
//     不要用结算前的值判断档位。例如 HP 档位为
//     `>30% normal` / `(10%,30%] low` / `≤10% critical`。
//   * **`PlayerDamaged` 的 120 ms `hit` 只是临时表现**：结束后必须立刻
//     依据最后一份 `PlayerVitalStateChanged` 重取 normal/low/critical，
//     **不能停留在 `hit`**；敌机 `hit` 同样固定 120 ms，
//     而敌机 `critical` 是 HP ≤25% 的**持久**状态。
//   * **每一个 `EnemyAttack*` 必须同时携带 `enemyId` 与 `attackId`**；
//     每一个 `BossAttack*` 必须携带 `attackId`（协议 §3.1）。
//   * **事件名与字段是稳定合同**：改名等同破坏协议，需走变更流程。
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
    required this.reason,
  });

  /// `victory` 或 `defeat`。
  final String result;
  final double durationSeconds;
  final int score;
  final int seed;
  final double bossHpRatio;

  /// 结算奖牌：`gold` / `silver` / `bronze` / `none`。
  ///
  /// 算法见 `lib/game/domain/result_tier.dart`：胜利 gold；
  /// 失败且曾把 Boss 打进 P3（bossHpRatio < 0.35）silver；其余失败 bronze。
  ///
  /// **注意**：产品基线 §8 与技术协议 §3.1 对算法有冲突，
  /// 已按交付清单 §8 的优先级（产品基线优先）裁决，
  /// 因此**不产生 `none`**。完整裁决记录见该文件头。
  final String resultTier;

  /// **结束原因**（v2.1 / 蓝图 §3.1）。
  ///
  /// 取值**只能是**：`bossDefeated` / `sectorCleared` / `playerDead` / `timeLimit`。
  /// 由 `GameRuntime` 唯一决定，**App 层禁止重算**
  /// （蓝图 §4.2：「`_onRunFinished` 不得重新计算奖章」）。
  ///
  /// 为什么要单列：v2.1 起**胜利有两条路**（击败 Boss / 清场），
  /// 失败也有两条路（阵亡 / 190 秒判负）。只看 `result` 无法区分
  /// 「清场胜利」与「Boss 击败」，也无法区分「阵亡」与「超时」。
  final String reason;

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
    this.affixId,
  });

  final EntityId entityId;
  final String enemyId;
  final Vec2 position;
  final bool isElite;

  /// 精英词缀 ID（普通敌人为 null）。
  ///
  /// 素材侧把词缀图标按 `isElite + affixId` **精确路由**
  /// （`UI-ELITE-AFFIX-ACCEL/SHIELD/BARRAGE` 的绑定条件即为此二字段）。
  /// 没有它，三个词缀图标**无法区分**，只能都靠外环 —— 而外环的颜色
  /// 正是色弱场景下不可靠的那一维。因此这个字段是 F-21 的必需传输项。
  final String? affixId;

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
    this.weaponStyleId,
  });

  final String weaponId;
  final EntityId sourceId;
  final Vec2 position;
  final Vec2 direction;

  /// **五种主弹道的稳定 style ID**（v2.1 / 蓝图 §3.1）。
  ///
  /// 旧主炮与副武器传 `null`；五个 `UP-WSTYLE-*` 形态传
  /// `prism`/`arc`/`plasma`/`needle`/`missile`。
  /// manifest 用它做**等值** `when` 路由（命中 cue / 命中图）。
  final String? weaponStyleId;

  @override
  String get eventType => 'WeaponFired';
}

/// 命中。
class WeaponHit extends DomainEvent {
  // **v2.1（技术协议 §…）**：`targetIsBoss` 必须由 **Domain 在命中时写入**
  // 不可变布尔值；Presentation 与 AudioDirector **不得**用
  // `targetEnemyId` 字符串或画面状态去推断。
  //
  // 为什么强调"不可推断"：`targetEnemyId == 'boss.aegis'` 今天成立，
  // 但一旦换 Boss ID、或加第二个 Boss，推断就**静默失配** ✗ ——
  // 而路由错了只会"听起来不对"，不会报错。

  const WeaponHit({
    required this.weaponId,
    required this.sourceId,
    required this.targetId,
    required this.critical,
    required this.damage,
    this.targetEnemyId,
    this.weaponStyleId,
    this.targetIsBoss = false,
  });

  final String weaponId;
  final EntityId sourceId;
  final EntityId targetId;
  final bool critical;
  final int damage;
  final String? targetEnemyId;

  /// 命中目标是否是 Boss（由 Domain 写入，见类注释）。
  final bool targetIsBoss;

  /// 同 [WeaponFired.weaponStyleId]：命中资源路由用（v2.1）。
  final String? weaponStyleId;

  @override
  String get eventType => 'WeaponHit';
}

/// **自动强化授予**（v2.1 / 冻结表 §2.2）。
///
/// v2.1 起标准 XP 路径**不再打开三选一草案**：达标即**单张**授予，
/// 直接 `applyCard` 一次并广播本事件（冻结表 §2.2 原文：
/// 「**禁止创建 `DraftOffer`、进入 `UpgradeDraft` 或等待输入**」）。
///
/// 消费方：`UI-V21-UPGRADE-NOTICE` + `SFX-V21-UPGRADE-GAIN`
/// （见 manifest 的 `AutoUpgradeGranted` 路由）；Toast 用
/// `nameKey`/`descKey` 从 catalog 解析文案，**不得**直接显示 key。
class AutoUpgradeGranted extends DomainEvent {
  const AutoUpgradeGranted({
    required this.grantOrdinal,
    required this.cardId,
    required this.level,
    required this.nameKey,
    required this.descKey,
    this.styleId,
  });

  /// 本局第几次自动强化（0 起）—— 冻结表 §2.2：
  /// 「`grantOrdinal` 从 0 开始，且必须作为快照/回放状态保存」。
  final int grantOrdinal;
  final String cardId;

  /// 授予后的**新等级**（不是增量）。
  final int level;

  /// 文案 key（供 Toast 解析成中文）。
  final String nameKey;
  final String descKey;

  /// 若这张卡是五种主弹道形态之一，给出其 style ID。
  final String? styleId;

  @override
  String get eventType => 'AutoUpgradeGranted';
}

/// **清场确认窗开始**（v2.1 / 技术协议 §3.2、蓝图 §4.1）。
///
/// 四条件同时满足的那一逻辑步产生本事件，并进入固定 **0.8 s** 确认窗；
/// 期间任何新威胁都会产生 [SectorClearCancelled]。
class SectorClearStarted extends DomainEvent {
  const SectorClearStarted();

  @override
  String get eventType => 'SectorClearStarted';
}

/// 清场确认窗**被取消**（确认期内出现新威胁）。
class SectorClearCancelled extends DomainEvent {
  const SectorClearCancelled({required this.reason});

  /// 取消原因（诊断用）。取值如 `newThreat` / `phaseChanged` / `bossRevived`。
  final String reason;

  @override
  String get eventType => 'SectorClearCancelled';
}

/// 清场**确认成功** —— 唯一的"清场胜利"来源，随后由 `GameRuntime`
/// 产生 `RunEnded(victory, reason=sectorCleared)`。
class SectorClearConfirmed extends DomainEvent {
  const SectorClearConfirmed();

  @override
  String get eventType => 'SectorClearConfirmed';
}

/// 升级草案开启（产品基线 §4.2）。
class UpgradeDraftOpened extends DomainEvent {
  const UpgradeDraftOpened({
    required this.draftIndex,
    required this.candidateIds,
  });

  /// 第几次草案（0 起）。
  final int draftIndex;

  /// 候选卡 ID，**顺序已固定**。
  final List<String> candidateIds;

  @override
  String get eventType => 'UpgradeDraftOpened';
}

/// 玩家选定一张升级卡。
class UpgradeSelected extends DomainEvent {
  const UpgradeSelected({required this.cardId, required this.newLevel});

  final String cardId;
  final int newLevel;

  @override
  String get eventType => 'UpgradeSelected';
}

/// 事件：Boss 阶段变化 / 招式 / 濒毁 / 击败 / 补给。
class BossPhaseChanged extends DomainEvent {
  const BossPhaseChanged({required this.phase});
  final String phase;
  @override
  String get eventType => 'BossPhaseChanged';
}

class BossAttackTelegraphed extends DomainEvent {
  const BossAttackTelegraphed({
    required this.attackId,
    required this.position,
    required this.telegraphSeconds,
  });
  final String attackId;
  final Vec2 position;
  final double telegraphSeconds;
  @override
  String get eventType => 'BossAttackTelegraphed';
}

class BossAttackFired extends DomainEvent {
  const BossAttackFired({
    required this.attackId,
    required this.position,
    required this.telegraphSeconds,
  });
  final String attackId;
  final Vec2 position;
  final double telegraphSeconds;
  @override
  String get eventType => 'BossAttackFired';
}

class BossAttackEnded extends DomainEvent {
  const BossAttackEnded({required this.attackId});
  final String attackId;
  @override
  String get eventType => 'BossAttackEnded';
}

class BossCriticalReached extends DomainEvent {
  const BossCriticalReached({required this.hpRatio});
  final double hpRatio;
  @override
  String get eventType => 'BossCriticalReached';
}

class BossDefeated extends DomainEvent {
  const BossDefeated();
  @override
  String get eventType => 'BossDefeated';
}

class PickupHeal extends DomainEvent {
  const PickupHeal({required this.amount});
  final int amount;
  @override
  String get eventType => 'PickupHeal';
}

class PickupShield extends DomainEvent {
  const PickupShield({required this.amount});
  final int amount;
  @override
  String get eventType => 'PickupShield';
}

class DashReady extends DomainEvent {
  const DashReady();
  @override
  String get eventType => 'DashReady';
}

/// 风险门开启（产品基线 §7.1）。
class RiskGateOpened extends DomainEvent {
  const RiskGateOpened({
    required this.gateId,
    required this.availableOptionIds,
    required this.lockedOptionIds,
  });

  final String gateId;
  final List<String> availableOptionIds;
  final List<String> lockedOptionIds;

  @override
  String get eventType => 'RiskGateOpened';
}

/// 风险门选定（含超时保底，`wasTimeout` 为 true）。
class RiskSelected extends DomainEvent {
  const RiskSelected({
    required this.gateId,
    required this.optionId,
    required this.wasTimeout,
  });

  final String gateId;
  final String optionId;
  final bool wasTimeout;

  @override
  String get eventType => 'RiskSelected';
}
