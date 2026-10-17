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
  int get upgradeCount => upgradeState.draftCount;

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

    // 风险门：窗口按表现时间推进，但战斗逻辑完全冻结。
    if (phases.phase == GamePhase.riskGate) {
      _updateRiskGate(renderDeltaSeconds, _lockedInput.riskSelection);
      return 0;
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
      _checkDraftDue();
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

    // 10. 经验阈值 → 打开升级草案（相位迁移，下一步起逻辑冻结）。
    _checkDraftDue();
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
  void _openRiskGate(String gateId) {
    final system = riskGateSystem;
    if (system == null || !openedRiskGates.add(gateId)) {
      return;
    }

    projectiles.removeWhere((p) => p.faction == ProjectileFaction.enemy);
    hazards.clear();
      _pendingAttacks.clear();

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

    final session = system.open(
      gateId: gateId,
      playerHp: player.health.current,
      availableRareCards: rarePool,
    );
    riskGate = session;

    final event = phases.transitionTo(GamePhase.riskGate, reason: 'riskGate');
    if (event != null) {
      bus.emit(event, runtime);
    }
    bus.emit(
      RiskGateOpened(
        gateId: gateId,
        availableOptionIds: session.availableOptions,
        lockedOptionIds: session.lockedOptions,
      ),
      runtime,
    );
  }

  /// 推进风险门窗口（用**表现时间**，因为战斗逻辑已冻结）。
  void _updateRiskGate(double dt, String? selection) {
    final session = riskGate;
    if (session == null || session.isResolved) {
      return;
    }
    if (selection != null) {
      final outcome = session.select(selection);
      if (outcome != null) {
        _applyRiskOutcome(outcome);
      }
      return;
    }
    final outcome = session.tick(dt);
    if (outcome != null) {
      _applyRiskOutcome(outcome);
    }
  }

  /// 玩家选择一个选项（供界面直接调用）。
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
      );
      _pendingProjectiles.add(projectile);

      bus.emit(
        WeaponFired(
          weaponId: request.weaponId,
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

  void _resolvePlayerProjectileHits() {
    for (final projectile in projectiles) {
      if (projectile.consumed || projectile.faction != ProjectileFaction.player) {
        continue;
      }
      for (final enemy in enemies) {
        if (enemy.isDead) {
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
        projectile.consumed = true;

        bus.emit(
          WeaponHit(
            weaponId: projectile.weaponId,
            sourceId: const EntityId(EntityKind.player, 0),
            targetId: enemy.id,
            critical: projectile.isCritical,
            damage: applied,
            targetEnemyId: enemy.tuning.id,
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
  /// 由 `UpgradeSystem.isDraftDue` 保留，不做任何补偿。
  void _checkDraftDue() {
    final system = upgradeSystem;
    if (system == null) {
      return;
    }
    if (!system.isDraftDue(
      xp: xp,
      draftCount: upgradeState.draftCount,
      combatSeconds: combatSeconds,
    )) {
      return;
    }
    final offer = system.generateDraft(
      state: upgradeState,
      rng: random,
      context: DraftContext(
        combatSeconds: combatSeconds,
        xp: xp,
        damageCardIds: system.damageCardIds,
      ),
    );
    if (offer == null) {
      return; // 候选池为空：安全跳过，不崩溃
    }
    currentOffer = offer;
    final event = phases.transitionTo(
      GamePhase.upgradeDraft,
      reason: 'xpThreshold',
    );
    if (event != null) {
      bus.emit(event, runtime);
    }
    bus.emit(
      UpgradeDraftOpened(
        draftIndex: offer.draftIndex,
        candidateIds: offer.candidates,
      ),
      runtime,
    );
  }

  /// 玩家选择一张卡（索引对应 [currentOffer] 的顺序）。
  ///
  /// 选择后一次性应用升级并回到 Playing（技术架构 §3.1）。
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
