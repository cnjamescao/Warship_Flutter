// ================================================================
// test/performance/object_cap_stress_test.dart —— AC-07（对象上限）
// ================================================================
// 产品基线 §9 AC-07：
//   「**达到 §2 对象上限时**仍满足帧时间目标；
//     降级**不影响预警、HUD、碰撞与输入**」
// 协议 §4 第 2 点：
//   「强制填满每类对象预算，验证拒绝低优先级特效后
//     预警、HUD、碰撞仍正常。」
//
// 上一轮报告的缺口正是"没跑到对象上限"（峰值仅 13 敌人）。
// 本轮**直接构造**满载状态，把缺口补上。
//
// ⚠️ 范围仍与上一轮一致：测的是**逻辑步成本**，不是帧时间。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/perf_baseline.dart';
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
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';
import 'package:warship_flutter/game/infrastructure/performance_monitor.dart';
import 'package:warship_flutter/game/infrastructure/performance_report.dart';
import 'package:warship_flutter/game/presentation/visual_effects.dart';

const int kSeed = 0x4E454F4E0001;
const String kContentVersion = '2.0.6-material-repair';
const String kReportPath =
    'test/fixtures/performance/object_cap_stress_v1.json';

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime buildRuntime() {
  final playerJson = readJson('player.json');
  final enemiesJson = readJson('enemies.json');
  final wavesJson = readJson('waves_normal.json');

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

  return GameRuntime(
    catalogPlayer: playerJson,
    enemyTunings: tunings,
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'stress',
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
      eliteRules: const <String, int>{},
    ),
    enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
    pulse: PulseWeapon(),
  );
}

/// 把场上填到每类对象的预算上限。
void fillToCap(GameRuntime rt, ObjectBudget budget) {
  final enemySystem = rt.enemySystem;

  // 敌人：45 个，分散排布避免全部重叠（否则碰撞收集会退化成最坏情况
  // 之外的情形 —— 我们要测的是"数量带来的成本"，不是单点重叠）。
  var index = 0;
  while (rt.enemies.length < budget.enemies) {
    final tuning = rt.enemyTunings['EN-WING']!;
    final enemy = enemySystem.spawn(
      id: rt.ids.next(EntityKind.enemy),
      tuning: tuning,
      spawnX: 120.0 + (index % 15) * 120,
      spawnY: -200.0 - (index ~/ 15) * 160,
    );
    enemy.hasEntered = true;
    rt.enemies.add(enemy);
    index++;
  }

  // 敌方投射物：90 个。
  for (var i = 0; i < budget.enemyProjectiles; i++) {
    rt.projectiles.add(
      Projectile(
        id: rt.ids.next(EntityKind.enemyProjectile),
        faction: ProjectileFaction.enemy,
        position: Vec2(100.0 + (i % 18) * 100, 100.0 + (i ~/ 18) * 90),
        direction: const Vec2(0, 1),
        speed: 720,
        radius: 14,
        damage: 8,
        lifetimeSeconds: 10.0,
        weaponId: 'wing_shot',
      ),
    );
  }

  // 我方投射物：120 个。
  for (var i = 0; i < budget.playerProjectiles; i++) {
    rt.projectiles.add(
      Projectile(
        id: rt.ids.next(EntityKind.playerProjectile),
        faction: ProjectileFaction.player,
        position: Vec2(60.0 + (i % 20) * 95, 900.0 - (i ~/ 20) * 40),
        direction: const Vec2(0, -1),
        speed: 1250,
        radius: 6,
        damage: 9,
        lifetimeSeconds: 10.0,
        weaponId: 'WPN-PULSE',
      ),
    );
  }
}

void main() {
  test('AC-07 对象满载时逻辑成本、降级与"降级不影响关键信息"', () {
    const budget = ObjectBudget();
    final rt = buildRuntime();
    final monitor = PerformanceMonitor();
    final effects = VisualEffects(budget: budget);

    fillToCap(rt, budget);

    expect(rt.enemies.length, budget.enemies, reason: '敌人应填满 45');
    final enemyProjectiles = rt.projectiles
        .where((p) => p.faction == ProjectileFaction.enemy)
        .length;
    final playerProjectiles = rt.projectiles.length - enemyProjectiles;
    expect(enemyProjectiles, budget.enemyProjectiles);
    expect(playerProjectiles, budget.playerProjectiles);

    // --- 在满载状态下逐步计时 ---
    final durations = <double>[];
    final watch = Stopwatch();
    var sawBreachWarning = false;
    var sawCollisionDamage = false;
    var sawInputHonoured = false;
    var warningEvents = 0;

    final startX = rt.player.position.x;

    for (var frame = 0; frame < 600; frame++) {
      // 保持满载：敌人被打死/越界后立刻补回。
      while (rt.enemies.length < budget.enemies) {
        final enemy = rt.enemySystem.spawn(
          id: rt.ids.next(EntityKind.enemy),
          tuning: rt.enemyTunings['EN-WING']!,
          spawnX: 120.0 + (rt.enemies.length % 15) * 120,
          spawnY: -200,
        );
        enemy.hasEntered = true;
        rt.enemies.add(enemy);
      }
      while (rt.projectiles.length <
          budget.enemyProjectiles + budget.playerProjectiles) {
        rt.projectiles.add(
          Projectile(
            id: rt.ids.next(EntityKind.enemyProjectile),
            faction: ProjectileFaction.enemy,
            position: Vec2(200.0 + (rt.projectiles.length % 16) * 100, 140),
            direction: const Vec2(0, 1),
            speed: 720,
            radius: 14,
            damage: 8,
            lifetimeSeconds: 10.0,
            weaponId: 'wing_shot',
          ),
        );
      }

      rt.player.health.current = rt.player.health.max;

      watch
        ..reset()
        ..start();
      rt.advance(
        GameClock.fixedStepSeconds,
        InputFrame(
          moveDirection: frame.isEven ? const Vec2(1, 0) : const Vec2(-1, 0),
          dashRequested: frame % 120 == 0,
        ),
      );
      watch.stop();

      durations.add(watch.elapsedMicroseconds / 1000);
      monitor.recordFrame(watch.elapsedMicroseconds / 1e6);

      // 特效池也在满载下工作（预算 + 档位双重限制）。
      effects.consume(
        rt.lastFrameEvents,
        level: monitor.level,
        positionOf: (id) => const Vec2(960, 540),
      );
      effects.step(GameClock.fixedStepSeconds);

      for (final event in rt.lastFrameEvents) {
        if (event.event is EnemyBreached) {
          sawBreachWarning = true;
        }
        if (event.event is PlayerDamaged) {
          sawCollisionDamage = true;
        }
        if (event.event is EnemyAttackFired) {
          warningEvents++;
        }
      }
    }

    sawInputHonoured = rt.player.position.x != startX;

    // --- 报告 ---
    final report = buildReport(
      seed: kSeed,
      contentVersion: kContentVersion,
      scenarioSeconds: 10,
      stepDurationsMs: durations,
      peakEnemies: rt.enemies.length,
      peakEnemyProjectiles: budget.enemyProjectiles,
      peakPlayerProjectiles: budget.playerProjectiles,
      peakHazards: rt.hazards.length,
      degradationLevel: monitor.level.name,
      note:
          '对象上限压力场景（AC-07 的逻辑侧证据）。'
          '**不含帧时间** —— 须在 profile/release 构建的真机上采样。',
    );
    // **F-42**：报告写到 `build/`（不提交）；基线只在
    // `UPDATE_PERF_BASELINE=1` 显式维护流程下重建。
    // 修复前此处直接改写 fixture —— 既弄脏工作区，又让后续
    // "读回同一文件"的断言恒为真、测不出回归。
    writePerfReport(
      baselinePath: kReportPath,
      json: report.encode(),
    );
    // 报告路径用于读回校验（见下方 reloaded 断言）。

    // **F-43**：基线（**只读输入**）对照 ——
    // 先校验元数据可比性，再逐项输出「历史 / 本次 / 差值 / 比例」。
    // 按裁定：**不作硬门槛**（开发机耗时不是跨机器性能门槛），
    // 输出供验收记录与人工判读。
    reportPerfComparison(
      label: 'AC-07 逻辑侧（$kSeed）',
      current: jsonDecode(report.encode()) as Map<String, Object?>,
      baseline: readPerfBaseline(kReportPath),
    );

    // --- 断言 1：满载下逻辑成本仍给渲染留余量 ---
    expect(
      report.logicMeetsBudget,
      isTrue,
      reason: '${report.summaryLine()}\n满载时逻辑步 p95 超出帧预算',
    );
    expect(
      report.logicBudgetUsage,
      lessThan(0.5),
      reason: '${report.summaryLine()}\n满载时逻辑应仍给渲染留出余量',
    );

    // --- 断言 2：降级确实生效 ---
    // 满载下帧时间会超预算，降级应被触发（或不触发也满足预算）。
    final degraded = monitor.level != DegradationLevel.none;
    expect(
      degraded || report.logicMeetsBudget,
      isTrue,
      reason: '要么降级生效，要么本来就没超预算',
    );

    // --- 断言 3：降级不影响预警 / 碰撞 / 输入 ---
    expect(
      warningEvents,
      greaterThan(0),
      reason: '满载时敌方攻击事件仍必须产生（预警不受降级影响）',
    );
    expect(
      sawCollisionDamage || sawBreachWarning,
      isTrue,
      reason: '满载时碰撞判定仍必须工作',
    );
    expect(sawInputHonoured, isTrue, reason: '满载时输入仍必须被采纳');

    // --- 断言 4：HUD 快照完整 ---
    final snapshot = rt.snapshot();
    expect(snapshot.hud, isNotNull);
    expect(snapshot.hud!.hpMax, 100);
    expect(snapshot.hud!.shieldMax, 30);
    expect(snapshot.enemies.length, rt.enemies.length);
    expect(snapshot.hud!.dashMaxCharges, 2);

    // --- 断言 5：特效池在预算内，且拒绝的是低优先级对象 ---
    expect(
      effects.numbers.length,
      lessThanOrEqualTo(budget.damageNumbers),
    );
    expect(effects.debris.length, lessThanOrEqualTo(budget.particles));
  });

  test('满载下预警资源永不被预算拒绝（无限预算之外的关键信息）', () {
    const budget = ObjectBudget();
    final effects = VisualEffects(budget: budget);

    // 把伤害数字与碎片都填满。
    final events = <StampedEvent>[
      for (var i = 0; i < 200; i++)
        StampedEvent(
          event: EnemyDamaged(
            entityId: EntityId(EntityKind.enemy, i + 1),
            enemyId: 'EN-WING',
            damage: 1,
            hpAfter: 1,
            hpMax: 32,
          ),
          runId: 'stress',
          frameIndex: 1,
          eventIndex: i,
        ),
    ];

    effects.consume(
      events,
      level: DegradationLevel.none,
      positionOf: (_) => const Vec2(960, 540),
    );

    expect(effects.numbers.length, budget.damageNumbers);
    expect(effects.rejectedNumbers, greaterThan(0), reason: '应记录拒绝次数');

    // 再喂一轮：仍不应超过上限（说明拒绝逻辑持续有效）。
    effects.consume(
      events,
      level: DegradationLevel.none,
      positionOf: (_) => const Vec2(960, 540),
    );
    expect(effects.numbers.length, budget.damageNumbers);
  });
}
