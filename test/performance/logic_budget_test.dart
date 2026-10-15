// ================================================================
// test/performance/logic_budget_test.dart —— AC-07（逻辑侧）
// ================================================================
// 协议 §5 的性能验收要求「场景 seed、对象峰值、p50/p95/p99 帧时间、
// 降级是否发生」。
//
// ⚠️ **范围声明**：本测试测的是**逻辑步成本**，不是帧时间。
// 无头 Dart 测试无法测量 GPU 绘制 / 合成 / 垂直同步。
// 它回答的问题是："在对象接近上限的密集段，模拟本身是否吃得下
// 16.67 ms 的帧预算，给渲染留下余量？"
//
// AC-07 要求的**帧时间** p50/p95/p99 仍必须在 profile/release 构建的
// 真实设备上采样。这一点在报告与验收对照表里都写明了。
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
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';
import 'package:warship_flutter/game/infrastructure/performance_monitor.dart';
import 'package:warship_flutter/game/infrastructure/performance_report.dart';

const int kSeed = 0x4E454F4E0001;
const String kContentVersion = '2.0.6-material-repair';
const String kReportPath = 'test/fixtures/performance/logic_budget_v1.json';

/// 产品基线 §2：最密集段为 130–150 秒。
const double kDenseSegmentStart = 130;
const double kDenseSegmentEnd = 150;

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime buildRuntime() {
  final playerJson = readJson('player.json');
  final enemiesJson = readJson('enemies.json');
  final wavesJson = readJson('waves_normal.json');
  final upgradesJson = readJson('upgrades.json');

  final tunings = <String, EnemyTuning>{
    for (final raw in (enemiesJson['enemies'] as List).cast<Map>())
      (raw['id'] as String):
          EnemyTuning.fromConfig(raw.cast<String, Object?>()),
  };
  final windows = ((wavesJson['dynamicAdjustment'] as Map)
          ['minimumUpgradeCountBySecond'] as List)
      .cast<Map>()
      .map((m) => MinimumUpgradeWindow.fromConfig(m.cast<String, Object?>()))
      .toList();
  final rows = (wavesJson['waves'] as List)
      .cast<Map>()
      .map((m) => WaveRow.fromConfig(m.cast<String, Object?>()))
      .toList();
  final guaranteed = upgradesJson['guaranteed'] as Map;

  return GameRuntime(
    catalogPlayer: playerJson,
    enemyTunings: tunings,
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'perf',
        seed: kSeed,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: kContentVersion,
        contentManifestSha256: '',
      ),
      random: Pcg32(kSeed),
    ),
    random: Pcg32(kSeed),
    bus: EventBus(),
    clock: GameClock(),
    phases: PhaseController(initialPhase: GamePhase.playing),
    director: DirectorSystem(
      rows: rows,
      minimumUpgradeWindows: windows,
      eliteRules: const <String, int>{'hp': 6, 'xp': 3, 'score': 8},
    ),
    enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
    pulse: PulseWeapon(),
    bossSystem: BossSystem(),
    riskGateSystem: RiskGateSystem(
      overloadHpThreshold: 35,
      selectionWindowSeconds: 5.0,
      timeoutFallbackId: RiskOptionIds.supply,
      overloadRarePool: const <String>['UP-CRIT-ARC'],
    ),
    upgradeSystem: UpgradeSystem(
      cards: (upgradesJson['cards'] as List)
          .cast<Map>()
          .map((m) => UpgradeCard.fromConfig(m.cast<String, Object?>()))
          .toList(),
      xpThresholds: (upgradesJson['xpThresholds'] as List).cast<int>(),
      firstDraftEarliestSecond:
          (upgradesJson['firstDraftEarliestSecond'] as num).toDouble(),
      maxDrafts: upgradesJson['maxDrafts'] as int,
      draftSize: upgradesJson['draftSize'] as int,
      damageCardIds:
          (upgradesJson['damageCardIds'] as List).cast<String>().toSet(),
      guaranteedFirstDraft: (guaranteed['firstDraft'] as List).cast<String>(),
      guaranteedSecondDraftAnyOf:
          (guaranteed['secondDraftAnyOf'] as List).cast<String>(),
    ),
  );
}

/// 高频机动输入：制造密集的走位、冲刺与射击。
InputFrame inputFor(int frame) {
  const directions = <Vec2>[
    Vec2(-1, 0),
    Vec2(-1, -1),
    Vec2(0, -1),
    Vec2(1, -1),
    Vec2(1, 0),
    Vec2(1, 1),
    Vec2(0, 1),
    Vec2(-1, 1),
  ];
  return InputFrame(
    moveDirection: directions[(frame ~/ 15) % directions.length],
    dashRequested: frame % 90 == 0,
  );
}

void main() {
  test('AC-07（逻辑侧）密集段逻辑步成本报告', () {
    final rt = buildRuntime();
    final monitor = PerformanceMonitor();

    // 让玩家活到密集段：每步把血量拉满（这是**采样夹具**，
    // 目的是"在对象密集时测成本"，不是"验证数值平衡"）。
    final totalFrames = ((kDenseSegmentEnd + 2) * 60).round();
    final stepDurations = <double>[];

    var peakEnemies = 0;
    var peakEnemyProjectiles = 0;
    var peakPlayerProjectiles = 0;
    var peakHazards = 0;

    final watch = Stopwatch();
    for (var frame = 0; frame < totalFrames; frame++) {
      rt.player.health.current = rt.player.health.max;
      // 立即提交选择，避免相位卡住。
      final offer = rt.currentOffer;
      if (offer != null) {
        rt.selectDraftCard(0);
      }
      final gate = rt.riskGate;
      if (gate != null && !gate.isResolved) {
        rt.selectRiskOption(RiskOptionIds.supply);
      }

      watch
        ..reset()
        ..start();
      rt.advance(GameClock.fixedStepSeconds, inputFor(frame));
      watch.stop();

      // 只统计密集段的样本。
      final second = frame / 60;
      if (second >= kDenseSegmentStart) {
        stepDurations.add(watch.elapsedMicroseconds / 1000);
        monitor.recordFrame(watch.elapsedMicroseconds / 1e6);
      }

      if (second >= kDenseSegmentStart) {
        peakEnemies = peakEnemies > rt.enemies.length
            ? peakEnemies
            : rt.enemies.length;
        final enemyProjectiles = rt.projectiles
            .where((p) => p.faction == ProjectileFaction.enemy)
            .length;
        final playerProjectiles = rt.projectiles.length - enemyProjectiles;
        peakEnemyProjectiles = peakEnemyProjectiles > enemyProjectiles
            ? peakEnemyProjectiles
            : enemyProjectiles;
        peakPlayerProjectiles = peakPlayerProjectiles > playerProjectiles
            ? peakPlayerProjectiles
            : playerProjectiles;
        peakHazards = peakHazards > rt.hazards.length
            ? peakHazards
            : rt.hazards.length;
      }
    }

    expect(stepDurations, isNotEmpty, reason: '密集段应采集到样本');

    final report = buildReport(
      seed: kSeed,
      contentVersion: kContentVersion,
      scenarioSeconds: kDenseSegmentEnd - kDenseSegmentStart,
      stepDurationsMs: stepDurations,
      peakEnemies: peakEnemies,
      peakEnemyProjectiles: peakEnemyProjectiles,
      peakPlayerProjectiles: peakPlayerProjectiles,
      peakHazards: peakHazards,
      degradationLevel: monitor.level.name,
      note:
          '逻辑步成本报告（AC-07 的逻辑侧证据）。'
          '**不含帧时间** —— 无头测试无法测量 GPU 绘制与合成，'
          'AC-07 要求的帧时间仍须在 profile/release 构建的真机上采样。',
    );

    // 写出报告供验收记录引用。
    final file = File(kReportPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(report.encode());

    // 关键断言：**逻辑成本必须远低于帧预算**，给渲染留出余量。
    // 取 16.67 ms 的一半作为门槛 —— 逻辑与渲染大致是同一量级，
    // 逻辑吃掉一半以上预算就意味着真机上必然掉帧。
    expect(
      report.logicMeetsBudget,
      isTrue,
      reason: '${report.summaryLine()}\n逻辑步 p95 已超出帧预算',
    );
    expect(
      report.logicBudgetUsage,
      lessThan(0.5),
      reason: '${report.summaryLine()}\n逻辑应给渲染留出余量',
    );

    // 密集段的对象规模不应超过产品基线 §6 的上限。
    const budget = ObjectBudget();
    expect(report.peakEnemies, lessThanOrEqualTo(budget.enemies));
    expect(
      report.peakEnemyProjectiles,
      lessThanOrEqualTo(budget.enemyProjectiles),
    );
    expect(
      report.peakPlayerProjectiles,
      lessThanOrEqualTo(budget.playerProjectiles),
    );

    // 报告本身要能被解析回来（验收记录依赖它）。
    final reloaded =
        jsonDecode(File(kReportPath).readAsStringSync()) as Map<String, Object?>;
    expect(reloaded['seed'], kSeed);
    expect(reloaded['scope'], contains('logic-step cost only'));
    expect((reloaded['logicStepMs'] as Map)['p95'], isA<num>());
  });
}
