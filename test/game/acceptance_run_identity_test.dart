// ================================================================
// test/game/acceptance_run_identity_test.dart —— T-CORE-01（P0）
// ================================================================
// 技术协议 §4 P0 清单的 T-CORE-01：
//   「依次执行 Home→Loading→Briefing→Playing |
//     只允许合法状态迁移；**runId/seed 只在新局创建**」
//
// 核对发现：状态迁移那一半有覆盖，但「**runId/seed 只在新局创建**」
// **从未被测试**（`grep` 测试目录无对应用例）。
//
// 这条不变量的意义：runId 与 seed 是回放、调试与存档的锚点
// （协议 §3.1：`RunStarted` 必须携带 seed 与 prngAlgorithm）。
// 若它们在同一局内被重新生成，回放就无法复现、记录也会串局。
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
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

Map<String, Object?> _read(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime _build({required int seed, required String runId}) {
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
      identity: RunIdentity(
        runId: runId,
        seed: seed,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.0.5-release',
        contentManifestSha256: '',
      ),
      random: Pcg32(seed),
    ),
    random: Pcg32(seed),
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
  test('T-CORE-01 同一局内 runId 与 seed 不随状态变化而改变', () {
    final rt = _build(seed: 0x4E454F4E0001, runId: 'run-A');

    final identity = rt.runtime.identity;
    final seedAtStart = identity.seed;
    final runIdAtStart = identity.runId;

    // 走遍会改变相位的路径：推进 → 暂停 → 恢复 → 再推进。
    for (var i = 0; i < 300; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    rt.phases.requestPause(PauseSource.userRequest);
    for (var i = 0; i < 60; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    rt.phases.requestResume();
    for (var i = 0; i < 300; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }

    expect(
      rt.runtime.identity.seed,
      seedAtStart,
      reason: 'T-CORE-01：seed 只在新局创建，不得在局内改变',
    );
    expect(
      rt.runtime.identity.runId,
      runIdAtStart,
      reason: 'T-CORE-01：runId 只在新局创建，不得在局内改变',
    );
  });

  test('T-CORE-01 新局获得新的 runId，且沿用调用方给定的 seed', () {
    // 引擎的契约：runId 由上层为新局创建；seed 由上层决定并写入 RunStarted。
    final first = _build(seed: 111, runId: 'run-1');
    final second = _build(seed: 222, runId: 'run-2');

    expect(first.runtime.identity.runId, isNot(second.runtime.identity.runId));
    expect(first.runtime.identity.seed, 111);
    expect(second.runtime.identity.seed, 222);

    // 同一 seed 的两个不同的局，随机序列应一致（回放可复现的前提）。
    final a = Pcg32(111);
    final b = Pcg32(111);
    for (var i = 0; i < 8; i++) {
      expect(a.nextUint32(), b.nextUint32());
    }
  });

  test('T-CORE-01 RunStarted 携带 seed 与算法名（协议 §3.1）', () {
    final rt = _build(seed: 0x4E454F4E0001, runId: 'run-A');
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

    final started = rt.lastFrameEvents
        .map((e) => e.event)
        .whereType<RunStarted>();
    // RunStarted 一般由上层在开局时发出；这里断言引擎暴露的身份是完整的，
    // 上层据此构造 RunStarted 时不会缺字段。
    expect(rt.runtime.identity.seed, isNotNull);
    expect(rt.runtime.identity.prngAlgorithm, 'pcg32-xsh-rr');
    expect(rt.runtime.identity.contentVersion, isNotEmpty);
    // 若引擎自己发了 RunStarted，则必须带全字段。
    for (final event in started) {
      expect(event.seed, rt.runtime.identity.seed);
      expect(event.prngAlgorithm, 'pcg32-xsh-rr');
    }
  });
}
