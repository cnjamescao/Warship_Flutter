// ================================================================
// test/game/acceptance_idle_input_test.dart —— AC-06 的第三条
// ================================================================
// 产品基线 §9 AC-06：
//   「用无伤基准输入可在 180 秒前击败 Boss；新手基准输入能稳定达到
//     60 秒；**站桩输入不能通关**」
//
// 前两条需要"会走位/不会走位"的真人基准输入（研发无法凭空造出，
// 见 docs/研发反馈意见.md 的 F-08）。但**第三条是可以自动化的**：
// 「站桩」= 完全不输入，这是精确定义的。
//   若不移动也能通关，那说明走位不重要 —— 那是设计问题。
//
// 本文件只覆盖第三条，并明确不冒充前两条。
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
import 'package:warship_flutter/game/domain/boss_system.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/risk_gate_system.dart';
import 'package:warship_flutter/game/domain/upgrade_system.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

const int kSeed = 0x4E454F4E0001;

Map<String, Object?> _read(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime _build() {
  final enemies = _read('enemies.json');
  final waves = _read('waves_normal.json');
  final upgrades = _read('upgrades.json');
  final risk = _read('risk_gates.json');
  final guaranteed = upgrades['guaranteed'] as Map;
  final common = risk['common'] as Map;
  final overload = (risk['options'] as List)
      .cast<Map>()
      .firstWhere((o) => o['id'] == 'RG-OVERLOAD');

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
        runId: 'idle',
        seed: kSeed,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.0.6-material-repair',
        contentManifestSha256: '',
      ),
      random: Pcg32(kSeed),
    ),
    random: Pcg32(kSeed),
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
      eliteRules: const <String, int>{'hp': 6, 'xp': 3, 'score': 8},
    ),
    enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
    pulse: PulseWeapon(),
    bossSystem: BossSystem(),
    riskGateSystem: RiskGateSystem(
      overloadHpThreshold:
          ((overload['availableCondition'] as Map?)?['hpAbove'] as num?)
                  ?.toInt() ??
              35,
      selectionWindowSeconds:
          (common['selectionWindowSeconds'] as num).toDouble(),
      timeoutFallbackId: common['timeoutFallbackId'] as String,
      overloadRarePool:
          (((overload['effect'] as Map?)?['pool'] as List?) ?? const [])
              .whereType<String>()
              .toList(),
    ),
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AC-06 站桩输入不能通关（180 秒内不会胜利）', () {
    final rt = _build();
    var frame = 0;
    var sawBoss = false;

    // 上限 300 游戏秒：足够越过 Boss 入场（150 秒）与整场时长。
    while (rt.combatSeconds < 300 && frame < 400 * 60) {
      // **站桩**：完全不输入（不移动、不冲刺）。武器自动开火是设计的一部分。
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);

      // 草案/风险门会冻结逻辑；为了让"站桩"能真正推进到 Boss，
      // 这里替玩家做掉选择（选择本身不是"走位"）。
      final offer = rt.currentOffer;
      if (offer != null) {
        rt.selectDraftCard(0);
      }
      final gate = rt.riskGate;
      if (gate != null && !gate.isResolved) {
        rt.selectRiskOption(RiskOptionIds.supply);
      }

      if (rt.boss != null) {
        sawBoss = true;
      }
      if (rt.victory) {
        break;
      }
      frame++;
    }

    expect(
      rt.victory,
      isFalse,
      reason: '站桩（零移动输入）不应通关 —— 若能通关说明走位不影响胜负',
    );
    // 顺带记录：站桩也会死，但如果连 Boss 都没见到，
    // 说明"不能通关"是弱者意义上的成立。这里断言的是更强的一条。
    expect(
      sawBoss,
      isTrue,
      reason: '应至少撑到 Boss 入场，否则"不能通关"缺乏说服力',
    );
  });
}
