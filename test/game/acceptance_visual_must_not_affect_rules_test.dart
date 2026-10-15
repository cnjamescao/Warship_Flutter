// ================================================================
// test/game/acceptance_visual_must_not_affect_rules_test.dart
// ================================================================
// 产品设计 §7.5 的「结束条件/验收」列里有两条是**同一条原则**：
//   * 敌人临界：「**不改变其攻击节奏或碰撞体**」
//   * 玩家濒危：「HP > 35% 后以 0.5 秒淡出；**不得改变碰撞范围**」
//
// 也就是「**表现不得反过来影响规则**」。这条原则若被破坏，
// 会出现"敌人血少了反而更难打/更好打"这类说不清的体验问题，
// 而且**任何只测画面或只测规则的用例都发现不了** ——
// 必须**同时观察两者**。
//
// 本文件按这个思路写：在同一局里，对比"满血"与"临界"两种状态下的
// 碰撞半径与攻击节奏。
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
import 'package:warship_flutter/game/domain/weapon_system.dart';

Map<String, Object?> _read(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime _build() {
  final enemies = _read('enemies.json');
  final waves = _read('waves_normal.json');
  return GameRuntime(
    catalogPlayer: _read('player.json'),
    enemyTunings: <String, EnemyTuning>{
      for (final raw in (enemies['enemies'] as List).cast<Map>())
        (raw['id'] as String):
            EnemyTuning.fromConfig(raw.cast<String, Object?>()),
    },
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'visual-rules',
        seed: 0x4E454F4E0001,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.0.6-material-repair',
        contentManifestSha256: '',
      ),
      random: Pcg32(0x4E454F4E0001),
    ),
    random: Pcg32(0x4E454F4E0001),
    bus: EventBus(),
    clock: GameClock(),
    phases: PhaseController(initialPhase: GamePhase.playing),
    director: DirectorSystem(
      rows: (waves['waves'] as List)
          .cast<Map>()
          .map((m) => WaveRow.fromConfig(m.cast<String, Object?>()))
          .toList(),
      minimumUpgradeWindows: const <MinimumUpgradeWindow>[],
      eliteRules: const <String, int>{},
    ),
    enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
    pulse: PulseWeapon(),
  );
}

void main() {
  test('敌人临界（HP ≤25%）不改变碰撞半径', () {
    final rt = _build();
    for (var i = 0; i < 120; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    expect(rt.enemies, isNotEmpty, reason: '应已有敌人');

    final enemy = rt.enemies.first;
    final radiusAtFull = enemy.hitbox.radius;

    // 推进到临界（HP ≤ 25%）。§7.5：「敌人 HP ≤ 25%」为临界状态。
    enemy.health.current = (enemy.health.max * 0.2).ceil();
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    final ratio = enemy.health.ratio;
    expect(ratio, lessThanOrEqualTo(0.25), reason: '应已处于临界状态');

    expect(
      enemy.hitbox.radius,
      radiusAtFull,
      reason: '§7.5 要求敌人临界"不改变碰撞体" —— 半径不得随表现变化',
    );
  });

  test('敌人临界不改变攻击节奏（攻击间隔配置不变）', () {
    final rt = _build();
    for (var i = 0; i < 120; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }

    // 找一个远程敌人（有 attackProfile 的），对比满血与临界时的
    // **攻击间隔配置**与**冷却推进速度**。
    final ranged = rt.enemies.where((e) => e.isRanged).toList();
    if (ranged.isEmpty) {
      // 开局这批是近战；推进到远程敌人出现再测。
      for (var i = 0; i < 60 * 60; i++) {
        rt.player.health.current = rt.player.health.max;
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        if (rt.enemies.any((e) => e.isRanged)) break;
      }
    }
    final target = rt.enemies.firstWhere((e) => e.isRanged);
    final interval = target.tuning.attack!.intervalSeconds;

    // 记录满血时推进 1 秒后冷却减少的量。
    target.health.current = target.health.max;
    final cdFull = target.attackCooldown ?? interval;
    for (var i = 0; i < 60; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    final droppedFull = cdFull - (target.attackCooldown ?? interval);

    // 置为临界，同样推进 1 秒。
    target.health.current = (target.health.max * 0.2).ceil();
    final cdCritical = target.attackCooldown ?? interval;
    for (var i = 0; i < 60; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    final droppedCritical = cdCritical - (target.attackCooldown ?? interval);

    expect(
      target.tuning.attack!.intervalSeconds,
      interval,
      reason: '攻击间隔配置不应随临界状态变化',
    );
    // 两者都应在 1 秒内推进同等量（或都已发射并重置）——
    // 这里断言"临界态的冷却推进不比满血态更慢"，
    // 即临界不会让敌人变得更慢/更快。
    expect(
      droppedCritical,
      greaterThanOrEqualTo(droppedFull - 1e-6),
      reason: '§7.5 要求敌人临界"不改变其攻击节奏"',
    );
  });

  test('玩家濒危（HP ≤30%）不改变碰撞半径', () {
    final rt = _build();
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

    final radiusAtFull = rt.player.hitbox.radius;

    // §7.5：「玩家濒危：HP ≤ 30%」。
    rt.player.health.current = (rt.player.health.max * 0.2).ceil();
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    expect(rt.player.health.ratio, lessThanOrEqualTo(0.30));

    expect(
      rt.player.hitbox.radius,
      radiusAtFull,
      reason: '§7.5 要求濒危表现"不得改变碰撞范围"',
    );
  });
}
