// ================================================================
// test/unit/presentation/sniper_line_clip_test.dart —— F-36 第 5 步
// ================================================================
// 协议 §3.2：「`sniper_line` 的 origin/aimTarget **均在 t=0 锁定**，
// 线形预警沿该射线**裁切到逻辑世界边界**。」
//
// 两部分：
//   1. `clipRayToWorldLength` 的裁切正确性（纯函数，可直接测）；
//   2. t=0 锁定：预警期间敌机移动，`TelegraphView` 的几何**不得**跟着变。
// ================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/core/game_clock.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/boss_system.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';
import 'package:warship_flutter/game/presentation/warship_v2_game.dart';

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
    eliteAffixes: <String, EliteAffix>{
      for (final raw in (enemies['affixes'] as List? ?? const []).cast<Map>())
        (raw['id'] as String):
            EliteAffix.fromConfig(raw.cast<String, Object?>()),
    },
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'sniper-clip',
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
    bossSystem: BossSystem(),
  );
}

void main() {
  group('clipRayToWorldLength（裁切到逻辑世界边界）', () {
    test('指向世界内目标：长度即到目标的距离', () {
      final len = clipRayToWorldLength(Vec2(100, 100), Vec2(200, 100));
      expect(len, closeTo(100, 1e-6));
    });

    test('向右上射出：裁到右边界或上边界（取先到者）', () {
      // 从 (100,100) 沿 45° 向右上 —— 到上边界距离 100，
      // 到右边界距离 1820 ⇒ 应先到上边界。
      final len = clipRayToWorldLength(Vec2(100, 100), Vec2(200, 0));
      // 方向 (1,-1)/√2 ⇒ 到 y=0 的 t = 100 / (1/√2) = 141.42
      expect(len, closeTo(100 * math.sqrt2, 1e-3));
    });

    test('起点在世界外：返回 0（不绘制）', () {
      expect(clipRayToWorldLength(Vec2(-50, 100), Vec2(100, 100)), 0);
      expect(clipRayToWorldLength(Vec2(100, -50), Vec2(100, 100)), 0);
      expect(
        clipRayToWorldLength(Vec2(3000, 100), Vec2(100, 100)),
        0,
      );
    });

    test('零长度射线：返回 0', () {
      expect(clipRayToWorldLength(Vec2(100, 100), Vec2(100, 100)), 0);
    });

    test('裁切结果必然落在世界矩形内', () {
      final origin = Vec2(960, 540);
      for (var deg = 0; deg < 360; deg += 7) {
        final rad = deg * math.pi / 180;
        final target = Vec2(
          origin.x + math.cos(rad) * 5000,
          origin.y + math.sin(rad) * 5000,
        );
        final len = clipRayToWorldLength(origin, target);
        expect(len, greaterThan(0), reason: '从中心应总能射出世界');
        final endX = origin.x + math.cos(rad) * len;
        final endY = origin.y + math.sin(rad) * len;
        expect(endX, greaterThanOrEqualTo(-1e-6));
        expect(endX, lessThanOrEqualTo(1920 + 1e-6));
        expect(endY, greaterThanOrEqualTo(-1e-6));
        expect(endY, lessThanOrEqualTo(1080 + 1e-6));
      }
    });
  });

  test('sniper_line 的 origin/aimTarget 在 t=0 锁定，预警期间不随敌机移动', () {
    final rt = _build();
    const step = GameClock.fixedStepSeconds;

    // 场上可能同时有**多个**狙击手，因此按 origin 分组：
    // 若几何在 t=0 锁定，则同一个 origin 必然始终对应同一个 aimTarget。
    final aimByOrigin = <String, String>{};
    var samples = 0;
    var displaced = false;

    for (var i = 0; i < 200 * 60; i++) {
      rt.advance(step, InputFrame.idle);
      for (final t in rt.snapshot().telegraphs) {
        if (t.attackId != 'sniper_line') {
          continue;
        }
        samples++;
        final key = '${t.origin.x.toStringAsFixed(3)},'
            '${t.origin.y.toStringAsFixed(3)}';
        final aim = '${t.aimTarget.x.toStringAsFixed(3)},'
            '${t.aimTarget.y.toStringAsFixed(3)}';
        final previous = aimByOrigin[key];
        if (previous == null) {
          aimByOrigin[key] = aim;
          // 同一帧内把源敌机**强行挪走** —— 若几何未锁定，
          // 之后同一 origin 对应的 aimTarget 会改变。
          if (!displaced) {
            displaced = true;
            for (final e in rt.enemies) {
              e.position = Vec2(e.position.x + 400, e.position.y + 300);
            }
          }
        } else {
          expect(
            aim,
            previous,
            reason: 'origin=$key 的 aimTarget 发生了变化（$previous → $aim）—— '
                '说明预警几何未在 t=0 锁定（协议 §3.2）',
          );
        }
      }
    }

    expect(displaced, isTrue, reason: '应至少位移过一次源敌机');
    expect(samples, greaterThan(1), reason: '应采样到多帧 sniper_line 预警');
  });
}
