// ================================================================
// lib/game/core/game_runtime.dart —— 单帧运行时
// ================================================================
// **架构位置**：Core 层，**规则与表现的唯一交汇点**。
//   Domain 只提供"纯函数式"的系统（移动/伤害/波次…），
//   本文件负责按固定顺序驱动它们，并产出**不可变快照**供表现层绘制。
//
// **依据**：Spec/02_技术/v2.0/01_技术架构与模块设计.md §4（固定步进与单帧顺序）
//
// **与谁交互**：
//   * 上游：`V2Bootstrap.buildRuntime`（装配）、`GameClock`（固定步进）、
//     `InputFrame`（每步唯一输入）
//   * 下游：`DomainEvent`（经 `EventBus` 广播给音频/触觉/表现）、
//     `RenderSnapshot`（表现层的唯一数据来源）
//   * **表现层不得反向修改本类状态** —— 这是"表现不影响规则"的实现基础
//
// 每个逻辑步严格按以下顺序：
//   1. 锁定本步 InputFrame；处理边沿命令
//   2. 非 Playing → 只生成快照后结束本步
//   3. 推进计时器（冲刺/护盾恢复/连击衰减/Director/Boss）
//   4. 依锁定输入算玩家移动意图并夹紧边界
//   5. 更新敌人/Boss/投射物/危险区/无人机；只产生"待生成命令"
//   6. 目标选择与武器发射；新实体入待提交队列
//   7. 收集碰撞对；按层与事件序号排序；生成伤害意图
//   8. 合并伤害、应用无敌/护盾/HP、死亡、经验、掉落、分数、状态转移
//   9. 提交实体增删、发出不可变 DomainEvent、生成 RenderSnapshot
//
// 契约：**仅 Playing 推进逻辑**；不可重入。
//
// **关键约束（改动前务必阅读）**：
//   * 所有实体增删都必须经"待提交队列"在**第 9 步**统一提交，
//     避免在遍历过程中改动集合（历史上会触发 Concurrent modification）；
//   * **仅 `Playing` 推进逻辑** —— 暂停/草案/风险门/结算期间
//     `_stepOnce` 会在相位门禁处提前返回。这同时也是"待执行攻击
//     在暂停时被**冻结**（而非取消）"的实现方式（协议 §3.2）；
//   * 快照必须是**不可变**的：表现层只读，不得持有可变引用。
//
// **⚠️ 易错点（真实事故，按损失排序）**：
//   1. **`_pendingHazards` 曾经从未被填充** —— Bomber 的 hazard 配置
//      完备（半径 90 / 2.2s / 每 0.25s 8 点），但
//      `_spawnEnemyAttack` 在 `projectile == null` 时**直接 return**，
//      于是危险区从未创建、`_drawHazards` 永远画不出东西、
//      落点伤害完全缺失（F-36）。**新增攻击类型时必须检查这条早退。**
//   2. **危险区伤害曾经没有半径判定** —— 只要地图上存在危险区，
//      玩家在任何位置都会被扣血。协议原文是"每 0.25 s **每目标**"，
//      即**区内目标**。
//   3. **预警时序曾与发射同步** —— 同一逻辑步里连发
//      `*Telegraphed`、`*Fired` 并生成实体，导致预警时长对玩家
//      **完全无效**。现由 `_pendingAttacks` 队列延迟到
//      `startedAt + telegraphSeconds` 的**同一步**才发射。
//   4. **`bossSystem` 未注入时 Boss 永不出现**（见 `v2_bootstrap.dart`
//      文件头的记录，F-39，P0）。
// ================================================================

import 'dart:math' as math;

import '../domain/boss_system.dart';
import '../domain/collision.dart';
import '../domain/damage.dart';
import '../domain/director_system.dart';
import '../domain/enemy_system.dart';
import '../domain/player_system.dart';
import '../domain/risk_gate_system.dart';
import '../domain/upgrade_system.dart';
import '../presentation/v21_result_notice.dart';
import '../domain/result_tier.dart';
import '../domain/values.dart';
import '../infrastructure/audio_director.dart';
import '../infrastructure/haptics_director.dart';
import '../domain/weapon_system.dart';
import 'domain_event.dart';
import 'event_bus.dart';
import 'game_clock.dart';
import 'game_phase.dart';
import 'input_frame.dart';
import 'phase_controller.dart';
import 'random_source.dart';
import 'render_snapshot.dart';
import 'run_context.dart';

/// 投射物归属方。
enum ProjectileFaction { player, enemy }

/// 一个投射物。
class Projectile {
  Projectile({
    required this.id,
    required this.faction,
    required this.position,
    required this.direction,
    required this.speed,
    required this.radius,
    required this.damage,
    required this.lifetimeSeconds,
    required this.weaponId,
    this.ownerId,
    this.isCritical = false,
    this.attackId,
    this.assetId,
    this.weaponStyleId,
    this.projectileAssetId,
    this.impactAssetId,
    this.impactCueId,
    this.pierceRemaining = 0,
    this.bounceRemaining = 0,
    this.homingTargetId,
    this.impactDamageRadius = 0,
  });

  final EntityId id;
  final ProjectileFaction faction;
  Vec2 position;
  Vec2 direction;
  final double speed;
  final double radius;
  final int damage;
  final double lifetimeSeconds;
  final String weaponId;
  final EntityId? ownerId;
  final bool isCritical;
  final String? attackId;
  final String? assetId;

  // ---- v2.1 主弹道形态（蓝图 §3.4）----
  final String? weaponStyleId;
  final String? projectileAssetId;
  final String? impactAssetId;
  final String? impactCueId;

  /// 命中后还能再命中几个**不同**目标（Prism 1 / Needle 2）。
  int pierceRemaining;

  /// 首次命中后还能弹跳几次（Arc 1）。
  int bounceRemaining;

  /// 追踪锁定目标（Missile）；null = 直线飞行。
  EntityId? homingTargetId;

  /// 爆裂伤害半径（logical px）；0 = 无范围伤害（FV21-03 待裁决）。
  final double impactDamageRadius;

  /// **已命中的目标集合** —— 穿透与弹跳**不得重复命中同一个目标**。
  ///
  /// 蓝图 §3.4：「`Projectile` 生命周期保存**已命中的 EntityId 集合**。
  /// 弹跳、穿透、追踪**永不命中玩家、拾取物或已移除实体**。」
  final Set<EntityId> hitTargetIds = <EntityId>{};

  double age = 0;
  bool consumed = false;

  bool get isExpired => age >= lifetimeSeconds;

  CircleHitbox get hitbox => CircleHitbox(position, radius);
}

/// 危险区（Bomber）。
/// **F-36**：一条待执行的敌机攻击（不可变）。
///
/// 协议 §3.2 要求以 t=0 的 `origin`/`aimTarget`/`shape` 建立
/// **不可变**待执行攻击 —— 因此这里持有 `EnemyAttackRequest` 本身
/// （它已含这些字段），到期时用**原值**发射，不受期间敌机移动影响。
class _PendingAttack {
  const _PendingAttack({
    required this.request,
    required this.fireAtSeconds,
  });

  final EnemyAttackRequest request;

  /// 到期时刻（逻辑秒）。
  final double fireAtSeconds;
}

/// **F-38**：Boss 招式的预警规格（由内容配置注入运行时）。
///
/// 与敌机的 `telegraphAssetId` 同一设计：**素材与形状由 Domain 持有**，
/// 表现层直接使用，不按 `attackId` 猜绑定。
class BossTelegraphSpec {
  const BossTelegraphSpec({
    required this.assetId,
    required this.shape,
    required this.totalSeconds,
  });

  final String assetId;

  /// `cone` | `line` | `circle`。
  final String shape;

  final double totalSeconds;
}

class HazardZone {
  HazardZone({
    required this.id,
    required this.position,
    required this.radius,
    required this.warningSeconds,
    required this.activeSeconds,
    required this.tickSeconds,
    required this.damagePerTick,
    required this.sourceId,
    this.assetId,
  });

  final EntityId id;
  final Vec2 position;
  final double radius;
  final double warningSeconds;
  final double activeSeconds;
  final double tickSeconds;
  final int damagePerTick;
  final EntityId sourceId;

  /// **F-36**：危险区的**正式素材**（`HazardSpec.assetId`）。
  ///
  /// 产品裁决要求危险区以**正式素材**识别（圆环/十字等），
  /// 而不是 Canvas 几何，也不是通用三角色弱图案。
  final String? assetId;

  double age = 0;
  double _tickAccumulator = 0;

  bool get isWarning => age < warningSeconds;
  bool get isExpired => age >= warningSeconds + activeSeconds;

  double get remainingRatio {
    final total = warningSeconds + activeSeconds;
    return total <= 0 ? 0 : (1 - age / total).clamp(0.0, 1.0);
  }

  /// 推进；返回本次是否应结算一次伤害。
  bool tick(double dt) {
    final wasWarning = isWarning;
    age += dt;
    if (wasWarning || isWarning) {
      return false;
    }
    _tickAccumulator += dt;
    if (_tickAccumulator >= tickSeconds) {
      _tickAccumulator -= tickSeconds;
      return true;
    }
    return false;
  }

  CircleHitbox get hitbox => CircleHitbox(position, radius);
}

/// 一局的运行时。持有全部实体注册表并驱动九步顺序。
class GameRuntime {
  GameRuntime({
    required this.catalogPlayer,
    required this.enemyTunings,
    this.eliteAffixes = const <String, EliteAffix>{},
    required this.runtime,
    required this.random,
    required this.bus,
    required this.clock,
    required this.phases,
    required this.director,
    required this.enemySystem,
    required this.pulse,
    this.mainWeaponStyles = const <String, WeaponStyleSpec>{},
    this.tuning,
    this.breachNormalHpDamage = 8,
    this.breachEliteHpDamage = 15,
    this.upgradeSystem,
    this.bossSystem,
    this.bossTelegraphs = const <String, BossTelegraphSpec>{},
    this.riskGateSystem,
    this.audioDirector,
    this.hapticsDirector,
  })  : player = PlayerState(
          tuning: tuning ?? PlayerTuning.fromConfig(catalogPlayer),
        );

  final Map<String, Object?> catalogPlayer;
  final Map<String, EnemyTuning> enemyTunings;

  /// 精英词缀表（`enemies.json` 的 `affixes`）。
  ///
  /// **此前这条链完全没接线**：`EliteAffix.fromConfig` 定义了却从未被调用，
  /// 波次表里的 `affixId` 也没被传给 `EnemySystem.spawn` ——
  /// 结果是精英有 6 倍血量却**没有任何词缀行为**。
  final Map<String, EliteAffix> eliteAffixes;
  final RunContext runtime;
  final RandomSource random;
  final EventBus bus;
  final GameClock clock;
  final PhaseController phases;
  final DirectorSystem director;
  final EnemySystem enemySystem;
  final PulseWeapon pulse;

  /// **五种主弹道形态的规格表**（v2.1 / 蓝图 §3.4），按 styleId 索引。
  ///
  /// 由 `V2Bootstrap` 从 `weapons.json.mainWeaponStyles` 解析后注入。
  /// 空表 ⇒ 所有形态都不可用，且 `PulseWeapon.activeStyle` 恒为 null
  /// （与 v2.0 **字节级等价**）。
  final Map<String, WeaponStyleSpec> mainWeaponStyles;
  final PlayerTuning? tuning;

  /// 突破伤害（穿透护盾）：普通 8、精英 15。
  final int breachNormalHpDamage;
  final int breachEliteHpDamage;

  /// 升级系统（可为 null 表示本局不启用，供纯战斗测试使用）。
  final UpgradeSystem? upgradeSystem;

  /// Boss 系统（可为 null 表示本局不启用 Boss）。
  final BossSystem? bossSystem;

  /// **F-38**：Boss 招式的预警规格（attackId → 规格）。
  final Map<String, BossTelegraphSpec> bossTelegraphs;

  /// 风险门系统（可为 null 表示本局不启用风险门）。
  final RiskGateSystem? riskGateSystem;

  /// 音频导演（可为 null 表示本局无音频）。
  ///
  /// 放在 runtime 而不是表现层：事件在本步结束时就被消费掉，
  /// 表现层与音频拿到的是同一批不可变事件，顺序一致。
  final AudioDirector? audioDirector;

  /// 触感导播（F-10）。与音频同一条事件分发路径。
  final HapticsDirector? hapticsDirector;

  /// 最近一帧消费掉的事件（供表现层使用）。
  List<StampedEvent> lastFrameEvents = const <StampedEvent>[];

  /// 进行中的风险门；null 表示没有。
  RiskGateSession? riskGate;

  /// **R2**：每次风险门自动结算的记录（gateId / 序号 / 选项 / 徽记序号）。
  final List<RiskGateResolution> riskGateResolutions =
      <RiskGateResolution>[];

  final Map<String, int> _riskGateOccurrences = <String, int>{};



  /// **胜利过渡态**：Boss 被击败后置位，此后本局不再结算任何伤害。
  ///
  /// 依 F-20 裁决（选 A）：「`BossDefeated` 被确认后…**原子切换**到
  /// 不可受伤的胜利过渡状态：拒绝该步后续及未来帧所有 `DamageIntent`、
  /// 清除敌人/敌弹/危险区、停用碰撞与伤害 tick、禁止生成新的伤害源」。
  ///
  /// 此前只清了"在飞的投射物"，**敌人本体接触、越界、危险区结算仍在跑** ——
  /// 于是胜利后仍有 3 次 `PlayerDamaged`（实测）。冻结必须覆盖**全部来源**，
  /// 而不只是投射物。
  bool _victoryFrozen = false;

  /// Boss 击败后需要清理在飞的敌方投射物与危险区。
  ///
  /// 用标记而不是立刻清理，是因为清理点必须在碰撞解析**之后** ——
  /// 见 `_onBossDefeated` 的注释。
  bool _pendingVictoryClear = false;

  /// 已打开过的风险门 ID（每道只开一次）。
  final Set<String> openedRiskGates = <String>{};

  /// 过载代价（所受最终伤害 ×1.15，20 秒）。
  final OverloadPenalty overloadPenalty = OverloadPenalty(
    multiplier: 1.15,
    durationSeconds: 20.0,
  );

  /// 赏金挂起效果（下一个固定精英额外 1 核心、HP ×1.25）。
  final BountyPending bountyPending = BountyPending();

  /// 当前 Boss；null 表示尚未入场。
  BossState? boss;

  /// 是否已触发 Boss 入场流程。
  bool bossEntryTriggered = false;

  /// 是否胜利。
  bool victory = false;

  /// 本局升级状态。
  late final UpgradeState upgradeState = UpgradeState(
    maxDrafts: upgradeSystem?.maxDrafts ?? 0,
  );

  /// 当前待选的升级草案；null 表示没有。
  DraftOffer? currentOffer;

  /// 已完成的升级次数（产品基线 §6 的"升级数"定义）。
  int get upgradeCount => upgradeState.grantCount;

  /// 当前选中的卡等级，供结算页与调试。
  Map<String, int> get selectedUpgrades =>
      Map<String, int>.unmodifiable(upgradeState.levels);

  late final PlayerState player;
  final PlayerSystem playerSystem = PlayerSystem();
  final DamageSystem damageSystem = DamageSystem();
  final CollisionSystem collisionSystem = CollisionSystem();
  final EntityIdAllocator ids = EntityIdAllocator();

  final List<EnemyState> enemies = <EnemyState>[];
  final List<Projectile> projectiles = <Projectile>[];
  final List<HazardZone> hazards = <HazardZone>[];

  int score = 0;
  int xp = 0;
  int comboCount = 0;
  double comboMultiplier = 1.0;
  double _comboTimer = 0;

  /// 当前锁定的输入（技术架构 §4 第 1 步）。
  InputFrame _lockedInput = InputFrame.idle;

  /// 本步待提交的新实体（第 5/6 步只入队，第 9 步提交）。
  final List<EnemyState> _pendingEnemies = <EnemyState>[];
  final List<Projectile> _pendingProjectiles = <Projectile>[];
  final List<HazardZone> _pendingHazards = <HazardZone>[];

  /// **F-36：待执行攻击队列**（协议 §3.2 时序合同）。
  ///
  /// `telegraphSeconds > 0` 的攻击在 t=0 只发预警，并以**当时的**
  /// `origin`/`aimTarget`/`shape` 建立不可变待执行攻击；
  /// 到期**同一步**才发 `EnemyAttackFired` 并生成伤害实体。
  ///
  /// 此前 Fired / Telegraphed / 生成实体发生在**同一步**，
  /// 预警时长对玩家完全无效。
  final List<_PendingAttack> _pendingAttacks = <_PendingAttack>[];

  // ---- v2.1 清场胜利（B1 步骤 4 / 蓝图 §4.1）----

  /// 清场确认状态（`inactive` / `confirming` / `confirmed`）。
  SectorClearState sectorClearState = SectorClearState.inactive;

  /// 进入 `confirming` 的逻辑时间；确认窗固定 0.8 s。
  double? sectorClearStartedAtSeconds;

  /// **终局结果的唯一来源**（蓝图 §4.1）。
  ///
  /// App 层**只允许**消费它，**禁止**用 `health.isDead` 或
  /// `combatSeconds >= 190` 自行推断胜负（蓝图 §4.2）。
  RunEnded? terminalResult;

  /// 最近一次自动强化的提示（v2.1 / 冻结表 §2.3）。
  ///
  /// 只保存**最近一次**：冻结表明确「每局强化间隔远大于 1.2 秒，不设队列」；
  /// 同帧多发时按 `grantOrdinal` 升序逐张展示由**事件顺序**保证，
  /// 而这里只承载"当前该显示哪一条"。

  /// **v2.1-R2 结果徽记队列**（冻结表 §2.3）。
  ///
  /// 「并发事件按产生顺序进入**单一结果队列**，前项结束后才显示后项；
  ///   队列**不暂停战斗、不丢事件**。」
  ///
  /// 队列用**逻辑时间**推进 ⇒ 暂停即冻结 ✓
  final V21ResultNoticeQueue resultNotices = V21ResultNoticeQueue();

  /// 结果徽记的**全局序号**（强化与风险门共用一个计数器）。
  int _resultNoticeOrdinal = 0;

  /// 清场确认窗时长（技术协议 §3.2：固定 0.8 s）。
  static const double kSectorClearConfirmSeconds = 0.8;

  /// 当前目标文案 key（v2.1 / 冻结表 §4）。
  ///
  /// | 条件 | key |
  /// | --- | --- |
  /// | `combatSeconds < 145` | `objective.survive`（`seconds=ceil(150-t)`） |
  /// | `145 ≤ t < 150` 且 Boss 未入场 | `objective.bossIncoming` |
  /// | Boss 已入场且存活 | `objective.defeatBoss` |
  /// | 清场确认窗 | `objective.sectorClear` |
  ///
  /// **注意**：v2.1 **不得**再显示 `190 - combatSeconds` 或裸倒数。
  String? get _objectiveKey {
    if (sectorClearState == SectorClearState.confirming) {
      return 'objective.sectorClear';
    }
    final b = boss;
    if (b != null && !b.isDefeated) {
      return 'objective.defeatBoss';
    }
    if (combatSeconds < 145) {
      return 'objective.survive';
    }
    if (combatSeconds < 150) {
      return 'objective.bossIncoming';
    }
    // 150 秒后 Boss 仍为 null：理论上不可达（150 秒必入场），
    // 但保持确定行为 —— 继续显示"击败守门者"之前的过渡提示。
    return 'objective.bossIncoming';
  }

  /// 目标文案的模板参数（冻结表 §4：`seconds=ceil(150 - combatSeconds)`）。
  Map<String, Object?> get _objectiveArgs {
    if (_objectiveKey == 'objective.survive') {
      return <String, Object?>{
        'seconds': (150 - combatSeconds).ceil().clamp(0, 150),
      };
    }
    return const <String, Object?>{};
  }

  /// 构建**同一逻辑步内一致**的威胁快照。
  ThreatSnapshot threatSnapshot() {
    final d = director;
    var enemyProjectiles = 0;
    for (final p in projectiles) {
      if (p.faction == ProjectileFaction.enemy) {
        enemyProjectiles++;
      }
    }
    // 待提交队列里的实体**也算威胁** —— 否则会在它们出生前误判清场。
    for (final p in _pendingProjectiles) {
      if (p.faction == ProjectileFaction.enemy) {
        enemyProjectiles++;
      }
    }
    return ThreatSnapshot(
      directorCompleted: d.isExhausted,
      hasFutureBossPlan: d.hasFutureBossEntry,
      enemyCount: enemies.length + _pendingEnemies.length,
      enemyProjectileCount: enemyProjectiles,
      hazardCount: hazards.length + _pendingHazards.length,
      pendingAttackCount: _pendingAttacks.length,
      bossAlive: boss != null && !(boss?.isDefeated ?? true),
    );
  }

  /// 是否推进过逻辑（用于测试断言"冻结"）。
  int logicSteps = 0;

  bool _inStep = false;

  /// 有效战斗时间（秒），由逻辑步累计。
  double get combatSeconds => clock.elapsedSeconds;

  // ------------------------------------------------------------
  // 帧推进
  // ------------------------------------------------------------

  /// 推进一个**渲染帧**。
  ///
  /// 返回本帧执行的逻辑步数。非 Playing 状态返回 0 —— 逻辑完全冻结。
  int advance(double renderDeltaSeconds, InputFrame input) {
    if (_inStep) {
      throw StateError('GameRuntime.advance 不可重入');
    }
    _lockedInput = input;

    // **R2**：不再有 `riskGate` 活动阶段 —— 进入该 phase 只可能是
    // 旧回放/旧快照的残留数据，此时**直接恢复为 playing**（不阻断）。
    if (phases.phase == GamePhase.riskGate) {
      phases.transitionTo(GamePhase.playing, reason: 'r2NoRiskGatePhase');
    }

    // 升级草案：只接受选卡，逻辑完全冻结。
    if (phases.phase == GamePhase.upgradeDraft) {
      final index = _lockedInput.cardSelection;
      if (index != null) {
        selectDraftCard(index);
      }
      return 0;
    }

    // 边沿命令即使不推进逻辑也要处理（例如暂停请求）。
    final pauseEvent = _lockedInput.pauseRequested
        ? phases.requestPause(PauseSource.userRequest)
        : null;
    if (pauseEvent != null) {
      bus.emit(pauseEvent, runtime);
    }

    // 相位迁移也要让音频知道（暂停/恢复/离开对局）。
    final phaseBefore = phases.phase;

    if (!phases.phase.advancesLogic) {
      _dispatchEvents();
      return 0;
    }

    final steps = clock.advanceAndRun(renderDeltaSeconds, (frameIndex) {
      _inStep = true;
      try {
        runtime.setFrameIndex(frameIndex);
        _stepOnce();
        logicSteps++;
      } finally {
        _inStep = false;
      }
    });

    _dispatchEvents();
    if (phaseBefore != phases.phase) {
      audioDirector?.onPhaseChanged(phaseBefore, phases.phase);
    }
    return steps;
  }

  /// 取出本帧事件并交给音频；同时保留给表现层读取。
  void _dispatchEvents() {
    final events = bus.drain();
    if (events.isEmpty) {
      lastFrameEvents = const <StampedEvent>[];
      return;
    }
    lastFrameEvents = events;
    audioDirector?.handleAll(events);
    hapticsDirector?.handleAll(events);
    // 逻辑时间推进音频限频窗口（不用墙上时钟，保证可复现）。
    audioDirector?.service.advance(GameClock.fixedStepSeconds * events.length);
  }

  /// 单个逻辑步（严格九步顺序）。
  void _stepOnce() {
    // 1. 输入已在本帧开头锁定；边沿命令已在 advance 处理。

    // 2. 相位门禁（此处必为 Playing，保留二次确认）。
    if (!phases.phase.advancesLogic) {
      return;
    }

    final dt = GameClock.fixedStepSeconds;

    // **F-36**：待执行攻击到期判定（必须早于本步的碰撞与伤害结算，
    // 以保证"到期同一步才发 Fired 并生成实体"）。
    _servicePendingAttacks();

    // 3. 计时器：冲刺/护盾恢复/连击衰减。
    player.dash.tick(dt);
    if (player.dash.endLockRemaining > 0) {
      player.dash.endLockRemaining -= dt;
      if (player.dash.endLockRemaining < 0) {
        player.dash.endLockRemaining = 0;
      }
    }
    if (_comboTimer > 0) {
      _comboTimer -= dt;
      if (_comboTimer <= 0) {
        _comboTimer = 0;
        comboCount = 0;
        comboMultiplier = 1.0;
      }
    }

    // 4. 玩家移动与冲刺（使用锁定输入）。
    playerSystem.step(
      state: player,
      input: _lockedInput,
      dt: dt,
      elapsedSeconds: combatSeconds,
    );
    final shieldRestored = player.shieldRegen.tick(dt, player.shield);
    if (shieldRestored > 0) {
      bus.emit(
        PlayerVitalStateChanged(
          hp: player.health.current,
          hpMax: player.health.max,
          shield: player.shield.current,
          shieldMax: player.shield.max,
          cause: 'shieldRegen',
        ),
        runtime,
      );
    }

    // **F-20：胜利过渡态下不再推进任何会产生伤害源的系统。**
    // 冻结覆盖的是"全部来源"——Director 生成、敌人行为、危险区、
    // Boss 招式、碰撞与伤害结算，而不只是清一次在飞的投射物。
    if (_victoryFrozen) {
      _fireWeapons(dt);
      _updateProjectiles(dt);
      _commitPending();
      _checkAutoGrantDue();
      return;
    }

    // 5. Director 与敌人更新（只产生待生成命令）。
    _updateDirector(dt);
    _updateEnemies(dt);
    _updateHazards(dt);

    // 5b. 过载代价计时（20 秒内所受最终伤害 ×1.15）。
    overloadPenalty.tick(dt);

    // 5c. Boss 推进（入场 → 阶段 → 招式循环）。
    _updateBoss(dt);
    _updateBossLaser(dt);

    // 6. 目标选择与武器发射。
    _fireWeapons(dt);
    _updateProjectiles(dt);

    // 7. 碰撞收集 + 8. 伤害结算。
    _resolveCollisions();

    // 9. 提交实体增删。
    _commitPending();

    // 9.1 胜利后在飞的敌方投射物与危险区 —— 在此统一清理，
    //     避开碰撞解析期间对 `projectiles` 的遍历（§7.5「停止伤害」）。
    if (_pendingVictoryClear) {
      _pendingVictoryClear = false;
      projectiles.removeWhere((p) => p.faction == ProjectileFaction.enemy);
      hazards.clear();
      _pendingAttacks.clear();
      // 裁决要求"清除敌人" —— 不只是在飞的投射物。
      // 敌人本体接触也会造成 HP 伤害，只清投射物仍然会挨打。
      for (final enemy in enemies) {
        _removals.add(enemy);
      }
      _commitPending();
    }

    // 10. 自动强化（不冻结逻辑）+ 清场确认（v2.1）。
    //     顺序：先强化再取威胁快照 —— 与冻结表 §2.1「同一逻辑步先应用
    //     强化，再构建 ThreatSnapshot」一致。
    _checkAutoGrantDue();
    _updateSectorClear();
  }

  // ------------------------------------------------------------
  // 第 5 步：Director 与敌人
  // ------------------------------------------------------------

  void _updateDirector(double dt) {
    final triggers = director.step(
      combatSeconds: combatSeconds,
      playerPosition: player.position,
      playerHp: player.health.current,
      hpDamageInLast15s: 0,
      upgradeCount: 0,
      activeEnemyCount: enemies.length,
    );

    for (final trigger in triggers) {
      if (trigger.isDeferred) {
        continue;
      }
      // 150 秒行：清理普通敌弹与危险区 → 战前补给 → Boss 入场。
      if (trigger.row.isBossEntry) {
        _startBossFight();
        continue;
      }
      // 风险门行：清普通敌弹、停新敌生成，进入选择窗口。
      if (trigger.row.isRiskGate) {
        _openRiskGate(trigger.row.riskGateId!);
        continue;
      }
      // 带 clearEnemyBullets 的行（两道风险门都是）：先清弹。
      if (trigger.row.clearEnemyBullets) {
        projectiles.removeWhere((p) => p.faction == ProjectileFaction.enemy);
        hazards.clear();
      _pendingAttacks.clear();
      }
      if (trigger.spawns.isEmpty) {
        continue;
      }
      final centerX = trigger.centerX ?? 960;
      for (final spawn in trigger.spawns) {
        final tuning = enemyTunings[spawn.enemyId];
        if (tuning == null) {
          continue;
        }
        // 预算门禁：同屏敌人上限 45。
        if (enemies.length + _pendingEnemies.length >= 45) {
          break;
        }
        final offsets = tuning.move.formationOffsets.isEmpty
            ? const <Vec2>[Vec2.zero]
            : tuning.move.formationOffsets;
        for (var i = 0; i < spawn.count; i++) {
          final offset = offsets.length == 1
              ? Vec2.zero
              : offsets[i % offsets.length];
          final enemy = enemySystem.spawn(
            id: ids.next(EntityKind.enemy),
            tuning: tuning,
            spawnX: centerX + (i ~/ offsets.length) * 120,
            formationOffset: offset,
            isElite: spawn.isElite,
            // 波次表的 affixId → 真实词缀。缺配置时为 null（不静默编造）。
            affix: spawn.affixId == null
                ? null
                : eliteAffixes[spawn.affixId],
          );
          _pendingEnemies.add(enemy);
          bus.emit(
            EnemySpawned(
              entityId: enemy.id,
              enemyId: tuning.id,
              position: enemy.position,
              isElite: spawn.isElite,
              affixId: enemy.affix?.id,
            ),
            runtime,
          );
        }
      }
    }
  }

  void _updateEnemies(double dt) {
    for (final enemy in enemies) {
      if (enemy.isDead) {
        continue;
      }
      final event = enemySystem.step(
        enemy: enemy,
        dt: dt,
        playerPosition: player.position,
      );

      if (event.breachWarning != null) {
        bus.emit(
          EnemyBreached(
            entityId: enemy.id,
            enemyId: enemy.tuning.id,
            isElite: enemy.isElite,
            breachHpDamage: 0,
            position: enemy.position,
            isWarningOnly: true,
          ),
          runtime,
        );
      }

      // 越界：移除 + 穿透护盾的 HP 伤害 + **不给任何奖励**。
      if (event.breached != null) {
        _applyBreach(enemy);
        continue;
      }

      for (final request in event.attackRequests) {
        // **F-36 时序合同**（协议 §3.2）：
        // `telegraphSeconds > 0` 的攻击在 t=0 **只发预警**，
        // 并建立不可变待执行攻击；到期同一步才发 Fired 并生成实体。
        if (request.telegraphSeconds > 0) {
          bus.emit(
            EnemyAttackTelegraphed(
              entityId: request.sourceId,
              enemyId: request.enemyId,
              attackId: request.attackId,
              position: request.origin,
              telegraphSeconds: request.telegraphSeconds,
            ),
            runtime,
          );
          _pendingAttacks.add(
            _PendingAttack(
              request: request,
              fireAtSeconds: combatSeconds + request.telegraphSeconds,
            ),
          );
          continue;
        }
        // 无预警招式：立即发射。
        _fireEnemyAttack(request);
      }
    }
  }

  void _applyBreach(EnemyState enemy) {
    // 产品基线 §5：普通敌人 8、精英敌人 15（穿透护盾）。
    final damage = enemy.isElite
        ? breachEliteHpDamage
        : breachNormalHpDamage;
    final result = damageSystem.applyToPlayer(
      intent: DamageIntent(
        sourceId: enemy.id,
        targetId: const EntityId(EntityKind.player, 0),
        damageType: DamageType.breach,
        rawDamage: damage,
        frameIndex: runtime.frameIndex,
        hitKey: 'breach|${enemy.id}',
        sourceType: 'breach',
      ),
      health: player.health,
      shield: player.shield,
      invulnerable: player.isInvulnerable,
      nowSeconds: combatSeconds,
    );

    bus.emit(
      EnemyBreached(
        entityId: enemy.id,
        enemyId: enemy.tuning.id,
        isElite: enemy.isElite,
        breachHpDamage: result.hpDamage,
        position: enemy.position,
      ),
      runtime,
    );
    _markForRemoval(enemy);
    // 突破**不给**经验、分数、掉落与连击。
    if (result.hpDamage > 0) {
      _onPlayerTookHpDamage(result.hpDamage);
    }
    _checkPlayerDeath();
  }

  /// **F-36**：发 `EnemyAttackFired` 并生成伤害实体。
  ///
  /// 无预警招式立即调用；有预警招式由待执行队列**到期同一步**调用。
  void _fireEnemyAttack(EnemyAttackRequest request) {
    bus.emit(
      EnemyAttackFired(
        entityId: request.sourceId,
        enemyId: request.enemyId,
        attackId: request.attackId,
        position: request.origin,
        telegraphSeconds: request.telegraphSeconds,
      ),
      runtime,
    );
    _spawnEnemyAttack(request);
  }

  /// **F-36**：推进待执行攻击 —— 到期则发 Fired 并生成实体。
  ///
  /// 取消/冻结规则（协议 §3.2「预警期间源敌机被移除、风险门开启、
  /// 胜利锁定、重开或非 Playing 状态，待执行攻击必须取消/冻结且不得残留」）：
  ///
  /// * **非 Playing（含暂停）**：`_stepOnce` 在相位门禁处提前返回，
  ///   本方法不会被调用 —— 即**冻结**（逻辑时钟不前进，到期时间不推移）。
  /// * **源敌机被移除**：此处剔除（`enemies` 是存活列表）。
  /// * **风险门 / 胜利锁定 / 重开 / 阶段切换 / 战前补给**：
  ///   由各处既有的 `hazards.clear()` 旁一并 `_pendingAttacks.clear()`。
  void _servicePendingAttacks() {
    if (_pendingAttacks.isEmpty) {
      return;
    }
    // 源敌机已移除 → 取消，不得残留。
    _pendingAttacks.removeWhere(
      (pending) => !enemies.any((enemy) => enemy.id == pending.request.sourceId),
    );
    // 到期 → 同一步发 Fired 并生成实体。
    final due = <_PendingAttack>[];
    _pendingAttacks.removeWhere((pending) {
      if (combatSeconds >= pending.fireAtSeconds) {
        due.add(pending);
        return true;
      }
      return false;
    });
    for (final pending in due) {
      _fireEnemyAttack(pending.request);
    }
  }

  void _spawnEnemyAttack(EnemyAttackRequest request) {
    // **F-36 第 4 步：`bomber_drop` 的危险区**（协议 §3.2）。
    //
    // * 落点固定为 **t=0 的 `origin`**（配置 `dropAt = selfBelow`）；
    // * 半径 90 / 持续 2.2s / 每 0.25s 每目标至多 8 点 —— 全部取自
    //   `attackProfile.hazard`（配置即规范值）；
    // * **`warningSeconds = 0`**：预警已由 `TelegraphView` 负责，
    //   协议明确"ACTIVE Hazard 的 warningSeconds 为 0，不能重复预警"。
    final hazardSpec = request.hazard;
    if (hazardSpec != null) {
      _pendingHazards.add(
        HazardZone(
          id: ids.next(EntityKind.hazard),
          position: request.origin,
          radius: hazardSpec.radius,
          warningSeconds: 0,
          activeSeconds: hazardSpec.activeSeconds,
          tickSeconds: hazardSpec.tickSeconds,
          damagePerTick: hazardSpec.damagePerTick,
          sourceId: request.sourceId,
          assetId: hazardSpec.assetId,
        ),
      );
    }

    final spec = request.projectile;
    if (spec == null) {
      return;
    }
    final baseAngle = _angleOf(
      (request.aimTarget - request.origin).normalized,
    );
    final count = request.projectileCount;
    final offsets = request.angleOffsetsDegrees.isEmpty
        ? <double>[
            for (var i = 0; i < count; i++)
              count == 1 ? 0 : -10.0 + (20.0 / (count - 1)) * i,
          ]
        : request.angleOffsetsDegrees;

    for (var i = 0; i < count; i++) {
      final offset = i < offsets.length ? offsets[i] : 0.0;
      final angle = baseAngle + offset * math.pi / 180;
      _pendingProjectiles.add(
        Projectile(
          id: ids.next(EntityKind.enemyProjectile),
          faction: ProjectileFaction.enemy,
          position: request.origin,
          direction: Vec2(math.cos(angle), math.sin(angle)),
          speed: spec.speed,
          radius: spec.radius,
          damage: spec.damage,
          lifetimeSeconds: spec.lifetimeSeconds,
          weaponId: request.attackId,
          ownerId: request.sourceId,
          attackId: request.attackId,
          assetId: spec.assetId,
        ),
      );
    }
  }

  void _updateHazards(double dt) {
    for (final hazard in hazards) {
      final shouldDamage = hazard.tick(dt);
      // **只在目标位于危险区内时结算伤害**（协议 §3.2：
      // 「每 0.25 s **每目标**至多造成 8 点伤害」——"每目标"即区内目标）。
      //
      // 此前这里对玩家**无差别**造成伤害：只要地图上存在危险区，
      // 玩家在任何位置都会被扣血。
      final dx = player.position.x - hazard.position.x;
      final dy = player.position.y - hazard.position.y;
      final reach = hazard.radius + player.tuning.bodyRadius;
      final playerInside = dx * dx + dy * dy <= reach * reach;
      if (shouldDamage && playerInside && !player.isInvulnerable) {
        damageSystem.applyToPlayer(
          intent: DamageIntent(
            sourceId: hazard.sourceId,
            targetId: const EntityId(EntityKind.player, 0),
            damageType: DamageType.standard,
            rawDamage: hazard.damagePerTick,
            frameIndex: runtime.frameIndex,
            hitKey: 'hazard|${hazard.id}',
            sourceType: 'hazard',
          ),
          health: player.health,
          shield: player.shield,
          invulnerable: false,
          nowSeconds: combatSeconds,
        );
      }
    }
  }

  // ------------------------------------------------------------
  // 风险门（产品基线 §7.1）
  // ------------------------------------------------------------

  /// 打开一道风险门。
  ///
  /// 出现前清除所有普通敌弹、停止新敌生成；**玩家位置不锁定**。
  /// **v2.1-R2：风险门到点自动结算**（冻结表 §2.4）。
  ///
  /// 与 v2.0 的关键差别 —— **不再有任何玩法阻断**：
  /// * **不清子弹**（`clearNormalEnemyBulletsBefore` 不参与正常对局）；
  /// * **不停刷怪**（`stopNewEnemySpawns` 同上）；
  /// * **不切换 phase**（不进入 `GamePhase.riskGate`，战斗不中断）；
  /// * **不等待玩家输入**，没有选择窗、没有超时回退。
  ///
  /// 抽取由 `RandomSource` 的**带标签固定调用**完成（等权），
  /// 因此同 seed 同输入必得同一结果，且不受帧率/暂停/渲染影响。
  ///
  /// 没有合法项属**内容配置错误** —— 抛错（Release 阻断），
  /// 而不是静默跳过（那会让"这一局少了风险门"变成不可见的缺陷）。
  void _openRiskGate(String gateId) {
    final system = riskGateSystem;
    if (system == null || !openedRiskGates.add(gateId)) {
      return;
    }

    // 记录本次是该 gate 的第几次（0 基），供快照与回放对账。
    final ordinal = _riskGateOccurrences[gateId] ?? 0;
    _riskGateOccurrences[gateId] = ordinal + 1;

    // 过载的可选项＝稀有池 ∩ 当前可用卡（满级/互斥/前置不满足的要过滤）。
    final rarePool = <String>[];
    final upgrades = upgradeSystem;
    if (upgrades != null) {
      final available = upgrades.availableCards(upgradeState).toSet();
      for (final id in system.overloadRarePool) {
        if (available.contains(id)) {
          rarePool.add(id);
        }
      }
    }

    final optionId = system.autoPickOption(
      gateId: gateId,
      occurrenceOrdinal: ordinal,
      playerHp: player.health.current,
      availableRareCards: rarePool,
      rng: random,
    );
    if (optionId == null) {
      throw StateError(
        '风险门 $gateId 没有合法选项 —— 内容配置错误，必须修复配置 '
        '（冻结表 §2.4：不得静默跳过）。',
      );
    }

    // 结算：与手动选择**走同一条** `_applyRiskOutcome`（避免两套效果）。
    final session = system.open(
      gateId: gateId,
      playerHp: player.health.current,
      availableRareCards: rarePool,
    );
    final outcome = session.select(optionId);
    if (outcome == null) {
      throw StateError('风险门 $gateId 的选项 $optionId 无法结算');
    }
    _applyRiskOutcome(outcome);

    // **R2**：风险门结果同样进**同一个**结果队列（视觉层无文字）。
    final kind = switch (optionId) {
      RiskOptionIds.supply => V21ResultKind.supply,
      RiskOptionIds.bounty => V21ResultKind.bounty,
      _ => V21ResultKind.overload,
    };
    resultNotices.enqueue(
      V21ResultNotice(
        kind: kind,
        args: <String, Object?>{
          'name': _riskOptionNameKey(optionId),
          'effect': _riskOptionDescKey(optionId),
        },
        ordinal: _resultNoticeOrdinal,
      ),
    );

    // 记录供回放/快照对账（冻结表 §2.4 要求）。
    riskGateResolutions.add(
      RiskGateResolution(
        gateId: gateId,
        occurrenceOrdinal: ordinal,
        optionId: optionId,
        resultNoticeOrdinal: _resultNoticeOrdinal++,
      ),
    );
  }

  bool selectRiskOption(String optionId) {
    final session = riskGate;
    if (session == null || session.isResolved) {
      return false;
    }
    final outcome = session.select(optionId);
    if (outcome == null) {
      return false;
    }
    _applyRiskOutcome(outcome);
    return true;
  }

  /// 风险选项的**名称 key**（语义模板参数；不显示在画面）。
  String _riskOptionNameKey(String optionId) =>
      kRiskOptionNameKeys[optionId] ?? optionId;

  /// 风险选项的**效果 key**（语义模板参数）。
  String _riskOptionDescKey(String optionId) =>
      kRiskOptionDescKeys[optionId] ?? optionId;

  void _applyRiskOutcome(RiskGateOutcome outcome) {
    final effect = outcome.effect;

    // RG-SUPPLY：护盾 +20、HP +8（均封顶）。
    if (effect.shieldGrant > 0) {
      player.shield.restore(effect.shieldGrant);
    }
    if (effect.hpGrant > 0) {
      player.health.heal(effect.hpGrant);
    }

    // RG-BOUNTY：挂起到下一个固定精英。
    if (effect.extraEliteCore > 0) {
      bountyPending.arm(
        extraCores: effect.extraEliteCore,
        hpMultiplier: effect.nextEliteHpMultiplier,
      );
    }

    // RG-OVERLOAD：立即三选一 + 20 秒受伤加重。
    if (effect.damageTakenMultiplier > 1.0) {
      overloadPenalty.activate();
    }

    bus.emit(
      RiskSelected(
        gateId: outcome.gateId,
        optionId: outcome.optionId,
        wasTimeout: outcome.wasTimeout,
      ),
      runtime,
    );
    bus.emit(
      PlayerVitalStateChanged(
        hp: player.health.current,
        hpMax: player.health.max,
        shield: player.shield.current,
        shieldMax: player.shield.max,
        cause: 'riskGate:${outcome.optionId}',
      ),
      runtime,
    );

    riskGate = null;
    final event = phases.transitionTo(GamePhase.playing, reason: 'riskResolved');
    if (event != null) {
      bus.emit(event, runtime);
    }

    // 过载给的稀有卡走一次即时草案（若池为空则跳过）。
    if (effect.rareDraftPool.isNotEmpty && upgradeSystem != null) {
      final offer = upgradeSystem!.generateDraft(
        state: upgradeState,
        rng: random,
        context: DraftContext(
          combatSeconds: combatSeconds,
          xp: xp,
          damageCardIds: upgradeSystem!.damageCardIds,
        ),
      );
      if (offer != null) {
        currentOffer = DraftOffer(
          candidates: List<String>.unmodifiable(
            effect.rareDraftPool.take(upgradeSystem!.draftSize).toList(),
          ),
          guaranteed: const <String>[],
          draftIndex: offer.draftIndex,
        );
        final draftEvent = phases.transitionTo(
          GamePhase.upgradeDraft,
          reason: 'overloadRareDraft',
        );
        if (draftEvent != null) {
          bus.emit(draftEvent, runtime);
        }
      }
    }
  }

  // ------------------------------------------------------------
  // Boss（产品基线 §7.2）
  // ------------------------------------------------------------

  /// 触发 Boss 入场前的准备：清弹、战前补给、开始入场。
  void _startBossFight() {
    final system = bossSystem;
    if (system == null || bossEntryTriggered) {
      return;
    }
    bossEntryTriggered = true;

    // 战前处理顺序（产品基线 §7.2）：
    // 清理所有普通敌弹/危险区 → HP +15 → 护盾 +20 → 冲刺为 0 时归 1 → 入场。
    projectiles.removeWhere((p) => p.faction == ProjectileFaction.enemy);
    hazards.clear();
      _pendingAttacks.clear();

    final supply = system.applyPreEntrySupply(
      playerHealth: player.health,
      playerShield: player.shield,
      playerDash: player.dash,
    );

    bus.emit(
      PlayerVitalStateChanged(
        hp: player.health.current,
        hpMax: player.health.max,
        shield: player.shield.current,
        shieldMax: player.shield.max,
        cause: 'preBossSupply',
      ),
      runtime,
    );
    if (supply.hpRestored > 0) {
      bus.emit(
        PickupHeal(amount: supply.hpRestored),
        runtime,
      );
    }
    if (supply.shieldRestored > 0) {
      bus.emit(PickupShield(amount: supply.shieldRestored), runtime);
    }
    if (supply.dashRestored > 0) {
      bus.emit(DashReady(), runtime);
    }

    final state = BossState(tuning: system.tuning);
    system.beginEntry(state);
    boss = state;
  }

  void _updateBoss(double dt) {
    final system = bossSystem;
    final state = boss;
    if (system == null || state == null || state.isDefeated) {
      return;
    }

    final event = system.step(
      state: state,
      dt: dt,
      combatSeconds: combatSeconds,
      playerPosition: player.position,
      summonCleared: !enemies.any((e) => e.tuning.id == 'EN-SHIELD'),
    );

    if (event.phaseChangedTo != null) {
      // 转阶段：清理所有敌方投射物与危险区（产品基线 §7.2）。
      projectiles.removeWhere((p) => p.faction == ProjectileFaction.enemy);
      hazards.clear();
      _pendingAttacks.clear();
      bus.emit(
        BossPhaseChanged(phase: event.phaseChangedTo!.name),
        runtime,
      );
    }

    final telegraph = event.telegraphStarted;
    if (telegraph != null) {
      bus.emit(
        BossAttackTelegraphed(
          attackId: telegraph.attackId,
          position: telegraph.origin,
          telegraphSeconds: telegraph.telegraphSeconds,
        ),
        runtime,
      );
    }

    final fired = event.attackFired;
    if (fired != null) {
      bus.emit(
        BossAttackFired(
          attackId: fired.attackId,
          position: fired.origin,
          telegraphSeconds: fired.telegraphSeconds,
        ),
        runtime,
      );
      _spawnBossAttack(fired);
    }

    if (event.weakpointOpened) {
      bus.emit(BossCriticalReached(hpRatio: state.hpRatio), runtime);
    }
    if (event.attackEnded != null) {
      bus.emit(BossAttackEnded(attackId: event.attackEnded!), runtime);
    }

    // 冲刺无敌期间不吃 Boss 的接触伤害。
    if (state.bodyContactActive && !player.isInvulnerable) {
      final contact = state.hitbox.intersects(player.hitbox);
      if (contact) {
        final result = damageSystem.applyToPlayer(
          intent: DamageIntent(
            sourceId: const EntityId(EntityKind.boss, 1),
            targetId: const EntityId(EntityKind.player, 0),
            damageType: DamageType.standard,
            rawDamage: state.tuning.bodyContactDamage,
            frameIndex: runtime.frameIndex,
            hitKey: 'bossCharge|player',
            attackId: BossAttackIds.charge,
            sourceType: 'boss',
          ),
          health: player.health,
          shield: player.shield,
          invulnerable: false,
          nowSeconds: combatSeconds,
        );
        if (result.dealtAnyDamage) {
          player.shieldRegen.notifyDamaged();
          if (result.hpDamage > 0) {
            _onPlayerTookHpDamage(result.hpDamage);
          }
          _checkPlayerDeath();
        }
      }
    }
  }

  void _spawnBossAttack(BossAttackEvent event) {
    // 激光扫射：以 Boss 为原点的持续伤害，按 0.25 秒 tick 结算。
    if (event.attackId == BossAttackIds.laser) {
      _activeLaser = _LaserSweep(
        remaining: event.sweepSeconds,
        tickAccumulator: 0,
      );
      return;
    }

    // 召唤：在固定坐标生成护盾机。
    if (event.summonPositions.isNotEmpty) {
      final tuning = enemyTunings['EN-SHIELD'];
      if (tuning != null) {
        for (final position in event.summonPositions) {
          final enemy = enemySystem.spawn(
            id: ids.next(EntityKind.enemy),
            tuning: tuning,
            spawnX: position.x,
            spawnY: position.y,
          );
          _pendingEnemies.add(enemy);
          bus.emit(
            EnemySpawned(
              entityId: enemy.id,
              enemyId: tuning.id,
              position: enemy.position,
              isElite: false,
              affixId: enemy.affix?.id,
            ),
            runtime,
          );
        }
      }
      return;
    }

    if (event.projectileCount <= 0 || event.speed <= 0) {
      return;
    }

    final baseAngle = _angleOf(
      (event.aimTarget - event.origin).normalized,
    );
    final offsets = event.angleOffsetsDegrees.isEmpty
        ? <double>[
            for (var i = 0; i < event.projectileCount; i++)
              -180.0 + (360.0 / event.projectileCount) * i,
          ]
        : event.angleOffsetsDegrees;

    for (final offset in offsets) {
      final angle = baseAngle + offset * math.pi / 180;
      _pendingProjectiles.add(
        Projectile(
          id: ids.next(EntityKind.enemyProjectile),
          faction: ProjectileFaction.enemy,
          position: event.origin,
          direction: Vec2(math.cos(angle), math.sin(angle)),
          speed: event.speed,
          radius: event.radius,
          damage: event.damage,
          lifetimeSeconds: event.lifetimeSeconds,
          weaponId: event.attackId,
          attackId: event.attackId,
          assetId: _bossProjectileAsset(event.attackId),
        ),
      );
    }
  }

  String _bossProjectileAsset(String attackId) =>
      attackId == BossAttackIds.ring
      ? 'GFX-BOSS-RING-BULLET'
      : 'GFX-BOSS-FAN-BULLET';

  _LaserSweep? _activeLaser;

  void _updateBossLaser(double dt) {
    final sweep = _activeLaser;
    final state = boss;
    if (sweep == null || state == null) {
      return;
    }
    sweep.remaining -= dt;
    if (sweep.remaining <= 0) {
      _activeLaser = null;
      return;
    }
    // 激光自 Boss 中心沿扫射路径；命中的是玩家而非实体列表，
    // 因此这里直接做线段到玩家的距离判定。
    sweep.tickAccumulator += dt;
    if (sweep.tickAccumulator < 0.25) {
      return;
    }
    sweep.tickAccumulator -= 0.25;

    // 扫射进度 → 当前方向。
    final total = state.enraged ? 2.2 : 1.8;
    final progress = (1 - sweep.remaining / total).clamp(0.0, 1.0);
    final from = const Vec2(240, 1020);
    final to = const Vec2(1680, 1020);
    final aim = Vec2(
      from.x + (to.x - from.x) * progress,
      from.y + (to.y - from.y) * progress,
    );
    final direction = (aim - state.position).normalized;
    final toPlayer = player.position - state.position;
    final along = toPlayer.x * direction.x + toPlayer.y * direction.y;
    if (along <= 0 || along > 1500) {
      return;
    }
    final perpendicular = (toPlayer - direction * along).length;
    if (perpendicular > 30 + player.tuning.bodyRadius) {
      return;
    }

    final result = damageSystem.applyToPlayer(
      intent: DamageIntent(
        sourceId: const EntityId(EntityKind.boss, 1),
        targetId: const EntityId(EntityKind.player, 0),
        damageType: DamageType.standard,
        rawDamage: 8,
        frameIndex: runtime.frameIndex,
        hitKey: 'bossLaser|${runtime.frameIndex ~/ 15}',
        attackId: BossAttackIds.laser,
        sourceType: 'boss',
      ),
      health: player.health,
      shield: player.shield,
      invulnerable: player.isInvulnerable,
      nowSeconds: combatSeconds,
    );
    if (result.dealtAnyDamage) {
      player.shieldRegen.notifyDamaged();
      if (result.hpDamage > 0) {
        _onPlayerTookHpDamage(result.hpDamage);
      }
      _checkPlayerDeath();
    }
  }

  // ------------------------------------------------------------
  // 第 6 步：武器
  // ------------------------------------------------------------

  void _fireWeapons(double dt) {
    final targets = _targetViews();
    final requests = pulse.step(
      playerPosition: player.position,
      targets: targets,
      dt: dt,
      rng: random,
    );

    for (final request in requests) {
      final projectile = Projectile(
        id: ids.next(EntityKind.playerProjectile),
        faction: ProjectileFaction.player,
        position: request.origin,
        direction: request.direction,
        speed: request.speed,
        radius: request.radius,
        damage: request.damage,
        lifetimeSeconds: request.lifetimeSeconds,
        weaponId: request.weaponId,
        isCritical: request.isCritical,
        // **v2.1**：把 Domain 锁定的形态信息**原样**带给投射物 ——
        // 表现层据此取弹体/命中图，**不得**按武器名猜（会命中错的图）。
        weaponStyleId: request.weaponStyleId,
        projectileAssetId: request.projectileAssetId,
        impactAssetId: request.impactAssetId,
        impactCueId: request.impactCueId,
        pierceRemaining: request.pierceRemaining,
        bounceRemaining: request.bounceRemaining,
        homingTargetId: request.homingTargetId,
        impactDamageRadius: request.impactDamageRadius,
        // 首帧即把锁定目标记为"已命中"是**不正确**的（还没打到），
        // 因此这里不预填 hitTargetIds。
      );
      _pendingProjectiles.add(projectile);

      bus.emit(
        WeaponFired(
          weaponId: request.weaponId,
          weaponStyleId: request.weaponStyleId,
          sourceId: const EntityId(EntityKind.player, 0),
          position: request.origin,
          direction: request.direction,
        ),
        runtime,
      );
    }
  }

  void _updateProjectiles(double dt) {
    for (final projectile in projectiles) {
      if (projectile.consumed) {
        continue;
      }
      projectile.age += dt;
      if (projectile.isExpired) {
        projectile.consumed = true;
        continue;
      }
      // **v2.1 Missile 追踪**（蓝图 §3.4）：
      // 「每逻辑步向**初次锁定**的最近合法目标转向；目标无效时
      //   **仅重新选一次**、**不消耗随机**；无目标直线飞行。」
      _steerHomingProjectile(projectile);

      projectile.position =
          projectile.position + projectile.direction * (projectile.speed * dt);
      // 出界即失效。
      if (projectile.position.y < -200 ||
          projectile.position.y > 1300 ||
          projectile.position.x < -200 ||
          projectile.position.x > 2100) {
        projectile.consumed = true;
      }
    }
  }

  List<TargetView> _targetViews() {
    final state = boss;
    return <TargetView>[
      // Boss 弱点优先级最高，但只在暴露期可选（产品基线 §4.1）。
      if (state != null && !state.isDefeated)
        TargetView(
          id: const EntityId(EntityKind.bossWeakpoint, 1),
          position: state.position,
          radius: state.tuning.weakpointRadius,
          isWeakpoint: true,
          weakpointActive: state.weakpointActive,
        ),
      if (state != null && !state.isDefeated && !state.invulnerable)
        TargetView(
          id: const EntityId(EntityKind.boss, 1),
          position: state.position,
          radius: state.tuning.bodyRadius,
          isBoss: true,
        ),
      for (final enemy in enemies)
        if (!enemy.isDead)
          TargetView(
            id: enemy.id,
            position: enemy.position,
            radius: enemy.tuning.radius,
            isElite: enemy.isElite,
          ),
    ];
  }

  // ------------------------------------------------------------
  // 第 7/8 步：碰撞与伤害
  // ------------------------------------------------------------

  void _resolveCollisions() {
    final bodies = <CollisionBody>[
      CollisionBody(
        id: const EntityId(EntityKind.player, 0),
        layer: CollisionLayer.playerBody,
        center: player.position,
        radius: player.tuning.bodyRadius,
      ),
      for (final enemy in enemies)
        if (!enemy.isDead)
          CollisionBody(
            id: enemy.id,
            layer: CollisionLayer.enemyBody,
            center: enemy.position,
            radius: enemy.tuning.radius,
            isElite: enemy.isElite,
            enemyId: enemy.tuning.id,
          ),
      for (final projectile in projectiles)
        if (!projectile.consumed)
          CollisionBody(
            id: projectile.id,
            layer: projectile.faction == ProjectileFaction.player
                ? CollisionLayer.playerProjectile
                : CollisionLayer.enemyProjectile,
            center: projectile.position,
            radius: projectile.radius,
            attackId: projectile.attackId,
          ),
      for (final hazard in hazards)
        if (!hazard.isExpired && !hazard.isWarning)
          CollisionBody(
            id: hazard.id,
            layer: CollisionLayer.hazard,
            center: hazard.position,
            radius: hazard.radius,
          ),
    ];

    final pairs = collisionSystem.collect(
      bodies,
      isPlayerInvulnerable: player.isInvulnerable,
    );

    final intents = <DamageIntent>[];
    for (final pair in pairs) {
      final a = pair.a;
      final b = pair.b;
      final playerSide = a.layer == CollisionLayer.playerBody ? a : b;
      final otherSide = identical(playerSide, a) ? b : a;

      if (playerSide.layer == CollisionLayer.playerBody &&
          otherSide.layer != CollisionLayer.playerBody) {
        intents.add(
          DamageIntent(
            sourceId: otherSide.id,
            targetId: playerSide.id,
            damageType: DamageType.standard,
            rawDamage: _playerDamageFrom(otherSide),
            frameIndex: runtime.frameIndex,
            hitKey: '${otherSide.id}|player',
            attackId: otherSide.attackId,
            sourceType: otherSide.layer.name,
          ),
        );
      }
    }

    // 合并同帧伤害后逐条结算（伤害顺序由 DamageSystem 保证）。
    // 过载代价在**最终伤害**上施加（产品基线 §7.1）。
    for (final raw in DamageSystem.mergeSameFrame(intents)) {
      final intent = overloadPenalty.isActive
          ? DamageIntent(
              sourceId: raw.sourceId,
              targetId: raw.targetId,
              damageType: raw.damageType,
              rawDamage: overloadPenalty.apply(raw.rawDamage),
              frameIndex: raw.frameIndex,
              hitKey: raw.hitKey,
              isCritical: raw.isCritical,
              attackId: raw.attackId,
              sourceType: raw.sourceType,
            )
          : raw;
      final result = damageSystem.applyToPlayer(
        intent: intent,
        health: player.health,
        shield: player.shield,
        invulnerable: player.isInvulnerable,
        nowSeconds: combatSeconds,
      );
      if (result.dealtAnyDamage) {
        player.shieldRegen.notifyDamaged();
        if (result.hpDamage > 0) {
          _onPlayerTookHpDamage(result.hpDamage);
        }
        bus.emit(
          PlayerDamaged(
            sourceType: intent.sourceType ?? 'unknown',
            shieldDamage: result.shieldDamage,
            hpDamage: result.hpDamage,
            hpAfter: result.hpAfter,
            shieldAfter: result.shieldAfter,
          ),
          runtime,
        );
        _checkPlayerDeath();
      }
    }

    _resolvePlayerProjectileHits();
  }

  int _playerDamageFrom(CollisionBody body) {
    if (body.layer == CollisionLayer.enemyBody) {
      final tuning = enemyTunings[body.enemyId];
      return tuning?.contactDamage ?? 10;
    }
    if (body.layer == CollisionLayer.hazard) {
      return 8;
    }
    // 敌方投射物：从投射物表里取真实伤害。
    for (final projectile in projectiles) {
      if (projectile.id == body.id) {
        return projectile.damage;
      }
    }
    return 0;
  }

  /// **Arc 弹跳的目标选择**（蓝图 §3.4 原文）。
  ///
  /// 「首命中后在 **360 logical px 内**以**距离、EntityId** 选一个
  /// **未命中**合法目标；**无候选即销毁**。」
  ///
  /// 排序必须**确定**（同距离时按 EntityId），否则回放不可复现。
  /// 只考虑**存活**敌人 —— 已移除实体不得被选中。
  /// **Missile 的逐步转向**（蓝图 §3.4）。
  ///
  /// 规则（逐条实现）：
  /// * 每逻辑步朝**初次锁定**的目标转向（不是每步重新选目标）；
  /// * 目标**无效**（已死/已移除）时**仅重新选一次**，且
  ///   **不消耗随机数**（用确定性的"最近存活敌人"而非加权抽）；
  /// * **无目标则直线飞行**（不改 direction）；
  /// * 转向采用**有上限的角度步进**，避免瞬间掉头（视觉与手感都不可接受）。
  void _steerHomingProjectile(Projectile projectile) {
    if (projectile.homingTargetId == null && !_homingRetried(projectile)) {
      return; // 非追踪弹，直接返回（v2.0 行为）。
    }
    // 找到当前锁定目标；无效则重选**一次**。
    EnemyState? target;
    final lockedId = projectile.homingTargetId;
    for (final e in enemies) {
      if (e.id == lockedId && !e.isDead) {
        target = e;
        break;
      }
    }
    if (target == null) {
      if (_homingRetried(projectile)) {
        projectile.homingTargetId = null;
        return; // 已经重试过 ⇒ 直线飞行。
      }
      _markHomingRetried(projectile);
      // **不消耗随机**：确定性地取最近存活敌人（同距离按 EntityId）。
      EnemyState? nearest;
      var bestDistance = double.infinity;
      for (final e in enemies) {
        if (e.isDead) {
          continue;
        }
        final d = (e.position - projectile.position).length;
        if (d < bestDistance ||
            (d == bestDistance &&
                nearest != null &&
                e.id.compareTo(nearest.id) < 0)) {
          bestDistance = d;
          nearest = e;
        }
      }
      target = nearest;
      projectile.homingTargetId = nearest?.id;
      if (target == null) {
        return; // 无目标 ⇒ 直线。
      }
    }

    // 朝目标转向（有角速度上限）。
    final desired = (target.position - projectile.position);
    if (desired.length == 0) {
      return;
    }
    final want = desired.normalized;
    const maxTurnRadiansPerSecond = 6.0;
    final maxTurn = maxTurnRadiansPerSecond * (1 / 60);
    final currentAngle = math.atan2(projectile.direction.y, projectile.direction.x);
    final wantAngle = math.atan2(want.y, want.x);
    var delta = wantAngle - currentAngle;
    while (delta > math.pi) {
      delta -= 2 * math.pi;
    }
    while (delta < -math.pi) {
      delta += 2 * math.pi;
    }
    final turn = delta.clamp(-maxTurn, maxTurn);
    final newAngle = currentAngle + turn;
    projectile.direction = Vec2(math.cos(newAngle), math.sin(newAngle));
  }

  /// 追踪弹是否已经"重选过一次"（`homingTargetId` 为 null 的追踪弹也需记录）。
  /// 用 `attackId` 之外的独立集合避免给 `Projectile` 加易忘的布尔字段。
  final Set<EntityId> _homingRetryDone = <EntityId>{};

  bool _homingRetried(Projectile p) => _homingRetryDone.contains(p.id);

  void _markHomingRetried(Projectile p) => _homingRetryDone.add(p.id);

  /// **Plasma 爆裂**（FV21-03 批复的精确算法）。
  ///
  /// 直接目标 [direct] **已被结算过一次**，这里**必须排除**它 ——
  /// 否则直接目标会被"命中 + 爆裂"打两次（批复明令禁止）。
  void _applyPlasmaSplash(Projectile projectile, EnemyState direct) {
    const maxTargets = 4;
    const splashRatio = 0.55;
    final radius = projectile.impactDamageRadius;
    final splashDamage = (projectile.damage * splashRatio).floor();
    if (splashDamage <= 0) {
      return;
    }

    final candidates = <EnemyState>[];
    for (final e in enemies) {
      if (e.isDead || e.id == direct.id) {
        continue; // 排除直接目标与已死敌人。
      }
      if ((e.position - projectile.position).length > radius) {
        continue;
      }
      candidates.add(e);
    }
    if (candidates.isEmpty) {
      return;
    }
    // **稳定排序**：距离优先，同距离按 EntityId（确定性，回放可复现）。
    candidates.sort((a, b) {
      final da = (a.position - projectile.position).length;
      final db = (b.position - projectile.position).length;
      final byDistance = da.compareTo(db);
      return byDistance != 0 ? byDistance : a.id.compareTo(b.id);
    });

    for (final e in candidates.take(maxTargets)) {
      final applied = e.health.applyDamage(splashDamage);
      bus.emit(
        WeaponHit(
          weaponId: projectile.weaponId,
          sourceId: const EntityId(EntityKind.player, 0),
          targetId: e.id,
          critical: false,
          damage: applied,
          targetEnemyId: e.tuning.id,
          weaponStyleId: projectile.weaponStyleId,
        ),
        runtime,
      );
      bus.emit(
        EnemyDamaged(
          entityId: e.id,
          enemyId: e.tuning.id,
          damage: applied,
          hpAfter: e.health.current,
          hpMax: e.health.max,
        ),
        runtime,
      );
      if (e.isDead) {
        _onEnemyKilled(e);
      }
    }
  }

  EnemyState? _pickBounceTarget(Projectile projectile) {
    const maxDistance = 360.0;
    final candidates = <EnemyState>[];
    for (final enemy in enemies) {
      if (enemy.isDead) {
        continue;
      }
      if (projectile.hitTargetIds.contains(enemy.id)) {
        continue;
      }
      if ((enemy.position - projectile.position).length > maxDistance) {
        continue;
      }
      candidates.add(enemy);
    }
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) {
      final da = (a.position - projectile.position).length;
      final db = (b.position - projectile.position).length;
      final byDistance = da.compareTo(db);
      if (byDistance != 0) {
        return byDistance;
      }
      return a.id.compareTo(b.id); // 同距离按 EntityId，保证确定性。
    });
    return candidates.first;
  }

  void _resolvePlayerProjectileHits() {
    for (final projectile in projectiles) {
      if (projectile.consumed || projectile.faction != ProjectileFaction.player) {
        continue;
      }
      for (final enemy in enemies) {
        if (enemy.isDead) {
          continue;
        }
        // **v2.1**：穿透/弹跳不得重复命中同一目标。
        if (projectile.hitTargetIds.contains(enemy.id)) {
          continue;
        }
        if (!projectile.hitbox.intersects(enemy.hitbox)) {
          continue;
        }
        final reduced = enemySystem.applyFrontShield(
          enemy.tuning,
          enemy.position,
          player.position,
          projectile.damage,
        );
        final applied = enemy.health.applyDamage(reduced);
        projectile.hitTargetIds.add(enemy.id);

        bus.emit(
          WeaponHit(
            weaponId: projectile.weaponId,
            sourceId: const EntityId(EntityKind.player, 0),
            targetId: enemy.id,
            critical: projectile.isCritical,
            damage: applied,
            targetEnemyId: enemy.tuning.id,
            weaponStyleId: projectile.weaponStyleId,
          ),
          runtime,
        );
        bus.emit(
          EnemyDamaged(
            entityId: enemy.id,
            enemyId: enemy.tuning.id,
            damage: applied,
            hpAfter: enemy.health.current,
            hpMax: enemy.health.max,
          ),
          runtime,
        );

        if (enemy.isDead) {
          _onEnemyKilled(enemy);
        }

        // ---- v2.1 Plasma 爆裂（FV21-03 批复）----
        //
        // 规则（逐条来自批复）：
        //   * **直接目标只受一次** `effectiveDamage`（上面已结算，此处**不再**伤它）；
        //   * 范围内**最多 4 个其他**合法敌人，按**距离 → EntityId** 稳定排序；
        //   * 各受 `floor(effectiveDamage × 0.55)`；
        //   * 半径来自**显式配置** `impactDamageRadius`，**绝不从图片尺寸推断**。
        if (projectile.impactDamageRadius > 0) {
          _applyPlasmaSplash(projectile, enemy);
        }

        // ---- v2.1 穿透 / 弹跳（蓝图 §3.4）----
        if (projectile.pierceRemaining > 0) {
          // **Prism / Needle**：继续飞行，还能再命中 N 个**不同**目标。
          projectile.pierceRemaining -= 1;
          continue;
        }
        if (projectile.bounceRemaining > 0) {
          final next = _pickBounceTarget(projectile);
          if (next == null) {
            // **Arc**：无候选即销毁（蓝图明确）。
            projectile.consumed = true;
            break;
          }
          projectile.bounceRemaining -= 1;
          projectile.direction = (next.position - projectile.position).normalized;
          continue;
        }
        projectile.consumed = true;
        break; // 单体命中后销毁
      }

      if (projectile.consumed) {
        continue;
      }
      final state = boss;
      if (state == null || state.isDefeated || state.invulnerable) {
        continue;
      }
      // 弱点暴露时优先判定弱点，命中伤害 ×1.5（产品基线 §3.4）。
      final weakpointHit = state.weakpointHitbox;
      var damage = projectile.damage;
      var hit = false;
      if (weakpointHit != null && projectile.hitbox.intersects(weakpointHit)) {
        damage = (projectile.damage * state.tuning.weakpointDamageMultiplier)
            .round();
        hit = true;
      } else if (projectile.hitbox.intersects(state.hitbox)) {
        hit = true;
      }
      if (!hit) {
        continue;
      }

      final applied = state.health.applyDamage(damage);
      projectile.consumed = true;
      bus.emit(
        WeaponHit(
          weaponId: projectile.weaponId,
          sourceId: const EntityId(EntityKind.player, 0),
          targetId: const EntityId(EntityKind.boss, 1),
          critical: projectile.isCritical,
          damage: applied,
          targetEnemyId: 'boss.aegis',
        ),
        runtime,
      );
      if (state.isDefeated) {
        _onBossDefeated();
      }
    }
  }

  void _onBossDefeated() {
    victory = true;

    // 产品设计 §7.5 的 Boss 击败结束条件是
    // 「**停止伤害和生成**后再进入结算」。
    //
    // 此前这里只置了 victory，**没清在飞的敌方投射物与危险区** ——
    // 于是胜利之后玩家还会继续挨打（实测抓出：胜利后仍有 5 次
    // PlayerDamaged）。胜利瞬间被打死与结算语义自相矛盾。
    //
    // ⚠️ **不能在这里直接 clear**：`_onBossDefeated` 是在
    // `_resolveCollisions()` 遍历 `projectiles` 的过程中被调用的，
    // 直接改列表会抛 `Concurrent modification during iteration`
    // （我第一版就是这么写的，被测试立刻抓出）。
    // 因此只置标记，在本步末尾（碰撞解析之后）统一清理。
    // **先结算本次击杀奖励，再冻结**（裁决的顺序要求）。
    // 击杀的伤害结算与 `WeaponHit` 已在上游 `_resolvePlayerProjectileHits`
    // 里先行发出，因此到这里时奖励已结清。
    //
    // 注：`boss_aegis.json` 里**没有** Boss 的得分字段，故此处不补分数 ——
    // 研发不擅自造数值（"不擅自增删功能/改内容"）。

    // 原子切换到胜利过渡态：此后本步与未来帧的一切伤害都被拒绝。
    _victoryFrozen = true;
    _pendingVictoryClear = true;

    bus.emit(BossDefeated(), runtime);
    bus.emit(
      RunEnded(
        result: 'victory',
        durationSeconds: combatSeconds,
        score: score,
        seed: runtime.seed,
        bossHpRatio: 0,
        resultTier: resultTierFor(victory: true, bossHpRatio: null).id,
        // v2.1：本处是**击败 Boss** 的胜利路径。
        // 清场胜利走 `SectorClearConfirmed` → `reason: 'sectorCleared'`。
        reason: 'bossDefeated',
      ),
      runtime,
    );
  }

  void _onEnemyKilled(EnemyState enemy) {
    // 分数 = 基础分 × 连击倍率，向下取整。
    final base = enemy.isElite
        ? enemy.tuning.score * 8
        : enemy.tuning.score;
    score += (base * comboMultiplier).floor();

    // 连击：4 秒内再次击杀 +1；每 10 连击倍率 +0.1，最高 2.0。
    comboCount += 1;
    _comboTimer = 4.0;
    comboMultiplier = (1.0 + (comboCount ~/ 10) * 0.1).clamp(1.0, 2.0);

    final gained = enemy.isElite ? enemy.tuning.xp * 3 : enemy.tuning.xp;
    xp += (gained * xpMultiplier).round();

    bus.emit(
      EnemyDestroyed(
        entityId: enemy.id,
        enemyId: enemy.tuning.id,
        position: enemy.position,
        isElite: enemy.isElite,
      ),
      runtime,
    );
    _markForRemoval(enemy);
  }

  void _onPlayerTookHpDamage(int amount) {
    // 连击倍率 -0.2（最低 1.0），**不清空层数**。
    comboMultiplier = (comboMultiplier - 0.2).clamp(1.0, 2.0);
  }

  void _checkPlayerDeath() {
    if (!player.health.isDead) {
      return;
    }
    // 关键：`bossHpRatio` 必须是**真实值**，不能硬编码。
    // 此前这里写死 0，而协议里 silver 的判定正是 `bossHpRatio < 0.35`
    // —— 若照协议算，写死 0 会让**每一次失败都判成 silver**。
    // Boss 尚未出现时为 null，按"未进 P3"处理。
    final bossHpRatio = boss?.hpRatio;
    bus.emit(
      RunEnded(
        result: 'defeat',
        durationSeconds: combatSeconds,
        score: score,
        seed: runtime.seed,
        // 字段非空：Boss 尚未出现时记 1.0（= 未被削弱），
        // 语义上与 resultTierFor 里 null 的处理一致。
        bossHpRatio: bossHpRatio ?? 1.0,
        resultTier: resultTierFor(
          victory: false,
          bossHpRatio: bossHpRatio,
        ).id,
        // v2.1：失败有两条路 —— 阵亡 / 190 秒判负（蓝图 §4.1）。
        // 本次改造（B1）先按既有 v2.0 行为标 playerDead；
        // B3 接入 `hardDefeatSeconds` 时改为按超时判定 timeLimit。
        reason: 'playerDead',
      ),
      runtime,
    );
  }

  // ------------------------------------------------------------
  // 升级草案（产品基线 §4.2）
  // ------------------------------------------------------------

  /// 经验达到阈值且满足时间门时打开草案。
  ///
  /// 第 1 次草案不得早于有效战斗时间 15.0 秒 —— 15 秒前积累的经验
  /// 由 `UpgradeSystem.isAutoGrantDue` 保留，不做任何补偿。
  /// **唯一的终局出口**（蓝图 §4.1）。
  ///
  /// 一切结束都必须经此：设置 [terminalResult]、发[一次] `RunEnded`、
  /// 并在胜利时**原子冻结**后续伤害。
  ///
  /// **为什么不各处自己 emit**：v2.0 曾让 `health.isDead` 与
  /// `combatSeconds >= 190` 各自推断结局，导致 App 层与运行时
  /// 可能得出不同结论。现在只留这一个出口，App 只消费
  /// [terminalResult]（蓝图 §4.2 明文禁止 App 重算）。
  void _endRun({
    required String result,
    required String reason,
    required double bossHpRatio,
  }) {
    if (terminalResult != null) {
      return; // 只结束一次。
    }
    if (result == 'victory') {
      _victoryFrozen = true;
      _pendingVictoryClear = true;
    }
    final tier = resultTierFor(
      victory: result == 'victory',
      bossHpRatio: result == 'victory' ? null : bossHpRatio,
    ).id;
    final ended = RunEnded(
      result: result,
      durationSeconds: combatSeconds,
      score: score,
      seed: runtime.seed,
      bossHpRatio: bossHpRatio,
      resultTier: tier,
      reason: reason,
    );
    terminalResult = ended;
    bus.emit(ended, runtime);
  }

  /// **推进清场确认状态机**（v2.1 / 蓝图 §4.1、技术协议 §3.2）。
  ///
  /// 三态迁移：
  ///   * `inactive` --四条件满足--> `confirming`（发 `SectorClearStarted`）
  ///   * `confirming` --出现新威胁--> `inactive`（发 `SectorClearCancelled`）
  ///   * `confirming` --满 0.8s--> `confirmed`（发 `SectorClearConfirmed`，
  ///     并写入 `terminalResult` —— **唯一的清场胜利来源**）
  ///
  /// **只在 `Playing` 推进**（本方法由 `_stepOnce` 调用，天然满足）。
  /// 确认窗用**逻辑时间**计时，因此暂停会冻结它 ✓。
  void _updateSectorClear() {
    if (sectorClearState == SectorClearState.confirmed) {
      return;
    }
    final snapshot = threatSnapshot();
    final empty = snapshot.isEmpty;

    switch (sectorClearState) {
      case SectorClearState.inactive:
        if (!empty) {
          return;
        }
        sectorClearState = SectorClearState.confirming;
        sectorClearStartedAtSeconds = combatSeconds;
        bus.emit(SectorClearStarted(), runtime);

      case SectorClearState.confirming:
        if (!empty) {
          // **新威胁出现 → 立即取消**（协议：确认期内新威胁即取消）。
          sectorClearState = SectorClearState.inactive;
          sectorClearStartedAtSeconds = null;
          bus.emit(
            SectorClearCancelled(reason: 'newThreat: $snapshot'),
            runtime,
          );
          return;
        }
        final startedAt = sectorClearStartedAtSeconds;
        if (startedAt != null &&
            combatSeconds - startedAt >= kSectorClearConfirmSeconds) {
          sectorClearState = SectorClearState.confirmed;
          bus.emit(SectorClearConfirmed(), runtime);
          _endRun(
            result: 'victory',
            reason: 'sectorCleared',
            bossHpRatio: boss?.hpRatio ?? 0,
          );
        }

      case SectorClearState.confirmed:
        break;
    }
  }

  void _checkAutoGrantDue() {
    final system = upgradeSystem;
    if (system == null) {
      return;
    }
    if (!system.isAutoGrantDue(
      xp: xp,
      grantCount: upgradeState.grantCount,
      combatSeconds: combatSeconds,
    )) {
      return;
    }

    // **v2.1**：达标即**单张**授予，**全程不变更 phase**
    // （冻结表 §2.2：「禁止创建 DraftOffer、进入 UpgradeDraft 或等待输入」）。
    //
    // 与 v2.0 的关键区别：旧路径 `transitionTo(upgradeDraft)` 会**冻结逻辑
    // 时钟**并等玩家点选；v2.1 不停顿，因此这一步必须在 Playing 内完成，
    // 且**不得**产生任何 PhaseChanged 事件。
    final grant = system.grantAutomatic(
      state: upgradeState,
      rng: random,
    ); // 空池/超上限会抛 StateError —— 响亮失败，不静默跳过。
    final card = system.card(grant.cardId);
    if (card == null) {
      throw StateError('自动强化收到未知卡 ${grant.cardId}');
    }

    final effects = system.applyGrant(upgradeState, grant);
    if (effects.isEmpty) {
      // 理论上不可达（候选池已按满级过滤）；到达这里说明状态不同步。
      throw StateError(
        '自动强化未能应用 ${grant.cardId}'
        '（grantOrdinal=${grant.grantOrdinal}）—— 候选池与状态不一致',
      );
    }
    _recomputeModifiers();

    bus.emit(
      AutoUpgradeGranted(
        grantOrdinal: grant.grantOrdinal,
        cardId: grant.cardId,
        level: upgradeState.levelOf(grant.cardId),
        nameKey: card.nameKey,
        descKey: card.descKey,
        styleId: grant.styleId,
      ),
      runtime,
    );
    // **v2.1-R2 结果徽记**（冻结表 §2.3）：视觉层**无文字**，
    // 只有图形；文字说明只进无障碍语义（`toast.upgradeAria`）。
    resultNotices.enqueue(
      V21ResultNotice(
        kind: V21ResultKind.upgrade,
        args: <String, Object?>{
          'name': card.nameKey,
          'level': upgradeState.levelOf(grant.cardId),
          'description': card.descKey,
        },
        ordinal: _resultNoticeOrdinal++,
      ),
    );
  }

  /// 玩家选择一张卡（索引对应 [currentOffer] 的顺序）。
  ///
  /// **⚠️ v2.1 起不可达（蓝图 §3.3 第 2 条）**：
  /// 标准 XP 路径已改为 `_checkAutoGrantDue` 单张自动授予，
  /// `currentOffer` 不再被产出，因此本方法**永远不会**被合法调用。
  /// 保留仅为兼容既有测试与回放代码；**新代码不得调用**。
  /// 由 `test/unit/domain/v21_no_draft_path_test.dart` 静态守住
  /// （生产代码中不得出现对它的调用）。
  @Deprecated('v2.1 起三选一草案路径不可达；请使用 grantAutomatic/applyGrant')
  bool selectDraftCard(int index) {
    final system = upgradeSystem;
    final offer = currentOffer;
    if (system == null || offer == null) {
      return false;
    }
    if (index < 0 || index >= offer.candidates.length) {
      return false;
    }
    final cardId = offer.candidates[index];
    final effects = system.applyCard(upgradeState, cardId);
    if (effects.isEmpty) {
      return false; // 满级/未知卡：不消耗本次选择
    }
    _recomputeModifiers();

    bus.emit(
      UpgradeSelected(cardId: cardId, newLevel: upgradeState.levelOf(cardId)),
      runtime,
    );

    currentOffer = null;
    final event = phases.transitionTo(GamePhase.playing, reason: 'cardChosen');
    if (event != null) {
      bus.emit(event, runtime);
    }
    return true;
  }

  /// 把已选升级折算到武器与玩家数值上。
  ///
  /// 用 [ModifierStack] 的语义（同源覆盖、先加后乘），因此重复调用幂等。
  void _recomputeModifiers() {
    // **v2.1**：主弹道形态的**唯一同步点**。
    // 放在这里是因为它已在"升级变化后"被调用（草案/风险门/自动授予）。
    // 若分散在多处设置 activeStyle，极易出现"卡片已授予但武器没换"的
    // 静默不一致（v2.0 的"声明了没接上"类缺陷）。
    final styleId = upgradeState.mainWeaponStyleId;
    pulse.activeStyle =
        styleId == null ? null : mainWeaponStyles[styleId];

    final system = upgradeSystem;
    if (system == null) {
      return;
    }
    final accumulator = UpgradeAccumulator();
    for (final entry in upgradeState.levels.entries) {
      accumulator.setLevel(entry.key, entry.value);
    }

    // 脉冲炮
    pulse.cadenceMultiplier = accumulator.totalMultiply(
      system,
      'multiplyWeaponStat',
    );
    pulse.bonusDamage = accumulator
        .totalAdd(system, 'addWeaponStat', 'damage')
        .round();
    pulse.criticalChance =
        accumulator.totalAdd(system, 'addWeaponStat', 'criticalChance');

    // 双联分束：等级 → 弹道数与角度
    final spreadLevel = upgradeState.levelOf('UP-PULSE-SPREAD');
    pulse.projectileCount = 1 + spreadLevel;
    pulse.spreadAngleDegrees = spreadLevel >= 1 ? 6.0 : 0.0;

    // 护盾上限
    final shieldLevel = upgradeState.levelOf('UP-SHIELD-MAX');
    if (shieldLevel > 0) {
      final target = player.tuning.shieldMax + shieldLevel * 10;
      if (player.shield.max < target) {
        player.shield.raiseMax(target - player.shield.max,
            refillSameAmount: true);
      }
    }

    // 冲刺层数
    if (upgradeState.levelOf('UP-DASH-CHARGE') > 0) {
      player.dash.maxCharges = player.tuning.dashMaxCharges + 1;
      player.dash.rechargeSeconds = 7.0;
    }
  }

  /// 升级带来的经验倍率（能量回路 ×1.15 逐级叠乘）。
  double get xpMultiplier {
    final system = upgradeSystem;
    if (system == null) {
      return 1.0;
    }
    final accumulator = UpgradeAccumulator();
    for (final entry in upgradeState.levels.entries) {
      accumulator.setLevel(entry.key, entry.value);
    }
    return accumulator.totalMultiply(system, 'multiplyXpGain');
  }

  // ------------------------------------------------------------
  // 第 9 步：提交
  // ------------------------------------------------------------

  final List<EnemyState> _removals = <EnemyState>[];

  void _markForRemoval(EnemyState enemy) => _removals.add(enemy);

  void _commitPending() {
    if (_pendingEnemies.isNotEmpty) {
      enemies.addAll(_pendingEnemies);
      _pendingEnemies.clear();
    }
    if (_pendingProjectiles.isNotEmpty) {
      projectiles.addAll(_pendingProjectiles);
      _pendingProjectiles.clear();
    }
    if (_pendingHazards.isNotEmpty) {
      hazards.addAll(_pendingHazards);
      _pendingHazards.clear();
    }
    if (_removals.isNotEmpty) {
      enemies.removeWhere(_removals.contains);
      _removals.clear();
    }
    projectiles.removeWhere((p) => p.consumed || p.isExpired);
    hazards.removeWhere((h) => h.isExpired);
  }

  // ------------------------------------------------------------
  // 快照
  // ------------------------------------------------------------

  /// 当前应显示的结果徽记（队列按**逻辑时间**推进）。
  V21ResultNotice? get currentNotice => resultNotices.current;

  /// 生成当前帧的只读快照。可在任意相位调用。
  RenderSnapshot snapshot({
    String? playerAssetId = 'GFX-PLAYER-BASE',
    String? playerState,
  }) {
    final enemyViews = <EntityView>[
      for (final enemy in enemies)
        EntityView(
          id: enemy.id,
          position: enemy.position,
          radius: enemy.tuning.radius,
          enemyId: enemy.tuning.id,
          hpRatio: enemy.health.ratio,
          isElite: enemy.isElite,
          affixId: enemy.affix?.id,
          assetId: enemy.tuning.bodyAssetId,
          visualState: enemy.health.ratio <= 0.25 ? 'critical' : 'idle',
        ),
    ];

    final projectileViews = <EntityView>[
      for (final projectile in projectiles)
        EntityView(
          id: projectile.id,
          position: projectile.position,
          radius: projectile.radius,
          isPlayerProjectile: projectile.faction == ProjectileFaction.player,
          rotationRadians: _angleOf(projectile.direction),
          assetId: projectile.assetId,
        ),
    ];

    final hazardViews = <HazardView>[
      for (final hazard in hazards)
        HazardView(
          id: hazard.id,
          position: hazard.position,
          radius: hazard.radius,
          isWarning: hazard.isWarning,
          remainingRatio: hazard.remainingRatio,
          assetId: hazard.assetId,
        ),
    ];

    return RenderSnapshot(
      frameIndex: runtime.frameIndex,
      phase: phases.phase.name,
      player: EntityView(
        id: const EntityId(EntityKind.player, 0),
        position: player.position,
        radius: player.tuning.bodyRadius,
        hpRatio: player.health.ratio,
        rotationRadians: 0,
        assetId: playerAssetId,
        visualState: playerState,
      ),
      enemies: List<EntityView>.unmodifiable(enemyViews),
      projectiles: List<EntityView>.unmodifiable(projectileViews),
      hazards: List<HazardView>.unmodifiable(hazardViews),
      telegraphs: List<TelegraphView>.unmodifiable(<TelegraphView>[
        // **F-38**：Boss 招式的预警也以独立 `TelegraphView` 公开。
        // 几何取自 `BossState` 在 **t=0 锁定**的 origin/aim；
        // 素材与形状来自内容配置（`bossTelegraphs`），表现层不猜绑定。
        if (boss != null &&
            boss!.telegraphRemaining > 0 &&
            boss!.currentAttack != null &&
            bossTelegraphs.containsKey(boss!.currentAttack))
          TelegraphView(
            attackId: boss!.currentAttack!,
            shape: bossTelegraphs[boss!.currentAttack!]!.shape,
            origin: boss!.telegraphOrigin,
            aimTarget: boss!.telegraphAim,
            remainingSeconds: boss!.telegraphRemaining,
            totalSeconds: bossTelegraphs[boss!.currentAttack!]!.totalSeconds,
            assetId: bossTelegraphs[boss!.currentAttack!]!.assetId,
          ),
        for (final pending in _pendingAttacks)
          TelegraphView(
            attackId: pending.request.attackId,
            shape: pending.request.telegraphShape ?? 'circle',
            origin: pending.request.origin,
            aimTarget: pending.request.aimTarget,
            remainingSeconds: pending.fireAtSeconds - combatSeconds,
            totalSeconds: pending.request.telegraphSeconds,
            enemyId: pending.request.enemyId,
            assetId: pending.request.telegraphAssetId,
          ),
      ]),
      riskGate: riskGate == null || riskGate!.isResolved
          ? null
          : RiskGateView(
              gateId: riskGate!.gateId,
              remainingSeconds: riskGate!.remainingSeconds,
              availableOptionIds: riskGate!.availableOptions,
              lockedOptionIds: riskGate!.lockedOptions,
            ),
      upgradeDraft: currentOffer == null
          ? null
          : DraftView(
              draftIndex: currentOffer!.draftIndex,
              cards: <DraftCardView>[
                for (final id in currentOffer!.candidates)
                  if (upgradeSystem?.card(id) != null)
                    DraftCardView(
                      cardId: id,
                      nameKey: upgradeSystem!.card(id)!.nameKey,
                      descKey: upgradeSystem!.card(id)!.descKey,
                      iconAssetId: upgradeSystem!.card(id)!.iconAssetId,
                      rarity: upgradeSystem!.card(id)!.rarity,
                      series: upgradeSystem!.card(id)!.series,
                      currentLevel: upgradeState.levelOf(id),
                      maxLevel: upgradeSystem!.card(id)!.maxLevel,
                      isGuaranteed: currentOffer!.guaranteed.contains(id),
                    ),
              ],
            ),
      hud: HudView(
        // **v2.1 Objective HUD**（冻结表 §4）。
        // 切换点属于**规则**，因此在这里算好，UI 只负责渲染。
        objectiveKey: _objectiveKey,
        objectiveArgs: _objectiveArgs,
        isSectorClearConfirming:
            sectorClearState == SectorClearState.confirming,
        // **R2 结果徽记**：只携带"该显示哪一条 + 播到第几毫秒"。
        // 视觉层无文字；文案只在 UI 的 `Semantics` 里用。
        resultNoticeKind: currentNotice?.kind,
        resultNoticeArgs: currentNotice?.args ?? const <String, Object?>{},
        resultNoticeElapsedMs: currentNotice == null
            ? 0
            : resultNotices.elapsedMsAt(combatSeconds),
        hp: player.health.current,
        hpMax: player.health.max,
        shield: player.shield.current,
        shieldMax: player.shield.max,
        xp: xp,
        upgradeLevel: upgradeCount,
        score: score,
        comboMultiplier: comboMultiplier,
        comboCount: comboCount,
        combatSeconds: combatSeconds,
        dashCharges: player.dash.charges,
        dashMaxCharges: player.dash.maxCharges,
        objectiveWarning: enemies.any((e) => e.warnedBreach),
        bossHpRatio: (boss?.isDefeated ?? true) ? null : boss?.hpRatio,
        bossPhase: boss?.phase.name,
      ),
      isPlayerInvulnerable: player.isInvulnerable,
      activeEnemyCount: enemies.length,
      isBossActive: boss != null && !(boss?.isDefeated ?? true),
    );
  }

  /// 释放本局（新局前必须调用）。
  void dispose() {
    enemies.clear();
    projectiles.clear();
    hazards.clear();
      _pendingAttacks.clear();
    _pendingEnemies.clear();
    _pendingProjectiles.clear();
    _pendingHazards.clear();
    _removals.clear();
    boss = null;
    bossEntryTriggered = false;
    riskGate = null;
    openedRiskGates.clear();
    overloadPenalty.reset();
    bountyPending.reset();
    _activeLaser = null;
    damageSystem.reset();
    collisionSystem.reset();
    ids.reset();
    bus.clear();
    lastFrameEvents = const <StampedEvent>[];
    audioDirector?.service.stopAllLoops();
  }
}

double _angleOf(Vec2 direction) => math.atan2(direction.y, direction.x);

/// 激光扫射的运行时状态（产品基线 §7.2：1.8 秒，每 0.25 秒一次伤害）。
class _LaserSweep {
  _LaserSweep({required this.remaining, required this.tickAccumulator});

  double remaining;
  double tickAccumulator;
}

// ================================================================
// v2.1 清场胜利（B1 步骤 4）
// ================================================================

/// **威胁快照** —— `VictorySystem` 的**唯一输入**（技术协议 §3.2）。
///
/// 为什么必须是"快照"而不是实时查询：清场判定要求**同一逻辑步**内
/// 各项计数彼此一致。分别查询可能跨步取到不同时刻的值，
/// 造成"敌人已清但待提交队列里还有"这类假清场。
class ThreatSnapshot {
  const ThreatSnapshot({
    required this.directorCompleted,
    required this.hasFutureBossPlan,
    required this.enemyCount,
    required this.enemyProjectileCount,
    required this.hazardCount,
    required this.pendingAttackCount,
    required this.bossAlive,
  });

  /// Director 是否已跑完全部波次行。
  final bool directorCompleted;

  /// Director 是否还有**未来的 Boss 入场行**（有则不算清场）。
  final bool hasFutureBossPlan;

  final int enemyCount;
  final int enemyProjectileCount;
  final int hazardCount;
  final int pendingAttackCount;
  final bool bossAlive;

  /// **清场四条件**（技术协议 §3.2 原文）。
  ///
  /// `directorCompleted && !hasFutureBossPlan && enemyCount == 0 &&
  ///  enemyProjectileCount == 0 && hazardCount == 0 &&
  ///  pendingAttackCount == 0 && !bossAlive`
  bool get isEmpty =>
      directorCompleted &&
      !hasFutureBossPlan &&
      enemyCount == 0 &&
      enemyProjectileCount == 0 &&
      hazardCount == 0 &&
      pendingAttackCount == 0 &&
      !bossAlive;

  @override
  String toString() =>
      'ThreatSnapshot(dirDone=$directorCompleted futureBoss=$hasFutureBossPlan '
      'enemies=$enemyCount eProj=$enemyProjectileCount hazards=$hazardCount '
      'pending=$pendingAttackCount bossAlive=$bossAlive)';
}

/// 清场确认的三种状态（蓝图 §4.1）。
enum SectorClearState {
  /// 条件不满足。
  inactive,

  /// 四条件已满足，正在 0.8 s 确认窗内；出现新威胁则取消。
  confirming,

  /// 确认成功 —— 唯一的"清场胜利"来源。
  confirmed,
}
