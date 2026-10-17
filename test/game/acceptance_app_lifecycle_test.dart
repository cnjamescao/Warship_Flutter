// ================================================================
// test/game/acceptance_app_lifecycle_test.dart —— AC-08 隐藏页面自动暂停
// ================================================================
// 产品基线 §9 AC-08 第三条：「**隐藏页面自动暂停**」。
//
// ### 本文件验证到什么程度（如实说明）
//
// 分两段链路：
//   (A) 浏览器 `visibilitychange(hidden)` → Flutter `AppLifecycleState.hidden`
//       → `V2RunScreen.didChangeAppLifecycleState` → `_clearInputAndPause`
//   (B) `requestPause(PauseSource.appLifecycle)` → 暂停并冻结全部逻辑时钟
//
// **本文件只覆盖 (B)。** (A) 段我**没能在 widget 测试里模拟**：
// `tester.binding.handleAppLifecycleStateChanged(hidden)` 之后，
// 观察者的 `didChangeAppLifecycleState` 没有收到回调
// （已按合法顺序 resumed → inactive → hidden 试过），
// 因此该段**仍属未验证**。
//
// 不声称 (A) 有问题，也不声称它没问题 —— 只记录"没验证到"。
//
// 实现侧我核对过：(A) 的观察者确实注册了
// （`WidgetsBinding.instance.addObserver(this)`），处理函数的分支
// 覆盖 inactive/paused/hidden/detached，`requestPause` 也确实接受
// `PauseSource.appLifecycle`。所以 (A) 看起来是通的，但**没有测试证据**。
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
        runId: 'lifecycle',
        seed: 0x4E454F4E0001,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.1.0-neon-flow',
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
  test('AC-08 以「应用生命周期」来源暂停：相位变为 paused，且逻辑完全冻结', () {
    final rt = _build();

    // 先跑一小段，让场上有实体、计时器在走。
    for (var i = 0; i < 120; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    final positionsBefore = <String>[
      for (final e in rt.enemies) '${e.id}:${e.position.x},${e.position.y}',
    ];
    final stepsBefore = rt.logicSteps;

    // 模拟 `_clearInputAndPause()` 提交的那条命令。
    final event = rt.phases.requestPause(PauseSource.appLifecycle);
    expect(event, isNotNull, reason: 'playing 相位下应能暂停');
    expect(rt.phases.phase, GamePhase.paused);

    // 暂停期间推进：逻辑时钟必须完全冻结（技术架构 §3.1）。
    for (var i = 0; i < 300; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }

    expect(rt.logicSteps, stepsBefore, reason: '暂停期间逻辑步数不应增加');
    expect(
      <String>[
        for (final e in rt.enemies) '${e.id}:${e.position.x},${e.position.y}',
      ],
      positionsBefore,
      reason: '暂停期间实体坐标不应变化',
    );
  });

  test('AC-08 恢复需要显式调用（「恢复不自动继续」）', () {
    final rt = _build();
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

    rt.phases.requestPause(PauseSource.appLifecycle);
    final stepsPaused = rt.logicSteps;

    // 只"回到前台"但不显式恢复 —— 逻辑应仍然冻结。
    for (var i = 0; i < 120; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    expect(rt.logicSteps, stepsPaused, reason: '未显式恢复时逻辑不应继续');

    rt.phases.requestResume();
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    expect(rt.logicSteps, greaterThan(stepsPaused), reason: '显式恢复后逻辑应继续');
  });

  test('AC-08 重复暂停是幂等的（切标签页可能连发多次事件）', () {
    final rt = _build();
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

    expect(rt.phases.requestPause(PauseSource.appLifecycle), isNotNull);
    expect(
      rt.phases.requestPause(PauseSource.appLifecycle),
      isNull,
      reason: '已暂停时再次请求应返回 null（幂等，不重复发事件）',
    );
    expect(rt.phases.phase, GamePhase.paused);
  });
}
