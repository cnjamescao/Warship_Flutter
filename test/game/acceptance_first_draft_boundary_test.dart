// ================================================================
// test/game/acceptance_first_draft_boundary_test.dart —— T-UP-00（P0）
// ================================================================
// 技术协议 §4 的 P0 清单 T-UP-00：
//   「经验在 15.0 秒前达到 20；分别推进至 **14.99 / 15.00 秒** |
//     **14.99 秒不打开草案；15.00 秒只打开一次**第 1 次草案
//     并**保留既有经验**」
//
// 核对发现已有的用例**把边界测松了**：
//   * 它在约 1.0 秒处断言"不打开"—— 距 15.00 秒很远，
//     压不到边界；14.99 与 15.00 之间差一帧的 off-by-one 测不出来；
//   * "15 秒后应打开"用的是 `greaterThanOrEqualTo(1)` ——
//     **不验证"只打开一次"**，开两次也会通过；
//   * **完全没有验证"保留既有经验"**。
//
// 本文件按原文逐条压边界：1499 帧（14.983 秒）不得打开，
// 第 1500 帧（恰好 15.00 秒）打开，且只打开一次、经验不清零。
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
        runId: 'draft-boundary',
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
  // 60 fps × 15 s = 900 帧。899 帧 = 14.983 秒，第 900 帧 = 恰好 15.00 秒。
  // （我第一版误写成 1500 帧，测试自己的算术错了 —— 实现在 15.000 秒
  //   打开，行为其实是对的。）
  test('T-UP-00 第 899 帧（14.983 秒）不得打开草案', () {
    final rt = _build();
    rt.xp = 20; // 已达阈值

    for (var i = 0; i < 899; i++) {
      rt.player.health.current = rt.player.health.max;
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      if (rt.phases.phase == GamePhase.upgradeDraft) break;
    }

    expect(
      rt.phases.phase,
      GamePhase.playing,
      reason: 'T-UP-00：第 1 次草案不得早于 15.0 秒；'
          '当前 ${rt.combatSeconds.toStringAsFixed(3)} 秒就打开了',
    );
    expect(rt.upgradeState.draftCount, 0, reason: '不应已产生草案');
  });

  test('T-UP-00 第 900 帧（恰好 15.00 秒）打开草案，且只打开一次', () {
    final rt = _build();
    rt.xp = 20;

    // 推进到刚好 15.00 秒（900 帧）。
    for (var i = 0; i < 900; i++) {
      rt.player.health.current = rt.player.health.max;
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      if (rt.phases.phase == GamePhase.upgradeDraft) break;
    }

    expect(
      rt.phases.phase,
      GamePhase.upgradeDraft,
      reason: 'T-UP-00：15.00 秒应打开第 1 次草案'
          '（当前 ${rt.combatSeconds.toStringAsFixed(3)} 秒）',
    );
    expect(rt.currentOffer, isNotNull, reason: '应给出候选卡');

    // **"只打开一次"**：草案期内继续推进，不得再开一个。
    final offerBefore = rt.currentOffer;
    for (var i = 0; i < 120; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    expect(
      identical(rt.currentOffer, offerBefore),
      isTrue,
      reason: 'T-UP-00：应"只打开一次" —— 草案期内不得重复打开',
    );
    expect(
      rt.upgradeState.draftCount,
      1,
      reason: 'T-UP-00：应"只打开一次"第 1 次草案',
    );
  });

  test('T-UP-00 打开草案时保留既有经验（不清零）', () {
    final rt = _build();
    // 给一个明显高于阈值的经验值，便于判断是否被清零。
    const xpGiven = 20;
    rt.xp = xpGiven;

    for (var i = 0; i < 900; i++) {
      rt.player.health.current = rt.player.health.max;
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      if (rt.phases.phase == GamePhase.upgradeDraft) break;
    }
    expect(rt.phases.phase, GamePhase.upgradeDraft);

    final threshold =
        ((_read('upgrades.json')['xpThresholds'] as List).first as num).toInt();

    // 协议原文是「**保留既有经验**」—— 核心是不能把 xp 粗暴清零。
    //
    // 注意：15 秒内玩家在自动开火击杀敌人，xp 会自然增长
    // （实测 20 → 56），所以**不能**断言"经验不应增加" ——
    // 我第一版加了这条，是我自己臆造的约束，与游戏机制矛盾。
    expect(rt.xp, greaterThan(0), reason: 'T-UP-00 要求"保留既有经验"，不应被清零');
    expect(
      rt.xp,
      greaterThanOrEqualTo(threshold),
      reason: '开草案时经验不应低于阈值（题目要求保留既有经验）',
    );
  });
}
