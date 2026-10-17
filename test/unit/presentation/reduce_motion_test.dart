// ================================================================
// test/unit/presentation/reduce_motion_test.dart
// ================================================================
// 产品设计 §8 第 280 行要求「提供降低动效、屏幕震动开关…」。
//
// **背景（真实缺口）**：`settings.reduceMotion` 此前只在设置页被读写，
// **渲染路径里一次都没被消费** —— 开关存了但完全没作用。
// 本轮把它接成"降级地板"，并用本文件守住它确实生效。
//
// 注意：用单元断言而不是 Golden —— 实测
// `matchesGoldenFile(find.byType(MaterialApp))` **抓不到 Flame 渲染的
// 战场层**（两张基线 MD5 完全相同），降级影响的画面不在基线里。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_bootstrap.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/core/game_clock.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';
import 'package:warship_flutter/game/infrastructure/performance_monitor.dart';
import 'package:warship_flutter/game/presentation/asset_cache.dart';
import 'package:warship_flutter/game/presentation/input_gateway.dart';
import 'package:warship_flutter/game/presentation/warship_v2_game.dart';

Map<String, Object?> _read(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AssetManifest manifest;

  setUpAll(() {
    manifest = AssetManifest.parse(
      jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
          as Map<String, Object?>,
      expectedVersion: kActiveContentVersion,
    ).requireValue;
  });

  GameRuntime buildRuntime() {
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
          runId: 'rm',
          seed: 1,
          prngAlgorithm: 'pcg32-xsh-rr',
          contentVersion: '2.1.0-neon-flow',
          contentManifestSha256: '',
        ),
        random: Pcg32(1),
      ),
      random: Pcg32(1),
      bus: EventBus(),
      clock: GameClock(),
      phases: PhaseController(initialPhase: GamePhase.playing),
      director: DirectorSystem(
        rows: (waves['waves'] as List)
            .cast<Map>()
            .map((m) => WaveRow.fromConfig(m.cast<String, Object?>()))
            .toList(),
        minimumUpgradeWindows: ((waves['dynamicAdjustment'] as Map)
                ['minimumUpgradeCountBySecond'] as List)
            .cast<Map>()
            .map((m) => MinimumUpgradeWindow.fromConfig(m.cast<String, Object?>()))
            .toList(),
        eliteRules: const <String, int>{},
      ),
      enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
      pulse: PulseWeapon(),
    );
  }

  WarshipV2Game buildGame({required bool reduceMotion}) => WarshipV2Game(
    runtime: buildRuntime(),
    input: KeyboardInputGateway(),
    visualAssets: VisualAssetCache(manifest: manifest),
    preloadAssets: false,
    reduceMotion: reduceMotion,
  );

  test('默认（未开启降低动效）时档位跟随性能监视器', () {
    final game = buildGame(reduceMotion: false);
    expect(game.effectiveDegradation, DegradationLevel.none);
  });

  test('开启降低动效后档位被抬到地板（非关键表现关闭）', () {
    final game = buildGame(reduceMotion: true);
    expect(
      game.effectiveDegradation,
      DegradationLevel.hitDebris,
      reason: '星云 / 非关键粒子 / 命中碎片都应关闭',
    );
    expect(
      game.effectiveDegradation.allows(DegradationLevel.damageNumbers),
      isTrue,
      reason: '伤害数字属于战斗信息，保留（"只降低非关键动效"）',
    );
  });

  test('性能降级更狠时以更严格的那个为准', () {
    final game = buildGame(reduceMotion: true);
    // 把监视器压到最低档，应覆盖降低动效的地板。
    for (var i = 0; i < 600; i++) {
      game.performance.recordFrame(0.2);
    }
    expect(
      game.effectiveDegradation.index,
      greaterThanOrEqualTo(DegradationLevel.hitDebris.index),
    );
    expect(game.effectiveDegradation, DegradationLevel.damageNumbers);
  });

  test('运行中切换开关能生效（设置是异步加载的）', () {
    final game = buildGame(reduceMotion: false);
    expect(game.effectiveDegradation, DegradationLevel.none);
    // 模拟设置加载完成后同步过来。
    game.reduceMotion = true;
    expect(game.effectiveDegradation, DegradationLevel.hitDebris);
  });
}
