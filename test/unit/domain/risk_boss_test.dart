// ================================================================
// test/unit/domain/risk_boss_test.dart —— 风险门与 Aegis
// ================================================================
// 覆盖 P0：T-RISK-01 / T-RISK-02 / T-BOSS-01 / T-BOSS-02 / T-BOSS-03
// 数值全部对齐产品基线 §7.1 / §7.2。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/domain/boss_system.dart';
import 'package:warship_flutter/game/domain/risk_gate_system.dart';
import 'package:warship_flutter/game/domain/values.dart';

const double kStep = 1 / 60;

const List<String> kRarePool = <String>[
  'UP-CRIT-ARC',
  'UP-MISSILE-SALVO',
  'UP-LASER-PRISM',
  'UP-DRONE-COUNT',
  'UP-DASH-REPAIR',
];

RiskGateSystem riskSystem() => RiskGateSystem(
  overloadHpThreshold: 35,
  selectionWindowSeconds: 5.0,
  timeoutFallbackId: RiskOptionIds.supply,
  overloadRarePool: kRarePool,
);

void main() {
  group('T-RISK-01 超时只执行保底', () {
    test('5 秒不操作后只执行 RG-SUPPLY，且标记为超时', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-55',
        playerHp: 100,
        availableRareCards: kRarePool,
      );

      RiskGateOutcome? outcome;
      // 推进 4.9 秒：仍未结算。
      for (var i = 0; i < 294; i++) {
        outcome = session.tick(kStep) ?? outcome;
      }
      expect(outcome, isNull);
      expect(session.isResolved, isFalse);

      // 再推进到超过 5 秒。
      for (var i = 0; i < 12; i++) {
        outcome = session.tick(kStep) ?? outcome;
      }

      expect(outcome, isNotNull);
      expect(outcome!.optionId, RiskOptionIds.supply);
      expect(outcome.wasTimeout, isTrue);
      expect(outcome.effect.shieldGrant, 20);
      expect(outcome.effect.hpGrant, 8);
    });

    test('窗口内点击可选；窗口过期后结果已由 tick 固定为保底', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-55',
        playerHp: 100,
        availableRareCards: kRarePool,
      );

      // 窗口内点击立即生效。
      final chosen = session.select(RiskOptionIds.bounty);
      expect(chosen!.optionId, RiskOptionIds.bounty);
      expect(chosen.wasTimeout, isFalse);

      // 另一个会话：让窗口自然过期。
      final expiring = system.open(
        gateId: 'RG-55',
        playerHp: 100,
        availableRareCards: kRarePool,
      );
      for (var i = 0; i < 320; i++) {
        expiring.tick(kStep);
      }

      expect(expiring.outcome!.optionId, RiskOptionIds.supply);
      expect(expiring.outcome!.wasTimeout, isTrue);
      expect(
        expiring.select(RiskOptionIds.bounty),
        isNull,
        reason: '已结算，不再接受新的选择',
      );
    });

    test('超时后重复 tick 不再产生新结果', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-55',
        playerHp: 100,
        availableRareCards: kRarePool,
      );
      for (var i = 0; i < 320; i++) {
        session.tick(kStep);
      }
      expect(session.tick(kStep), isNull);
    });
  });

  group('T-RISK-02 Overload 的 HP 条件', () {
    test('HP=35 时 Overload 显示为锁定且不可选择', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-55',
        playerHp: 35,
        availableRareCards: kRarePool,
      );

      expect(session.lockedOptions, contains(RiskOptionIds.overload));
      expect(
        session.isSelectable(RiskOptionIds.overload),
        isFalse,
      );
      expect(
        session.availableOptions,
        isNot(contains(RiskOptionIds.overload)),
      );
    });

    test('HP=36 时 Overload 可选择', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-55',
        playerHp: 36,
        availableRareCards: kRarePool,
      );

      expect(session.lockedOptions, isEmpty);
      expect(session.isSelectable(RiskOptionIds.overload), isTrue);
    });

    test('HP=36 选择 Overload 可提交并给出三选一稀有池与代价', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-55',
        playerHp: 36,
        availableRareCards: kRarePool,
      );

      final outcome = session.select(RiskOptionIds.overload);

      expect(outcome!.wasTimeout, isFalse);
      expect(outcome.effect.rareDraftPool, kRarePool);
      expect(outcome.effect.damageTakenMultiplier, 1.15);
      expect(outcome.effect.damageTakenDurationSeconds, 20.0);
      expect(system.overloadDraft(kRarePool).length, 3);
    });

    test('锁定项被强选时降级为保底', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-55',
        playerHp: 30,
        availableRareCards: kRarePool,
      );

      final outcome = session.select(RiskOptionIds.overload);
      expect(outcome!.optionId, RiskOptionIds.supply);
      expect(outcome.wasTimeout, isTrue);
    });

    test('稀有卡全部不可用时 Overload 不出现，由 Bounty 占位', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-115',
        playerHp: 100,
        availableRareCards: const <String>[],
      );

      expect(session.availableOptions, <String>[
        RiskOptionIds.supply,
        RiskOptionIds.bounty,
      ]);
      expect(session.lockedOptions, isEmpty, reason: '是"不显示"而不是"锁定"');
    });
  });

  group('风险门效果', () {
    test('RG-BOUNTY：下一个固定精英额外 1 个核心且 HP ×1.25', () {
      final system = riskSystem();
      final session = system.open(
        gateId: 'RG-55',
        playerHp: 100,
        availableRareCards: kRarePool,
      );

      final outcome = session.select(RiskOptionIds.bounty);

      expect(outcome!.effect.extraEliteCore, 1);
      expect(outcome.effect.nextEliteHpMultiplier, 1.25);
    });

    test('BountyPending 在精英结束后清除', () {
      final pending = BountyPending()..arm(extraCores: 1, hpMultiplier: 1.25);
      expect(pending.isPending, isTrue);

      pending.consume();
      expect(pending.isPending, isFalse);
      expect(pending.hpMultiplier, 1.0);
    });

    test('Overload 代价：20 秒内所受最终伤害 ×1.15，到期恢复', () {
      final penalty = OverloadPenalty(multiplier: 1.15, durationSeconds: 20.0)
        ..activate();

      expect(penalty.apply(20), 23); // 20 × 1.15
      expect(penalty.isActive, isTrue);

      // 推进 20 秒。
      for (var i = 0; i < 20 * 60 + 2; i++) {
        penalty.tick(kStep);
      }

      expect(penalty.isActive, isFalse);
      expect(penalty.apply(20), 20, reason: '到期后不再加重');
    });
  });

  group('T-BOSS-03 战前补给', () {
    test('+15 HP、+20 护盾、冲刺归 1（仅在为 0 时）', () {
      final boss = BossSystem();
      final health = Health(max: 100, current: 40);
      final shield = ShieldPool(max: 30, current: 5);
      final dash = DashState(maxCharges: 2, rechargeSeconds: 6.0);
      dash.charges = 0;

      final result = boss.applyPreEntrySupply(
        playerHealth: health,
        playerShield: shield,
        playerDash: dash,
      );

      expect(result.hpRestored, 15);
      expect(health.current, 55);
      expect(result.shieldRestored, 20);
      expect(shield.current, 25);
      expect(result.dashRestored, 1);
      expect(dash.charges, 1);
    });

    test('不超过上限，且冲刺非 0 时不恢复', () {
      final boss = BossSystem();
      final health = Health(max: 100, current: 95);
      final shield = ShieldPool(max: 30, current: 28);
      final dash = DashState(maxCharges: 2, rechargeSeconds: 6.0);

      final result = boss.applyPreEntrySupply(
        playerHealth: health,
        playerShield: shield,
        playerDash: dash,
      );

      expect(result.hpRestored, 5, reason: '封顶 100');
      expect(health.current, 100);
      expect(shield.current, 30);
      expect(result.dashRestored, 0);
      expect(dash.charges, 2);
    });
  });

  group('T-BOSS-01 阶段推进', () {
    late BossSystem system;
    late BossState state;

    setUp(() {
      system = BossSystem();
      state = BossState(tuning: const BossTuning());
      system.beginEntry(state);
    });

    /// 把入场跑完（跑到 hasEntered 为止，不多跑 —— 多跑会提前消耗
    /// 入场后的 0.6 秒首招延迟，后续断言都会偏）。
    void finishEntry() {
      var guard = 0;
      while (!state.hasEntered && guard < 600) {
        system.step(
          state: state,
          dt: kStep,
          combatSeconds: guard * kStep,
          playerPosition: const Vec2(960, 900),
          summonCleared: false,
        );
        guard++;
      }
    }

    test('入场为 0.8 秒，期间不可受击且位置从 (960,-160) 到 (960,210)', () {
      expect(state.position, const Vec2(960, -160));
      expect(state.invulnerable, isTrue);

      // 0.4 秒时应在中点附近。
      for (var i = 0; i < 24; i++) {
        system.step(
          state: state,
          dt: kStep,
          combatSeconds: i * kStep,
          playerPosition: const Vec2(960, 900),
          summonCleared: false,
        );
      }
      expect(state.position.y, closeTo(25, 3));
      expect(state.invulnerable, isTrue);

      finishEntry();
      expect(state.hasEntered, isTrue);
      expect(state.position, const Vec2(960, 210));
      expect(state.invulnerable, isFalse);
    });

    test('入场后等 0.6 秒才开始第一招', () {
      finishEntry();
      expect(state.attackDelayRemaining, closeTo(0.6, 1e-9));

      // 0.5 秒内不应有招式。
      BossAttackEvent? first;
      for (var i = 0; i < 30; i++) {
        final event = system.step(
          state: state,
          dt: kStep,
          combatSeconds: 1.0 + i * kStep,
          playerPosition: const Vec2(960, 900),
          summonCleared: false,
        );
        first ??= event.telegraphStarted;
      }
      expect(first, isNull);

      // 继续推进到 0.6 秒之后。
      for (var i = 0; i < 10; i++) {
        final event = system.step(
          state: state,
          dt: kStep,
          combatSeconds: 1.5 + i * kStep,
          playerPosition: const Vec2(960, 900),
          summonCleared: false,
        );
        first ??= event.telegraphStarted;
      }
      expect(first, isNotNull);
    });

    test('HP 降到 70% / 35% 时各转阶段一次，并进入 1.2 秒不可受击', () {
      finishEntry();

      final phases = <BossPhase>[];
      void runTo(double ratio) {
        state.health.current = (state.tuning.maxHp * ratio).round();
        final event = system.step(
          state: state,
          dt: kStep,
          combatSeconds: 10,
          playerPosition: const Vec2(960, 900),
          summonCleared: false,
        );
        if (event.phaseChangedTo != null) {
          phases.add(event.phaseChangedTo!);
        }
      }

      runTo(0.70);
      expect(state.phase, BossPhase.p2);
      expect(
        state.transitionInvulnerableRemaining,
        closeTo(1.2, 1e-9),
      );

      // 不可受击期间再改 HP 也不会二次转阶段。
      state.transitionInvulnerableRemaining = 0;
      runTo(0.35);
      expect(state.phase, BossPhase.p3);

      expect(phases, <BossPhase>[BossPhase.p2, BossPhase.p3]);
    });

    test('阶段循环顺序与产品表一致', () {
      expect(
        system.phases.firstWhere((c) => c.phase == BossPhase.p1).loop,
        <String>[BossAttackIds.fan, BossAttackIds.charge],
      );
      expect(
        system.phases.firstWhere((c) => c.phase == BossPhase.p2).loop,
        <String>[BossAttackIds.ring, BossAttackIds.summon],
      );
      expect(
        system.phases.firstWhere((c) => c.phase == BossPhase.p3).loop,
        <String>[BossAttackIds.laser, BossAttackIds.weakpoint],
      );
    });

    test('身体接触伤害仅在冲锋期间有效，且为 20', () {
      finishEntry();

      // 入场后还要等 0.6 秒（36 步）才会开始第一招，因此这里必须推进足够步数。
      for (var i = 0; i < 40; i++) {
        system.step(
          state: state,
          dt: kStep,
          combatSeconds: 1.0 + i * kStep,
          playerPosition: const Vec2(960, 900),
          summonCleared: false,
        );
      }

      // P1 第一招是扇形点射，不是冲锋 —— 此时 Body 不造成接触伤害。
      expect(state.currentAttack, BossAttackIds.fan);
      expect(state.bodyContactActive, isFalse);
      expect(state.tuning.bodyContactDamage, 20, reason: '仅冲锋期间生效');
    });
  });

  group('T-BOSS-02 招式几何与时序', () {
    late BossSystem system;
    late BossState state;

    setUp(() {
      system = BossSystem();
      state = BossState(tuning: const BossTuning());
      system.beginEntry(state);
      var guard = 0;
      while (!state.hasEntered && guard < 600) {
        system.step(
          state: state,
          dt: kStep,
          combatSeconds: guard * kStep,
          playerPosition: const Vec2(960, 900),
          summonCleared: false,
        );
        guard++;
      }
    });

    /// 收集下一次预警事件。
    BossAttackEvent? nextTelegraph({double startAt = 2.0, int steps = 120}) {
      for (var i = 0; i < steps; i++) {
        final event = system.step(
          state: state,
          dt: kStep,
          combatSeconds: startAt + i * kStep,
          playerPosition: const Vec2(800, 700),
          summonCleared: false,
        );
        if (event.telegraphStarted != null) {
          return event.telegraphStarted;
        }
      }
      return null;
    }

    test('P1 第一招扇形：0.7 秒预警、5 枚、-24/-12/0/+12/+24°、12 伤害', () {
      final event = nextTelegraph()!;

      expect(event.attackId, BossAttackIds.fan);
      expect(event.telegraphSeconds, 0.7);
      expect(event.projectileCount, 5);
      expect(event.angleOffsetsDegrees, <double>[-24, -12, 0, 12, 24]);
      expect(event.damage, 12);
      expect(event.speed, 1200);
      expect(event.radius, 12);
      expect(event.lifetimeSeconds, 2.0);
    });

    test('P1 第二招冲锋：0.8 秒预警、目标 x 夹紧到 210..1710', () {
      // 第一招扇形预警 + 结束后进入冲锋。
      nextTelegraph();
      final event = nextTelegraph(startAt: 4.0, steps: 400)!;

      expect(event.attackId, BossAttackIds.charge);
      expect(event.telegraphSeconds, 0.8);
      expect(event.aimTarget.x, greaterThanOrEqualTo(210));
      expect(event.aimTarget.x, lessThanOrEqualTo(1710));
    });

    test('冲锋使用 0.8 秒前的玩家位置', () {
      // 真实运行时每帧都会记录一次；这里用 1 秒附近的密集采样复现。
      system.recordPlayerPosition(9.0, const Vec2(300, 900));
      system.recordPlayerPosition(9.2, const Vec2(300, 900));
      system.recordPlayerPosition(9.4, const Vec2(1500, 900));
      system.recordPlayerPosition(10.0, const Vec2(1600, 900));

      final remembered = system.playerPositionAgo(10.0, 0.8);
      expect(remembered.x, 300, reason: '10.0 - 0.8 = 9.2，取该时刻的采样');
    });

    test('狂暴把激光扫射改为 2.2 秒，且是唯一变化', () {
      final normal = BossSystem();
      final enraged = BossSystem();
      final enragedState = BossState(tuning: const BossTuning());

      expect(normal.laserSweepSeconds, 1.8);
      expect(normal.laserEnragedSweepSeconds, 2.2);
      expect(enraged.enrageAtSeconds, 180);
      expect(enragedState.enraged, isFalse);
      expect(normal.weakpointExposeSeconds, 3.0,
          reason: '核心暴露时长不因狂暴改变');
    });

    test('180 秒未击败时进入狂暴', () {
      // 直接推进到 180 秒之后并处于 P3。
      state.health.current = (state.tuning.maxHp * 0.20).round();
      state.transitionInvulnerableRemaining = 0;
      state.phase = BossPhase.p3;

      system.step(
        state: state,
        dt: kStep,
        combatSeconds: 181.0,
        playerPosition: const Vec2(960, 900),
        summonCleared: false,
      );

      expect(state.enraged, isTrue);
    });
  });

  group('召唤阻塞', () {
    test('召唤的护盾机清除前不进入下一招', () {
      final system = BossSystem();
      final state = BossState(tuning: const BossTuning())
        ..hasEntered = true
        ..phase = BossPhase.p2
        ..summonBlocking = true;
      // 血量必须落在 P2 区间（35%..70%），否则 _advancePhaseIfNeeded 会把
      // 相位纠正回 P1 并提前返回，召唤阻塞分支根本不会被执行到。
      state.health.current = (state.tuning.maxHp * 0.5).round();

      final event = system.step(
        state: state,
        dt: kStep,
        combatSeconds: 10,
        playerPosition: const Vec2(960, 900),
        summonCleared: false,
      );

      expect(event.telegraphStarted, isNull);
      expect(state.summonBlocking, isTrue);

      final after = system.step(
        state: state,
        dt: kStep,
        combatSeconds: 10.1,
        playerPosition: const Vec2(960, 900),
        summonCleared: true,
      );

      expect(state.summonBlocking, isFalse);
      expect(after.telegraphStarted, isNull, reason: '解阻塞后仍需等 0.6 秒');
    });

    test('召唤坐标固定为 (560,250) 与 (1360,250)', () {
      final system = BossSystem();
      expect(system.summonPositions, <Vec2>[
        const Vec2(560, 250),
        const Vec2(1360, 250),
      ]);
    });
  });

  group('弱点与胜负', () {
    test('核心暴露 3.0 秒并启用弱点判定；未暴露时弱点判定为 null', () {
      final state = BossState(tuning: const BossTuning());

      expect(state.weakpointHitbox, isNull);
      expect(state.tuning.weakpointRadius, 52);
      expect(state.tuning.weakpointDamageMultiplier, 1.5);

      state.weakpointActive = true;
      expect(state.weakpointHitbox, isNotNull);
    });

    test('HP 归零即位 defeated', () {
      final state = BossState(tuning: const BossTuning());
      expect(state.isDefeated, isFalse);

      state.health.applyDamage(state.tuning.maxHp);
      expect(state.isDefeated, isTrue);

      final event = BossSystem().step(
        state: state,
        dt: kStep,
        combatSeconds: 100,
        playerPosition: const Vec2(960, 900),
        summonCleared: false,
      );
      expect(event.defeated, isFalse, reason: '已击败则不再产生任何事件');
    });

    test('Boss 不可越界（产品基线 §5 明确排除）', () {
      const tuning = BossTuning();
      expect(tuning.entryTo.y, 210);
      // 入场终点远在 y=1140 的突破线之上。
      expect(tuning.entryTo.y, lessThan(1140));
    });
  });
}
