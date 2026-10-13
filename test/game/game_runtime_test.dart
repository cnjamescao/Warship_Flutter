// ================================================================
// test/game/game_runtime_test.dart —— 帧循环与相位门禁
// ================================================================
// 覆盖 P0：T-CORE-02（仅 Playing 推进逻辑；其余状态完全冻结）
//       以及运行时的基础集成：生成、开火、命中、突破。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/core/game_clock.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime buildRuntime() {
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
        contentVersion: '2.0.4-release',
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

    test('升级草案与风险门同样冻结全部逻辑', () {
      for (final phase in <GamePhase>[
        GamePhase.upgradeDraft,
        GamePhase.riskGate,
      ]) {
        final rt = buildRuntime();
        runSeconds(rt, 2.0);
        final stepsBefore = rt.logicSteps;
        final positionBefore = rt.player.position;

        rt.phases.transitionTo(phase, reason: 'test');
        runSeconds(rt, 5.0, input: const InputFrame(moveDirection: Vec2(1, 0)));

        expect(rt.logicSteps, stepsBefore, reason: '${phase.name} 必须冻结');
        expect(rt.player.position, positionBefore);
      }
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
      rt.bus.drain();
      runSeconds(rt, 0.2);

      final events = rt.bus.drain();
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
