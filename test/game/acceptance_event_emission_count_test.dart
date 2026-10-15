// ================================================================
// test/game/acceptance_event_emission_count_test.dart —— T-EVENT-01（P0）
// ================================================================
// 技术协议 §4 的 P0 清单 T-EVENT-01：
//   「触发开局、动态波次、突破、战前补给、冲刺开始/结束、**HP/护盾阈值跨越**、
//     五种敌方攻击和五种 Boss 招式 |
//     所有事件均具规定字段、正确 frame/eventIndex，且**只发出应有次数**；…
//     持续武器与 Boss 激光必有成对开始/结束事件」
//
// 核对发现：「成对开始/结束事件」已覆盖（acceptance_visual_states_test），
// 但「**只发出应有次数**」这一半——具体到 **HP/护盾阈值跨越** ——
// `PlayerVitalStateChanged` **从未被按"次数"测过**。
//
// 风险很具体：若阈值事件**每帧都发**（而不是只在跨越时发一次），
// 视觉与音频会被每帧重复触发，回放日志也会被淹没。
// 这类缺陷**只断言"事件存在"是发现不了的**。
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
        runId: 'event-count',
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
  test('T-EVENT-01 静止一段时间内，不应每帧重复发出阈值事件', () {
    final rt = _build();
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

    // **静止 3 秒**（180 帧），期间状态完全不变。
    // 若阈值事件是"按帧发"而不是"按跨越发"，这里会收到上百条。
    var vitalEvents = 0;
    for (var i = 0; i < 180; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      for (final stamped in rt.lastFrameEvents) {
        if (stamped.event is PlayerVitalStateChanged) vitalEvents++;
      }
    }

    // 允许少量（真要发生掉血则确实该发），但**绝不能接近帧数**。
    expect(
      vitalEvents,
      lessThan(20),
      reason: '3 秒（180 帧）内发出 $vitalEvents 条 PlayerVitalStateChanged —— '
          '像是按帧重复发出，而不是按阈值跨越发出',
    );
  });

  test('T-EVENT-01 单次跨越 HP 阈值只产生有限条阈值事件', () {
    final rt = _build();

    // 削 HP 跨过 30% 的濒危阈值。
    rt.player.health.current = (rt.player.health.max * 0.2).ceil();

    var events = 0;
    for (var i = 0; i < 60; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      for (final stamped in rt.lastFrameEvents) {
        if (stamped.event is PlayerVitalStateChanged) events++;
      }
    }

    expect(
      events,
      lessThan(20),
      reason: '跨越 HP 阈值后 1 秒内发出 $events 条 —— 阈值事件不应每帧重复',
    );
  });

  test('T-EVENT-01 事件都带正确的 frame/eventIndex 且 eventIndex 递增', () {
    final rt = _build();
    final indices = <int>[];
    final runIds = <String>{};

    for (var i = 0; i < 300; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      for (final stamped in rt.lastFrameEvents) {
        indices.add(stamped.eventIndex);
        runIds.add(stamped.runId);
        // frameIndex 必须是已推进过的帧号，不能是负数。
        expect(stamped.frameIndex, greaterThanOrEqualTo(0));
      }
    }

    expect(indices, isNotEmpty, reason: '应产生过事件');

    // eventIndex 在整局内严格递增（不分帧重置）。
    for (var i = 1; i < indices.length; i++) {
      expect(
        indices[i],
        greaterThan(indices[i - 1]),
        reason: 'eventIndex 必须严格递增：${indices[i - 1]} → ${indices[i]}',
      );
    }

    expect(
      runIds,
      hasLength(1),
      reason: '同一局内所有事件的 runId 必须一致（T-CORE-01 的 runId 稳定性）',
    );
  });
}
