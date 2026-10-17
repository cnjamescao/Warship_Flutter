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

/// 配置文件的**内容指纹**（批复要求报告里列出"实际配置 SHA"）。
///
/// 用长度 + 逐字节 FNV-1a 代替 SHA-256，避免为一处报告引入 `crypto` 依赖
/// （`crypto` 不在本包的直接依赖里，分析器会报 `depend_on_referenced_packages`）。
/// 它**不是**密码学哈希，只用于"同一份配置 → 同一指纹"的对账目的。
String _sha(String name) {
  final bytes = File('assets/config/v2/$name').readAsBytesSync();
  var h = 0x811C9DC5;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return '${bytes.length}-${h.toRadixString(16)}';
}

GameRuntime _build({int? seed}) {
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
      identity: RunIdentity(
        runId: 'idle',
        seed: seed ?? kSeed,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.1.0-neon-flow',
        contentManifestSha256: '',
      ),
      random: Pcg32(seed ?? kSeed),
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

  test('AC-06 站桩输入不能通关（固定 20 seed，0/20 victory）', () {
    // **FV21-05 批复（2026-10-17）**：
    //   「不允许站桩通关……固定 **20 个 seed**、零移动/零冲刺/零暂停输入
    //    推进至 **180 秒**，验收要求为 **`0/20 victory`**；
    //    最终报告必须列出每条结果和实际配置 SHA。」
    //
    // 本用例就是那份报告的执行体：**逐条打印结果**，而不是只给一个总数
    // （只给总数时，失败无法定位到具体 seed）。
    const seeds = <int>[
      0x2A01, 0x2A02, 0x2A03, 0x2A04, 0x2A05,
      0x2A06, 0x2A07, 0x2A08, 0x2A09, 0x2A0A,
      0x2AB1, 0x2AB2, 0x2AB3, 0x2AB4, 0x2AB5,
      0x2AB6, 0x2AB7, 0x2AB8, 0x2AB9, 0x2ABA,
    ];
    expect(seeds, hasLength(20), reason: '必须是固定 20 个 seed');

    final results = <String>[];
    var victories = 0;
    for (final seed in seeds) {
      final rt = _build(seed: seed);
      var frame = 0;
      // 推进到 180 游戏秒（批复的判定窗口）。
      while (rt.combatSeconds < 180 && frame < 180 * 60) {
        // **站桩**：零移动、零冲刺、零暂停。
        rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
        if (rt.victory || rt.player.health.isDead) {
          break;
        }
        frame++;
      }
      if (rt.victory) {
        victories++;
      }
      results.add(
        'seed=0x${seed.toRadixString(16).toUpperCase()} '
        't=${rt.combatSeconds.toStringAsFixed(1)}s '
        'hp=${rt.player.health.current} '
        '${rt.victory ? 'VICTORY' : (rt.player.health.isDead ? 'defeat' : 'survived')}',
      );
    }

    // 逐条结果 + 配置 SHA（批复要求）。
    final report = StringBuffer()
      ..writeln('== AC-06 站桩 20 seed 报告 ==')
      ..writeln('enemies.json  sha=${_sha('enemies.json')}')
      ..writeln('waves_normal.json sha=${_sha('waves_normal.json')}')
      ..writeln('player.json  sha=${_sha('player.json')}');
    for (final r in results) {
      report.writeln('  $r');
    }
    report.writeln('victory = $victories / ${seeds.length}');
    // ignore: avoid_print
    print(report.toString());

    expect(
      victories,
      0,
      reason: 'AC-06：站桩（零输入）**不得**通关。\n$report',
    );
  });
}
