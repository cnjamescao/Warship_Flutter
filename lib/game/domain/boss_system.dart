// ================================================================
// lib/game/domain/boss_system.dart —— 守门者 Aegis
// ================================================================
// 依据：产品基线 §7.2
//
// 固定规则：
//   * HP 2600；入场从 (960,-160) 用 0.8 s 移到 (960,210)，期间无伤害、不可受击；
//   * 入场完成或阶段转场完成后等 0.6 s 才开始第一招；同一招式结束后也最少
//     等 0.6 s；
//   * 阶段阈值 70% / 35%；每次转阶段 1.2 s 不可受击，并清理所有敌方投射物
//     与危险区；
//   * Body 仅在**冲锋**路径期间造成 20 点接触伤害，其他状态不对玩家造成
//     接触伤害（但仍可被攻击）；
//   * 狂暴：P3 开始、技能冷却结束且 HP ≤10% 时，下一次激光扫射改为 2.2 s；
//     180 s 未击败同样进入该变化。**这是唯一狂暴变化。**
// ================================================================

import 'values.dart';

/// Boss 招式 ID（与 `boss_aegis.json` 的 `attackId` 一致）。
class BossAttackIds {
  static const String fan = 'boss_fan';
  static const String charge = 'boss_charge';
  static const String ring = 'boss_ring';
  static const String summon = 'boss_summon';
  static const String laser = 'boss_laser';
  static const String weakpoint = 'boss_weakpoint';
}

/// 阶段。
enum BossPhase { p1, p2, p3 }

/// 阶段配置。
class BossPhaseConfig {
  const BossPhaseConfig({
    required this.phase,
    required this.upperHpRatio,
    required this.lowerHpRatio,
    required this.loop,
  });

  final BossPhase phase;

  /// 该阶段的 HP 上界（含）。
  final double upperHpRatio;
  final double lowerHpRatio;

  /// 该阶段的招式循环顺序。
  final List<String> loop;
}

/// Boss 数值（从 `boss_aegis.json` 映射）。
class BossTuning {
  const BossTuning({
    this.maxHp = 2600,
    this.bodyRadius = 150,
    this.weakpointRadius = 52,
    this.weakpointDamageMultiplier = 1.5,
    this.entryFrom = const Vec2(960, -160),
    this.entryTo = const Vec2(960, 210),
    this.entrySeconds = 0.8,
    this.phaseTransitionInvulnerableSeconds = 1.2,
    this.firstAttackDelaySeconds = 0.6,
    this.minDelayBetweenAttacksSeconds = 0.6,
    this.bodyContactDamage = 20,
    this.hpRestore = 15,
    this.hpCap = 100,
    this.shieldRestore = 20,
  });

  final int maxHp;
  final double bodyRadius;
  final double weakpointRadius;
  final double weakpointDamageMultiplier;

  final Vec2 entryFrom;
  final Vec2 entryTo;
  final double entrySeconds;
  final double phaseTransitionInvulnerableSeconds;
  final double firstAttackDelaySeconds;
  final double minDelayBetweenAttacksSeconds;
  final int bodyContactDamage;

  /// 战前补给（产品基线 §7.2）。
  final int hpRestore;
  final int hpCap;
  final int shieldRestore;
}

/// 一次招式预警 / 发射 / 结束。
class BossAttackEvent {
  const BossAttackEvent({
    required this.attackId,
    required this.origin,
    required this.aimTarget,
    required this.telegraphSeconds,
    this.projectileCount = 0,
    this.angleOffsetsDegrees = const <double>[],
    this.damage = 0,
    this.speed = 0,
    this.radius = 0,
    this.lifetimeSeconds = 0,
    this.sweepSeconds = 0,
    this.summonPositions = const <Vec2>[],
    this.exposeSeconds = 0,
  });

  final String attackId;
  final Vec2 origin;
  final Vec2 aimTarget;
  final double telegraphSeconds;
  final int projectileCount;
  final List<double> angleOffsetsDegrees;
  final int damage;
  final double speed;
  final double radius;
  final double lifetimeSeconds;
  final double sweepSeconds;
  final List<Vec2> summonPositions;
  final double exposeSeconds;
}

/// Boss 一局状态。
class BossState {
  BossState({required this.tuning})
    : health = Health(max: tuning.maxHp),
      position = tuning.entryFrom;

  final BossTuning tuning;
  final Health health;

  Vec2 position;
  BossPhase phase = BossPhase.p1;

  /// 入场剩余时间；>0 表示还在入场。
  double entryRemaining = 0;
  bool hasEntered = false;

  /// 转阶段不可受击剩余时间。
  double transitionInvulnerableRemaining = 0;

  /// 距离下一招还要等多久。
  double attackDelayRemaining = 0;

  /// 本阶段循环指针。
  int loopIndex = 0;

  /// 当前招式（null 表示在冷却/等待）。
  String? currentAttack;

  /// 当前招式的预警剩余时间（>0 表示正在预警）。
  double telegraphRemaining = 0;

  /// 当前招式的执行剩余时间（冲锋位移、激光扫射、核心暴露）。
  double actionRemaining = 0;

  /// Boss 中心沿冲锋路径移动时是否启用 Body 接触伤害。
  bool bodyContactActive = false;

  /// 弱点是否暴露。
  bool weakpointActive = false;

  /// 召唤物是否仍阻塞下一招。
  bool summonBlocking = false;

  /// 狂暴是否已触发（唯一变化：激光扫射时长）。
  bool enraged = false;

  /// 入场期间与阶段转场期间不可受击。
  bool get invulnerable =>
      !hasEntered || transitionInvulnerableRemaining > 0 || entryRemaining > 0;

  bool get isDefeated => health.isDead;

  double get hpRatio => health.ratio;

  CircleHitbox get hitbox => CircleHitbox(position, tuning.bodyRadius);

  /// 弱点判定；未暴露时返回 null。
  CircleHitbox? get weakpointHitbox =>
      weakpointActive ? CircleHitbox(position, tuning.weakpointRadius) : null;
}

/// 一步的 Boss 输出。
class BossStepEvent {
  const BossStepEvent({
    this.telegraphStarted,
    this.attackFired,
    this.attackEnded,
    this.phaseChangedTo,
    this.weakpointOpened = false,
    this.weakpointClosed = false,
    this.defeated = false,
    this.supplyGranted = false,
  });

  final BossAttackEvent? telegraphStarted;
  final BossAttackEvent? attackFired;

  /// 持续型招式（激光、核心暴露）结束。
  final String? attackEnded;

  final BossPhase? phaseChangedTo;
  final bool weakpointOpened;
  final bool weakpointClosed;
  final bool defeated;

  /// 本步发生了战前补给。
  final bool supplyGranted;
}

/// 战前补给的结果（产品基线 §7.2）。
class BossSupplyResult {
  const BossSupplyResult({
    required this.hpRestored,
    required this.shieldRestored,
    required this.dashRestored,
  });

  final int hpRestored;
  final int shieldRestored;

  /// 冲刺层数为 0 时恢复的层数（否则 0）。
  final int dashRestored;
}

/// Boss 系统。
class BossSystem {
  BossSystem({
    this.tuning = const BossTuning(),
    this.phases = const <BossPhaseConfig>[
      BossPhaseConfig(
        phase: BossPhase.p1,
        upperHpRatio: 1.00,
        lowerHpRatio: 0.70,
        loop: <String>[BossAttackIds.fan, BossAttackIds.charge],
      ),
      BossPhaseConfig(
        phase: BossPhase.p2,
        upperHpRatio: 0.70,
        lowerHpRatio: 0.35,
        loop: <String>[BossAttackIds.ring, BossAttackIds.summon],
      ),
      BossPhaseConfig(
        phase: BossPhase.p3,
        upperHpRatio: 0.35,
        lowerHpRatio: 0.00,
        loop: <String>[BossAttackIds.laser, BossAttackIds.weakpoint],
      ),
    ],
    this.summonPositions = const <Vec2>[Vec2(560, 250), Vec2(1360, 250)],
    this.laserSweepSeconds = 1.8,
    this.laserEnragedSweepSeconds = 2.2,
    this.enrageAtSeconds = 180,
    this.weakpointExposeSeconds = 3.0,
    this.chargeTravelSeconds = 0.65,
    this.chargePostArrivalPauseSeconds = 0.4,
    this.chargeTargetClampMinX = 210,
    this.chargeTargetClampMaxX = 1710,
    this.chargeTargetLookbackSeconds = 0.8,
  });

  final BossTuning tuning;
  final List<BossPhaseConfig> phases;
  final List<Vec2> summonPositions;
  final double laserSweepSeconds;
  final double laserEnragedSweepSeconds;
  final double enrageAtSeconds;
  final double weakpointExposeSeconds;
  final double chargeTravelSeconds;
  final double chargePostArrivalPauseSeconds;
  final double chargeTargetClampMinX;
  final double chargeTargetClampMaxX;
  final double chargeTargetLookbackSeconds;

  /// 记录玩家位置历史，供冲锋取"0.8 秒前的位置"。
  final List<({double at, Vec2 position})> _playerHistory =
      <({double at, Vec2 position})>[];

  /// 开始入场。
  void beginEntry(BossState state) {
    state.position = tuning.entryFrom;
    state.entryRemaining = tuning.entrySeconds;
    state.hasEntered = false;
    state.attackDelayRemaining = 0;
  }

  /// 战前补给：清弹、回血、回盾、冲刺归 1（仅当为 0）。
  BossSupplyResult applyPreEntrySupply({
    required Health playerHealth,
    required ShieldPool playerShield,
    required DashState playerDash,
  }) {
    final hpRestored = playerHealth.heal(tuning.hpRestore);
    final shieldRestored = playerShield.restore(tuning.shieldRestore);
    var dashRestored = 0;
    if (playerDash.charges == 0) {
      playerDash.charges = 1;
      dashRestored = 1;
    }
    return BossSupplyResult(
      hpRestored: hpRestored,
      shieldRestored: shieldRestored,
      dashRestored: dashRestored,
    );
  }

  void recordPlayerPosition(double atSeconds, Vec2 position) {
    _playerHistory.add((at: atSeconds, position: position));
    // 只保留最近 2 秒，避免无限增长。
    while (_playerHistory.length > 2 &&
        atSeconds - _playerHistory.first.at > 2.0) {
      _playerHistory.removeAt(0);
    }
  }

  /// 取"距当前 [lookback] 秒之前"的玩家位置（用于冲锋目标 x）。
  Vec2 playerPositionAgo(double nowSeconds, double lookback) {
    final target = nowSeconds - lookback;
    Vec2 best = _playerHistory.isEmpty
        ? const Vec2(960, 900)
        : _playerHistory.first.position;
    var bestDelta = double.infinity;
    for (final sample in _playerHistory) {
      final delta = (sample.at - target).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = sample.position;
      }
    }
    return best;
  }

  /// 推进一个逻辑步。
  BossStepEvent step({
    required BossState state,
    required double dt,
    required double combatSeconds,
    required Vec2 playerPosition,
    required bool summonCleared,
  }) {
    if (state.isDefeated) {
      return const BossStepEvent();
    }

    recordPlayerPosition(combatSeconds, playerPosition);

    // ---- 1. 入场 ----
    if (!state.hasEntered) {
      state.entryRemaining -= dt;
      final progress = state.entryRemaining <= 0
          ? 1.0
          : 1.0 - (state.entryRemaining / tuning.entrySeconds);
      state.position = Vec2(
        tuning.entryFrom.x +
            (tuning.entryTo.x - tuning.entryFrom.x) * progress,
        tuning.entryFrom.y +
            (tuning.entryTo.y - tuning.entryFrom.y) * progress,
      );
      if (state.entryRemaining <= 0) {
        state.hasEntered = true;
        state.entryRemaining = 0;
        state.position = tuning.entryTo;
        state.attackDelayRemaining = tuning.firstAttackDelaySeconds;
      }
      return const BossStepEvent();
    }

    // ---- 2. 转阶段不可受击 ----
    if (state.transitionInvulnerableRemaining > 0) {
      state.transitionInvulnerableRemaining -= dt;
      if (state.transitionInvulnerableRemaining <= 0) {
        state.transitionInvulnerableRemaining = 0;
        state.attackDelayRemaining = tuning.firstAttackDelaySeconds;
      }
      return const BossStepEvent();
    }

    // ---- 3. 阶段推进（HP 阈值 70% / 35%）----
    final phaseEvent = _advancePhaseIfNeeded(state);
    if (phaseEvent != null) {
      return phaseEvent;
    }

    // ---- 4. 狂暴判定（唯一变化：激光扫射时长）----
    // 「P3 开始、技能冷却结束且 HP ≤10%」或「180 秒未击败」。
    if (!state.enraged && state.phase == BossPhase.p3) {
      final ready = state.currentAttack == null &&
          state.telegraphRemaining <= 0 &&
          state.attackDelayRemaining <= 0;
      if ((ready && state.hpRatio <= 0.10) || combatSeconds >= enrageAtSeconds) {
        state.enraged = true;
      }
    }

    // ---- 5. 召唤阻塞 ----
    if (state.summonBlocking) {
      if (summonCleared) {
        state.summonBlocking = false;
        state.attackDelayRemaining = tuning.minDelayBetweenAttacksSeconds;
      }
      return const BossStepEvent();
    }

    // ---- 6. 招式推进 ----
    return _stepAttack(
      state: state,
      dt: dt,
      combatSeconds: combatSeconds,
      playerPosition: playerPosition,
    );
  }

  BossStepEvent? _advancePhaseIfNeeded(BossState state) {
    final ratio = state.hpRatio;
    BossPhase? target;
    for (final config in phases.reversed) {
      if (ratio > config.lowerHpRatio && ratio <= config.upperHpRatio) {
        target = config.phase;
        break;
      }
    }
    // HP 恰好为 0 时归入 P3。
    target ??= ratio <= 0 ? BossPhase.p3 : state.phase;

    if (target == state.phase) {
      return null;
    }

    state.phase = target;
    state.loopIndex = 0;
    state.currentAttack = null;
    state.telegraphRemaining = 0;
    state.actionRemaining = 0;
    state.bodyContactActive = false;
    state.weakpointActive = false;
    // 转阶段：1.2 s 不可受击，并清理所有敌方投射物与危险区。
    state.transitionInvulnerableRemaining =
        tuning.phaseTransitionInvulnerableSeconds;

    return BossStepEvent(phaseChangedTo: target);
  }

  BossStepEvent _stepAttack({
    required BossState state,
    required double dt,
    required double combatSeconds,
    required Vec2 playerPosition,
  }) {
    // ---- 执行中的持续招式 ----
    if (state.actionRemaining > 0) {
      state.actionRemaining -= dt;
      if (state.actionRemaining <= 0) {
        state.actionRemaining = 0;
        final ended = state.currentAttack;
        state.currentAttack = null;
        state.bodyContactActive = false;
        var weakpointClosed = false;
        if (state.weakpointActive) {
          state.weakpointActive = false;
          weakpointClosed = true;
        }
        if (state.currentAttack == BossAttackIds.summon) {
          state.summonBlocking = true;
        }
        state.attackDelayRemaining = tuning.minDelayBetweenAttacksSeconds;
        return BossStepEvent(
          attackEnded: ended,
          weakpointClosed: weakpointClosed,
        );
      }
      return const BossStepEvent();
    }

    // ---- 预警中 ----
    if (state.telegraphRemaining > 0) {
      state.telegraphRemaining -= dt;
      if (state.telegraphRemaining > 0) {
        return const BossStepEvent();
      }
      state.telegraphRemaining = 0;
      final attack = state.currentAttack!;
      final event = _buildEvent(
        state: state,
        attackId: attack,
        combatSeconds: combatSeconds,
        playerPosition: playerPosition,
      );
      _beginAction(state, attack);
      final endedImmediately = state.actionRemaining <= 0;
      if (endedImmediately) {
        state.currentAttack = null;
        state.attackDelayRemaining = tuning.minDelayBetweenAttacksSeconds;
      }
      return BossStepEvent(attackFired: event);
    }

    // ---- 等冷却 ----
    if (state.attackDelayRemaining > 0) {
      state.attackDelayRemaining -= dt;
      if (state.attackDelayRemaining > 0) {
        return const BossStepEvent();
      }
      state.attackDelayRemaining = 0;
    }

    // ---- 开始下一招 ----
    final config = phases.firstWhere((c) => c.phase == state.phase);
    final attackId = config.loop[state.loopIndex % config.loop.length];
    state.loopIndex = (state.loopIndex + 1) % config.loop.length;
    state.currentAttack = attackId;
    state.telegraphRemaining = _telegraphFor(attackId);

    final event = _buildEvent(
      state: state,
      attackId: attackId,
      combatSeconds: combatSeconds,
      playerPosition: playerPosition,
    );

    // 无预警的招式（核心暴露）立即进入执行期。
    if (state.telegraphRemaining <= 0) {
      _beginAction(state, attackId);
      return BossStepEvent(
        telegraphStarted: event,
        attackFired: event,
        weakpointOpened: state.weakpointActive,
      );
    }

    return BossStepEvent(telegraphStarted: event);
  }

  double _telegraphFor(String attackId) {
    switch (attackId) {
      case BossAttackIds.fan:
        return 0.7;
      case BossAttackIds.charge:
        return 0.8;
      case BossAttackIds.ring:
        return 0.9;
      case BossAttackIds.summon:
        return 0.6;
      case BossAttackIds.laser:
        return 0.9;
      case BossAttackIds.weakpoint:
        return 0.0; // 核心暴露无预警
      default:
        return 0.0;
    }
  }

  void _beginAction(BossState state, String attackId) {
    switch (attackId) {
      case BossAttackIds.charge:
        state.bodyContactActive = true;
        state.actionRemaining =
            chargeTravelSeconds + chargePostArrivalPauseSeconds;
      case BossAttackIds.laser:
        state.actionRemaining = state.enraged
            ? laserEnragedSweepSeconds
            : laserSweepSeconds;
      case BossAttackIds.weakpoint:
        state.weakpointActive = true;
        state.actionRemaining = weakpointExposeSeconds;
      case BossAttackIds.summon:
        state.actionRemaining = 0; // 召唤瞬时完成，随后进入阻塞
        state.summonBlocking = true;
      default:
        state.actionRemaining = 0;
    }
  }

  BossAttackEvent _buildEvent({
    required BossState state,
    required String attackId,
    required double combatSeconds,
    required Vec2 playerPosition,
  }) {
    final origin = state.position;
    switch (attackId) {
      case BossAttackIds.fan:
        return BossAttackEvent(
          attackId: attackId,
          origin: origin,
          // 中心方向在预警开始时锁定为 Boss 指向玩家中心。
          aimTarget: playerPosition,
          telegraphSeconds: 0.7,
          projectileCount: 5,
          angleOffsetsDegrees: const <double>[-24, -12, 0, 12, 24],
          damage: 12,
          speed: 1200,
          radius: 12,
          lifetimeSeconds: 2.0,
        );
      case BossAttackIds.charge:
        final remembered = playerPositionAgo(
          combatSeconds,
          chargeTargetLookbackSeconds,
        );
        final targetX = remembered.x.clamp(
          chargeTargetClampMinX,
          chargeTargetClampMaxX,
        );
        return BossAttackEvent(
          attackId: attackId,
          origin: origin,
          aimTarget: Vec2(targetX, origin.y),
          telegraphSeconds: 0.8,
          damage: tuning.bodyContactDamage,
        );
      case BossAttackIds.ring:
        return BossAttackEvent(
          attackId: attackId,
          origin: origin,
          aimTarget: playerPosition,
          telegraphSeconds: 0.9,
          projectileCount: 16,
          damage: 10,
          speed: 520,
          radius: 12,
          lifetimeSeconds: 2.8,
        );
      case BossAttackIds.summon:
        return BossAttackEvent(
          attackId: attackId,
          origin: origin,
          aimTarget: playerPosition,
          telegraphSeconds: 0.6,
          summonPositions: summonPositions,
        );
      case BossAttackIds.laser:
        return BossAttackEvent(
          attackId: attackId,
          origin: origin,
          aimTarget: const Vec2(1680, 1020),
          telegraphSeconds: 0.9,
          damage: 8,
          sweepSeconds: state.enraged
              ? laserEnragedSweepSeconds
              : laserSweepSeconds,
        );
      case BossAttackIds.weakpoint:
        return BossAttackEvent(
          attackId: attackId,
          origin: origin,
          aimTarget: origin,
          telegraphSeconds: 0,
          exposeSeconds: weakpointExposeSeconds,
        );
      default:
        return BossAttackEvent(
          attackId: attackId,
          origin: origin,
          aimTarget: playerPosition,
          telegraphSeconds: 0,
        );
    }
  }

  void reset() => _playerHistory.clear();
}
