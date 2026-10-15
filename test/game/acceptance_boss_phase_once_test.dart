// ================================================================
// test/game/acceptance_boss_phase_once_test.dart —— AC-05 结束条件
// ================================================================
// 产品设计 §7.5 的「结束条件/验收」列里，Boss 转段写的是：
//   「**只执行一次**；玩家无敌不被打断」
//
// 核对发现这条**从未被测试**（`grep "只执行一次" test/` 为 0）。
// AC-05 要求「13 个状态均有正确视觉、音频**和结束条件**」——
// 此前只覆盖了前两项。
//
// 本文件验证「只执行一次」：把 Boss 打过 70% / 35% 两个阈值，
// 统计 `BossPhaseChanged` 事件，断言**每个相位最多出现一次**。
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
import 'package:warship_flutter/game/domain/boss_system.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/upgrade_system.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

Map<String, Object?> _read(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime _build() {
  final enemies = _read('enemies.json');
  final waves = _read('waves_normal.json');
  final upgrades = _read('upgrades.json');
  final guaranteed = upgrades['guaranteed'] as Map;
  return GameRuntime(
    catalogPlayer: _read('player.json'),
    enemyTunings: <String, EnemyTuning>{
      for (final raw in (enemies['enemies'] as List).cast<Map>())
        (raw['id'] as String):
            EnemyTuning.fromConfig(raw.cast<String, Object?>()),
    },
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'boss-phase',
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
    upgradeSystem: UpgradeSystem(
      cards: (upgrades['cards'] as List)
          .cast<Map>()
          .map((m) => UpgradeCard.fromConfig(m.cast<String, Object?>()))
          .toList(),
      xpThresholds: (upgrades['xpThresholds'] as List).cast<int>(),
      firstDraftEarliestSecond:
          (upgrades['firstDraftEarliestSecond'] as num).toDouble(),
      maxDrafts: upgrades['maxDrafts'] as int,
      draftSize: upgrades['draftSize'] as int,
      damageCardIds:
          (upgrades['damageCardIds'] as List).cast<String>().toSet(),
      guaranteedFirstDraft: (guaranteed['firstDraft'] as List).cast<String>(),
      guaranteedSecondDraftAnyOf:
          (guaranteed['secondDraftAnyOf'] as List).cast<String>(),
    ),
  );
}

void main() {
  test('Boss 转段只执行一次：每个相位最多一条 BossPhaseChanged', () {
    final rt = _build();
    final phaseEvents = <String>[];

    var frame = 0;
    // 150 秒 Boss 入场；打到 35% 以下需要一段时间。
    while (frame < 260 * 60 && !rt.victory) {
      rt.player.health.current = rt.player.health.max; // 保持存活

      final offer = rt.currentOffer;
      if (offer != null) {
        rt.selectDraftCard(0);
      }

      // 把 Boss 的血往下推，跨过 70% 与 35% 两个阈值 ——
      // 但要**逐帧小步**推进，否则会跳过中间的转段判定。
      final boss = rt.boss;
      if (boss != null && !boss.isDefeated) {
        // 每帧削掉一点点，制造多个会触发阈值判定的帧。
        boss.health.current = (boss.health.current - 1).clamp(
          1,
          boss.health.max,
        );
      }

      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

      for (final event in rt.lastFrameEvents) {
        if (event.event is BossPhaseChanged) {
          phaseEvents.add((event.event as BossPhaseChanged).phase);
        }
      }
      frame++;
    }

    expect(
      phaseEvents,
      isNotEmpty,
      reason: '应至少发生过一次转段，否则本用例没验证到东西',
    );

    // **核心不变量**：同一相位不得重复播报转段。
    final duplicates = <String>[];
    final seen = <String>{};
    for (final phase in phaseEvents) {
      if (!seen.add(phase)) {
        duplicates.add(phase);
      }
    }
    expect(
      duplicates,
      isEmpty,
      reason: '§7.5 要求转段"只执行一次"，但重复出现：$duplicates\n'
          '完整序列：$phaseEvents',
    );
  });
}
