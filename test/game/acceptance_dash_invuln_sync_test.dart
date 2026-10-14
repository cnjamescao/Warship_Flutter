// ================================================================
// test/game/acceptance_dash_invuln_sync_test.dart —— AC-05 结束条件
// ================================================================
// 产品设计 §7.5 玩家无敌冲刺的结束条件是：
//   「**无敌结束即撤销高亮**；不与濒危色冲突（使用外轮廓优先）」，
//   且「**机体不可见性必须与无敌一致**」。
//
// 也就是：**表现层的"高亮/无敌"标记必须与规则层的无敌状态严格同步** ——
// 既不能无敌已结束但高亮还在（玩家以为还无敌），
// 也不能高亮已撤销但无敌还在（玩家白挨一下）。
//
// 本文件断言这条同步：`RenderSnapshot.isPlayerInvulnerable`（表现取用）
// 必须与 `player.isInvulnerable`（规则）**逐帧一致**。
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
        runId: 'dash-sync',
        seed: 0x4E454F4E0001,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.0.5-release',
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
  test('冲刺确实带来无敌，且无敌会自行结束', () {
    final rt = _build();

    // 冲刺需要一个方向输入。
    rt.advance(
      GameClock.fixedStepSeconds,
      const InputFrame(moveDirection: Vec2(-1, 0), dashRequested: true),
    );

    expect(
      rt.player.isInvulnerable,
      isTrue,
      reason: '冲刺激活后应进入无敌',
    );

    // 推进到无敌时长之后。
    var sawInvulnerableEnd = false;
    for (var i = 0; i < 120; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      if (!rt.player.isInvulnerable) {
        sawInvulnerableEnd = true;
        break;
      }
    }

    expect(
      sawInvulnerableEnd,
      isTrue,
      reason: '§7.5 要求"无敌结束即撤销高亮" —— 无敌本身必须会结束',
    );
  });

  test('表现层的无敌标记与规则层逐帧一致（「不可见性必须与无敌一致」）', () {
    final rt = _build();

    rt.advance(
      GameClock.fixedStepSeconds,
      const InputFrame(moveDirection: Vec2(1, 0), dashRequested: true),
    );

    var mismatch = <String>[];
    // 覆盖冲刺全程 + 结束后一段，确保跨越"无敌结束"那一帧。
    for (var i = 0; i < 180; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

      final rule = rt.player.isInvulnerable;
      final visual = rt.snapshot().isPlayerInvulnerable;
      if (rule != visual) {
        mismatch.add('frame$i: 规则=$rule 表现=$visual');
      }
    }

    expect(
      mismatch,
      isEmpty,
      reason: '§7.5：「机体不可见性必须与无敌一致」—— '
          '表现标记与规则状态出现不一致：$mismatch',
    );
  });

  test('无敌结束后不再处于"冲刺中"（表现撤销）', () {
    final rt = _build();
    rt.advance(
      GameClock.fixedStepSeconds,
      const InputFrame(moveDirection: Vec2(0, -1), dashRequested: true),
    );
    expect(rt.player.isInvulnerable, isTrue);

    for (var i = 0; i < 120; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }

    expect(rt.player.isInvulnerable, isFalse, reason: '无敌应已结束');
    expect(
      rt.snapshot().isPlayerInvulnerable,
      isFalse,
      reason: '§7.5 要求"无敌结束即撤销高亮" —— 快照不得仍标记为无敌',
    );
  });
}
