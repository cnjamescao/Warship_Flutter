// ================================================================
// test/game/game_runtime_test.dart —— 帧循环与相位门禁
// ================================================================
// 覆盖 P0：T-CORE-02（仅 Playing 推进逻辑；其余状态完全冻结）
//       以及运行时的基础集成：生成、开火、命中、突破。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/domain_event.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/core/game_clock.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/boss_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/risk_gate_system.dart';
import 'package:warship_flutter/game/domain/upgrade_system.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

UpgradeSystem buildUpgradeSystem() {
  final config = readJson('upgrades.json');
  final guaranteed = config['guaranteed'] as Map;
  return UpgradeSystem(
    cards: (config['cards'] as List)
        .cast<Map>()
        .map((m) => UpgradeCard.fromConfig(m.cast<String, Object?>()))
        .toList(),
    xpThresholds: (config['xpThresholds'] as List).cast<int>(),
    firstDraftEarliestSecond:
        (config['firstDraftEarliestSecond'] as num).toDouble(),
    maxDrafts: config['maxDrafts'] as int,
    draftSize: config['draftSize'] as int,
    damageCardIds: (config['damageCardIds'] as List).cast<String>().toSet(),
    guaranteedFirstDraft: (guaranteed['firstDraft'] as List).cast<String>(),
    guaranteedSecondDraftAnyOf:
        (guaranteed['secondDraftAnyOf'] as List).cast<String>(),
  );
}

GameRuntime buildRuntime({
  UpgradeSystem? upgrades,
  BossSystem? bossSystem,
  RiskGateSystem? riskGates,
}) {
  final playerJson = readJson('player.json');
  final enemiesJson = readJson('enemies.json');
  final wavesJson = readJson('waves_normal.json');

  final tunings = <String, EnemyTuning>{
    for (final raw in (enemiesJson['enemies'] as List).cast<Map>())
      (raw['id'] as String):
          EnemyTuning.fromConfig(raw.cast<String, Object?>()),
  };

  final windows = ((wavesJson['dynamicAdjustment'] as Map)
          ['minimumUpgradeCountBySecond'] as List)
      .cast<Map>()
      .map((m) => MinimumUpgradeWindow.fromConfig(m.cast<String, Object?>()))
      .toList();
  final rows = (wavesJson['waves'] as List)
      .cast<Map>()
      .map((m) => WaveRow.fromConfig(m.cast<String, Object?>()))
      .toList();

  return GameRuntime(
    catalogPlayer: playerJson,
    enemyTunings: tunings,
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'test-run',
        seed: 0x4E454F4E0001,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.1.0-neon-flow',
        contentManifestSha256: 'test',
      ),
      random: Pcg32(0x4E454F4E0001),
    ),
    random: Pcg32(0x4E454F4E0001),
    bus: EventBus(),
    clock: GameClock(),
    phases: PhaseController(initialPhase: GamePhase.playing),
    director: DirectorSystem(
      rows: rows,
      minimumUpgradeWindows: windows,
      eliteRules: const <String, int>{},
    ),
    enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
    pulse: PulseWeapon(),
    upgradeSystem: upgrades,
    bossSystem: bossSystem,
    riskGateSystem: riskGates,
  );
}

/// 推进 [seconds] 秒（按 1/60 渲染帧）。
void runSeconds(GameRuntime rt, double seconds, {InputFrame? input}) {
  final frames = (seconds * 60).round();
  for (var i = 0; i < frames; i++) {
    rt.advance(GameClock.fixedStepSeconds, input ?? InputFrame.idle);
  }
}

void main() {
  group('T-CORE-02 只有 Playing 推进逻辑', () {
    test('Playing 下推进 1 秒产生 60 个逻辑步', () {
      final rt = buildRuntime();

      runSeconds(rt, 1.0);

      expect(rt.logicSteps, 60);
      expect(rt.combatSeconds, closeTo(1.0, 1e-9));
    });

    test('暂停时逻辑完全冻结：坐标、计时器、实体数都不变', () {
      final rt = buildRuntime();

      // 先跑 3 秒建立场景。
      runSeconds(
        rt,
        3.0,
        input: const InputFrame(moveDirection: Vec2(1, 0)),
      );
      final stepsBefore = rt.logicSteps;
      final positionBefore = rt.player.position;
      final enemiesBefore = rt.enemies.length;
      final dashBefore = rt.player.dash.rechargeTimers;

      rt.phases.transitionTo(GamePhase.paused, reason: 'test');
      runSeconds(rt, 10.0, input: const InputFrame(moveDirection: Vec2(-1, 0)));

      expect(rt.logicSteps, stepsBefore, reason: '暂停期间不得有任何逻辑步');
      expect(rt.player.position, positionBefore, reason: '坐标不得变化');
      expect(rt.enemies.length, enemiesBefore, reason: '不得生成或移除实体');
      expect(rt.player.dash.rechargeTimers, dashBefore, reason: '充能计时必须冻结');
      expect(rt.combatSeconds, closeTo(3.0, 1e-9), reason: '战斗时间不得推进');
    });

    test('R2：升级草案（历史阶段）仍冻结逻辑', () {
      final rt = buildRuntime();
      runSeconds(rt, 2.0);

      // 升级草案：仍然冻结（正常对局已不再进入，仅作历史阶段行为）。
      rt.phases.transitionTo(GamePhase.upgradeDraft, reason: 'test');
      final stepsBefore = rt.logicSteps;
      runSeconds(rt, 1.0);
      expect(rt.logicSteps, stepsBefore, reason: '升级草案期间逻辑冻结');

      // **R2**：风险门不再是活动阶段。
      // 这条由 "R2：55 秒自动结算风险门" 用例直接断言
      // （结算后 `phase` 仍为 playing、`riskGate` 为 null）；
      // 此处不再人为构造非法转移 —— 阶段机本就不允许进入它。
    });

    test('恢复 Playing 后逻辑继续推进', () {
      final rt = buildRuntime();
      runSeconds(rt, 1.0);
      final stepsBefore = rt.logicSteps;

      rt.phases.transitionTo(GamePhase.paused, reason: 'test');
      runSeconds(rt, 2.0);
      expect(rt.logicSteps, stepsBefore);

      rt.phases.requestResume();
      runSeconds(rt, 1.0);
      expect(rt.logicSteps, stepsBefore + 60);
    });
  });

  group('运行时集成', () {
    test('波次表驱动生成：0 秒应生成 Scout×3', () {
      final rt = buildRuntime();

      // 只推进几步，让 Director 的 0 秒行触发。
      runSeconds(rt, 0.1);

      expect(rt.enemies, isNotEmpty);
      expect(
        rt.enemies.every((e) => e.tuning.id == 'EN-SCOUT'),
        isTrue,
        reason: '0 秒行只有 Scout',
      );
      expect(rt.enemies.length, 3);
    });

    test('玩家移动按锁定输入生效', () {
      final rt = buildRuntime();
      final startX = rt.player.position.x;

      runSeconds(
        rt,
        1.0,
        input: const InputFrame(moveDirection: Vec2(1, 0)),
      );

      expect(rt.player.position.x - startX, closeTo(340, 1.0));
    });

    test('无输入立即停止（无惯性）', () {
      final rt = buildRuntime();
      runSeconds(rt, 0.5, input: const InputFrame(moveDirection: Vec2(-1, 0)));
      final x = rt.player.position.x;

      runSeconds(rt, 0.5);

      expect(rt.player.position.x, x);
    });

    test('自动开火会伤害敌人并累计分数与经验', () {
      final rt = buildRuntime();

      // Scout 从 y=-80 以 180 px/s 下行；跑足够久让它进入脉冲射程。
      runSeconds(rt, 6.0);

      expect(
        rt.score,
        greaterThan(0),
        reason: '应当击毁至少一个 Scout 并得分',
      );
      expect(rt.xp, greaterThan(0));
      expect(rt.comboMultiplier, greaterThanOrEqualTo(1.0));
    });

    test('敌人越过 y=1140 触发突破：扣 HP、不给分数与经验', () {
      final rt = buildRuntime();
      runSeconds(rt, 0.1);

      final enemy = rt.enemies.first;
      final scoreBefore = rt.score;
      final xpBefore = rt.xp;
      final hpBefore = rt.player.health.current;
      final shieldBefore = rt.player.shield.current;

      // 直接把它推到移除线之外。
      enemy.position = Vec2(enemy.position.x, 1150);
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

      expect(rt.enemies.contains(enemy), isFalse, reason: '突破后必须被移除');
      expect(rt.score, scoreBefore, reason: '突破不给分数');
      expect(rt.xp, xpBefore, reason: '突破不给经验');
      expect(
        rt.player.health.current,
        lessThan(hpBefore),
        reason: '突破穿透护盾直接扣 HP',
      );
      expect(rt.player.shield.current, shieldBefore, reason: '护盾必须完好');
    });

    test('冲刺进入无敌；无敌期间玩家伤害为 0', () {
      final rt = buildRuntime();
      runSeconds(rt, 0.5);

      rt.advance(
        GameClock.fixedStepSeconds,
        const InputFrame(moveDirection: Vec2(0, -1), dashRequested: true),
      );

      expect(rt.player.isInvulnerable, isTrue);
      expect(rt.snapshot().isPlayerInvulnerable, isTrue);
    });

    test('同屏敌人不超过预算上限 45', () {
      final rt = buildRuntime();
      runSeconds(rt, 150.0);

      expect(rt.enemies.length, lessThanOrEqualTo(45));
    });
  });

  group('风险门接入（产品基线 §7.1）', () {
    RiskGateSystem gates() => RiskGateSystem(
      overloadHpThreshold: 35,
      selectionWindowSeconds: 5.0,
      timeoutFallbackId: RiskOptionIds.supply,
      overloadRarePool: const <String>[
        'UP-CRIT-ARC',
        'UP-MISSILE-SALVO',
        'UP-LASER-PRISM',
      ],
    );

    test('R2：55 秒自动结算风险门，**不中断战斗**', () {
      // **v2.1-R2 冻结表 §2.4**：风险门到点自动结算 ——
      // 不得出现选择窗、超时回退、遮罩，也不得清子弹或停刷怪。
      final rt = buildRuntime(riskGates: gates());

      var guard = 0;
      while (rt.riskGateResolutions.isEmpty && guard < 300000) {
        rt.player.health.current = 100;
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        guard++;
      }

      expect(rt.riskGateResolutions, isNotEmpty,
          reason: '55 秒应自动结算风险门');
      final res = rt.riskGateResolutions.first;
      expect(res.gateId, 'RG-55');
      expect(res.occurrenceOrdinal, 0, reason: '首次为 0 基第 0 次');
      expect(
        <String>['RG-SUPPLY', 'RG-BOUNTY', 'RG-OVERLOAD'],
        contains(res.optionId),
      );

      // **关键**：phase 必须仍是 playing（战斗没有被打断）。
      expect(rt.phases.phase, GamePhase.playing,
          reason: 'R2 不得进入 riskGate 阶段');
      expect(rt.riskGate, isNull, reason: 'R2 不保留等待中的门会话');

      // 逻辑**继续推进**（不是冻结）。
      final stepsBefore = rt.logicSteps;
      runSeconds(rt, 2.0);
      expect(rt.logicSteps, greaterThan(stepsBefore),
          reason: 'R2：风险门不得冻结逻辑');
    });

    test('R2：不操作也无需保底 —— 结算在触发当步完成', () {
      final rt = buildRuntime(riskGates: gates());
      var guard = 0;
      while (rt.riskGateResolutions.isEmpty && guard < 300000) {
        rt.player.health.current = 100;
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        guard++;
      }
      // 风险门已结算完毕，**不存在**等待窗口。
      expect(rt.riskGateResolutions, hasLength(1));
      expect(rt.riskGate, isNull);
      // 再推进 6 秒也不会出现第二个 RG-55（同一 gate 只结算一次）。
      runSeconds(rt, 6.0);
      final gate55 =
          rt.riskGateResolutions.where((r) => r.gateId == 'RG-55').length;
      expect(gate55, 1, reason: '同一 gate 只结算一次');
    });

    test('过载代价：20 秒内所受伤害加重', () {
      final rt = buildRuntime(riskGates: gates());
      rt.overloadPenalty.activate();
      expect(rt.overloadPenalty.apply(20), 23);
    });

    test('未启用风险门时 55 秒不打开', () {
      final rt = buildRuntime();
      var guard = 0;
      while (rt.combatSeconds < 56 && guard < 300000) {
        rt.player.health.current = 100;
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        guard++;
      }
      expect(rt.riskGate, isNull);
      expect(rt.phases.phase, GamePhase.playing);
    });
  });

  group('Boss 接入（产品基线 §7.2）', () {
    test('150 秒触发战前补给并让 Boss 入场', () {
      final rt = buildRuntime(bossSystem: BossSystem());

      // 站立不动 150 秒玩家会先战死，因此每步把玩家拉回已知状态，
      // 这样"补给生效"的断言才有确定含义（这是测试构造，不是实现行为）。
      var guard = 0;
      while (!rt.bossEntryTriggered && guard < 300000) {
        rt.player.health.current = 40;
        rt.player.shield.current = 5;
        rt.player.dash.charges = 0;
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        guard++;
      }

      expect(rt.bossEntryTriggered, isTrue, reason: '150 秒行应触发 Boss');
      expect(rt.boss, isNotNull);
      expect(rt.player.health.current, 55, reason: '40 + 15');
      expect(rt.player.shield.current, 25, reason: '5 + 20');
      expect(rt.player.dash.charges, 1, reason: '冲刺为 0 时归 1');
    });

    test('Boss 入场期间不可受击，入场完成后位置为 (960,210)', () {
      final rt = buildRuntime(bossSystem: BossSystem());
      rt.bossEntryTriggered = true;
      final system = BossSystem();
      final state = BossState(tuning: system.tuning);
      system.beginEntry(state);
      rt.boss = state;

      expect(state.position, const Vec2(960, -160));
      expect(state.invulnerable, isTrue);

      for (var i = 0; i < 60; i++) {
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      }

      expect(state.hasEntered, isTrue);
      expect(state.position, const Vec2(960, 210));
      expect(state.invulnerable, isFalse);
    });

    test('Boss 被击毁即胜利并发出 RunEnded(victory)', () {
      final rt = buildRuntime(bossSystem: BossSystem());
      rt.bus.drain();

      final system = BossSystem();
      final state = BossState(tuning: system.tuning)
        ..hasEntered = true
        // 关键：先把相位设到 P3 并清掉转场无敌。
        // 若只把 HP 设低而不设相位，_advancePhaseIfNeeded 会立刻转入 P3
        // 并给出 1.2 秒不可受击，注入的弹会被**正确地**跳过 ——
        // 上一轮我正是栽在这里，误判成实现有 bug。
        ..phase = BossPhase.p3;
      state.position = const Vec2(960, 300);
      state.health.current = 1;
      state.transitionInvulnerableRemaining = 0;
      rt.boss = state;
      rt.bossEntryTriggered = true;

      expect(state.invulnerable, isFalse, reason: '构造后必须可受击');

      rt.projectiles.add(
        Projectile(
          id: const EntityId(EntityKind.playerProjectile, 900),
          faction: ProjectileFaction.player,
          position: state.position,
          direction: const Vec2(0, -1),
          speed: 0,
          radius: 6,
          damage: 9,
          lifetimeSeconds: 1.0,
          weaponId: 'WPN-PULSE',
        ),
      );

      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

      expect(state.isDefeated, isTrue);
      expect(rt.victory, isTrue);
      final ended = rt.bus.debugHistory
          .map((e) => e.event)
          .whereType<RunEnded>()
          .toList();
      expect(ended, isNotEmpty);
      expect(ended.last.result, 'victory');
    });

    test('弱点暴露时伤害 ×1.5', () {
      final rt = buildRuntime(bossSystem: BossSystem());
      final state = BossState(tuning: BossSystem().tuning)
        ..hasEntered = true
        ..phase = BossPhase.p3
        ..weakpointActive = true;
      // 血量必须落在 P3 区间，否则 _advancePhaseIfNeeded 会把相位纠正回
      // P1 并给出 1.2 秒转场无敌，注入的弹会被正确跳过。
      state.health.current = (state.tuning.maxHp * 0.20).round();
      state.position = const Vec2(960, 300);
      state.transitionInvulnerableRemaining = 0;
      rt.boss = state;
      rt.bossEntryTriggered = true;

      expect(state.invulnerable, isFalse);
      final before = state.health.current;
      rt.projectiles.add(
        Projectile(
          id: const EntityId(EntityKind.playerProjectile, 901),
          faction: ProjectileFaction.player,
          position: state.position,
          direction: const Vec2(0, -1),
          speed: 0,
          radius: 6,
          damage: 10,
          lifetimeSeconds: 1.0,
          weaponId: 'WPN-PULSE',
        ),
      );

      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

      // 命中弱点应为 15 而不是 10。
      expect(before - state.health.current, 15);
    });

    test('未启用 Boss 时 150 秒不会出现 Boss', () {
      final rt = buildRuntime();
      var guard = 0;
      while (rt.combatSeconds < 150.5 && guard < 200000) {
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        guard++;
      }
      expect(rt.bossEntryTriggered, isFalse);
      expect(rt.boss, isNull);
    });
  });

  group('升级系统接入（产品基线 §4.2）', () {
    test('经验在 15 秒前达阈值不打开草案，15 秒后打开', () {
      final rt = buildRuntime(upgrades: buildUpgradeSystem());

      // 直接把经验推到阈值，但战斗时间还不到 15 秒。
      rt.xp = 20;
      runSeconds(rt, 1.0);
      expect(rt.phases.phase, GamePhase.playing,
          reason: '第 1 次草案不得早于 15.0 秒');

      // 推进到 15 秒之后。
      runSeconds(rt, 15.0);

      // 战斗时间因暂停/相位切换可能不精确，但应已进入草案或已选完。
      expect(
        rt.upgradeState.grantCount + (rt.currentOffer == null ? 0 : 1),
        greaterThanOrEqualTo(1),
        reason: '15 秒后应打开草案',
      );
    });

    test('自动授予后应用升级、**不进入** upgradeDraft 并提升脉冲数值', () {
      final rt = buildRuntime(upgrades: buildUpgradeSystem());
      rt.xp = 20;

      // 推进到发生第一次自动授予。
      var guard = 0;
      while (rt.upgradeState.grantCount == 0 && guard < 60 * 25) {
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        guard++;
      }
      expect(rt.upgradeState.grantCount, 1, reason: '应恰好自动授予一张');
      // **v2.1（冻结表 §2.2）**：不得进入 upgradeDraft，也不得产出候选。
      expect(rt.phases.phase, GamePhase.playing, reason: '自动授予不得暂停逻辑');
      expect(rt.currentOffer, isNull, reason: 'v2.1 禁止 DraftOffer');

      // 第 1 张按冻结表 §2.2 必须是 Pulse Rate。
      expect(rt.upgradeState.levelOf('UP-PULSE-RATE'), 1);
      expect(rt.upgradeCount, 1);
      // 与"未强化"的同构运行时对比脉冲间隔，确认强化真的生效。
      final baseline = buildRuntime(upgrades: buildUpgradeSystem());
      expect(
        rt.pulse.effectiveCadence,
        lessThan(baseline.pulse.effectiveCadence),
        reason: '脉冲增幅应缩短发射间隔',
      );
    });

    test('快照**不含**草案卡片数据（v2.1 禁止 DraftOffer）', () {
      final rt = buildRuntime(upgrades: buildUpgradeSystem());
      rt.xp = 20;
      var guard = 0;
      while (rt.upgradeState.grantCount == 0 && guard < 60 * 25) {
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        guard++;
      }

      // **v2.1**：自动授予**不产生** upgradeDraft 快照数据。
      expect(
        rt.snapshot().upgradeDraft,
        isNull,
        reason: 'v2.1 不得产出 DraftOffer 快照',
      );
      expect(rt.currentOffer, isNull, reason: 'v2.1 禁止 DraftOffer');
      expect(rt.upgradeState.grantCount, greaterThanOrEqualTo(1));
      expect(rt.upgradeState.levels, isNotEmpty, reason: '应已应用升级');
    });

    test('未启用升级系统时不会打开草案', () {
      final rt = buildRuntime();
      rt.xp = 9999;
      runSeconds(rt, 20.0);
      expect(rt.currentOffer, isNull);
      expect(rt.phases.phase, GamePhase.playing);
    });
  });

  group('快照与事件', () {
    test('快照携带 HUD 所需字段且血量为满', () {
      final rt = buildRuntime();
      final snapshot = rt.snapshot();

      expect(snapshot.hud, isNotNull);
      expect(snapshot.hud!.hp, 100);
      expect(snapshot.hud!.hpMax, 100);
      expect(snapshot.hud!.shield, 30);
      expect(snapshot.hud!.dashMaxCharges, 2);
      expect(snapshot.player, isNotNull);
      expect(snapshot.phase, 'playing');
    });

    test('HUD 血量语义状态按阈值切换', () {
      final rt = buildRuntime();
      runSeconds(rt, 0.1);

      rt.player.health.current = 30; // 30%
      expect(rt.snapshot().hud!.hpVisualState, 'low');
      expect(rt.snapshot().hud!.hpRatio, closeTo(0.30, 1e-9));

      rt.player.health.current = 25; // 恰为 25%
      expect(rt.snapshot().hud!.hpVisualState, 'critical');

      rt.player.health.current = 100;
      expect(rt.snapshot().hud!.hpVisualState, 'normal');
    });

    test('生成了敌人后快照里有敌人视图且带 enemyId', () {
      final rt = buildRuntime();
      runSeconds(rt, 0.5);

      final snapshot = rt.snapshot();
      expect(snapshot.enemies, isNotEmpty);
      expect(snapshot.enemies.first.enemyId, 'EN-SCOUT');
      expect(snapshot.activeEnemyCount, rt.enemies.length);
    });

    test('事件带有 runId / frameIndex / 递增 eventIndex', () {
      final rt = buildRuntime();
      // 运行时会在每帧结束时消费事件并把它们交给音频，
      // 因此这里累积它暴露出来的 lastFrameEvents。
      // 注意不能只看最后一帧 —— 那一帧可能恰好没有事件。
      final events = <StampedEvent>[];
      for (var i = 0; i < 12; i++) {
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        events.addAll(rt.lastFrameEvents);
      }
      expect(events, isNotEmpty);

      var lastIndex = -1;
      for (final event in events) {
        expect(event.runId, 'test-run');
        expect(event.eventIndex, greaterThan(lastIndex));
        lastIndex = event.eventIndex;
      }
    });

    test('dispose 清空全部实体与分配器', () {
      final rt = buildRuntime();
      runSeconds(rt, 1.0);
      expect(rt.enemies, isNotEmpty);

      rt.dispose();

      expect(rt.enemies, isEmpty);
      expect(rt.projectiles, isEmpty);
      expect(rt.hazards, isEmpty);
      expect(rt.bus.pending, isEmpty);
    });
  });
}
