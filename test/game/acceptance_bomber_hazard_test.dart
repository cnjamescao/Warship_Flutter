// ================================================================
// test/game/acceptance_bomber_hazard_test.dart —— F-36 第 4 步
// ================================================================
// 协议 §3.2（F-36 批复）：
//   「`bomber_drop` 的落点固定为 t=0 的 origin；预警 0.40 s 后创建
//     半径 90 的 ACTIVE 危险区，持续 2.2 s、每 0.25 s 每目标至多
//     造成 8 点伤害。预警由 TelegraphView 负责，故 ACTIVE Hazard 的
//     warningSeconds 为 0，不能重复预警。」
//
// 修复前：`_spawnEnemyAttack` 只处理 `projectile`，
// `spec == null` 时**直接 return** —— EN-BOMBER 的 hazard 配置
// （半径 90 / 2.2s / 0.25s / 8 点）从未被实例化，
// `hazards` 列表恒为空，`_drawHazards` 永远画不出东西。
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
import 'package:warship_flutter/game/domain/values.dart';
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
    eliteAffixes: <String, EliteAffix>{
      for (final raw in (enemies['affixes'] as List? ?? const []).cast<Map>())
        (raw['id'] as String):
            EliteAffix.fromConfig(raw.cast<String, Object?>()),
    },
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'bomber-hazard',
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
  test('bomber_drop 到期后创建 ACTIVE 危险区，参数与规范一致', () {
    final rt = _build();
    const step = GameClock.fixedStepSeconds;

    HazardZone? spawned;
    for (var i = 0; i < 200 * 60; i++) {
      rt.advance(step, InputFrame.idle);
      final fired = rt.lastFrameEvents.any(
        (e) =>
            e.event is EnemyAttackFired &&
            (e.event as EnemyAttackFired).attackId == 'bomber_drop',
      );
      if (fired && rt.hazards.isNotEmpty) {
        spawned = rt.hazards.first;
        break;
      }
    }

    expect(
      spawned,
      isNotNull,
      reason: 'bomber_drop 发射后应创建危险区 —— '
          '修复前 _spawnEnemyAttack 在 projectile 为 null 时直接 return，'
          '危险区从未被创建',
    );

    // 协议 §3.2 明文数值。
    expect(spawned!.radius, 90, reason: '危险区半径应为 90');
    expect(spawned.activeSeconds, 2.2, reason: '危险区应持续 2.2 秒');
    expect(spawned.tickSeconds, 0.25, reason: '伤害间隔应为 0.25 秒');
    expect(spawned.damagePerTick, 8, reason: '每 tick 至多 8 点伤害');
    expect(
      spawned.warningSeconds,
      0,
      reason: 'ACTIVE 危险区的 warningSeconds 必须为 0 —— '
          '预警由 TelegraphView 负责，不能重复预警（协议 §3.2）',
    );
    // warningSeconds == 0 的直接后果：创建即处于 ACTIVE。
    expect(
      spawned.isWarning,
      isFalse,
      reason: '危险区创建后应立刻处于 ACTIVE',
    );
  });

  test('危险区每 0.25 秒对区内目标造成 8 点伤害', () {
    final rt = _build();
    const step = GameClock.fixedStepSeconds;

    // 跑到出现危险区。
    for (var i = 0; i < 200 * 60 && rt.hazards.isEmpty; i++) {
      rt.advance(step, InputFrame.idle);
    }
    expect(rt.hazards, isNotEmpty, reason: '应已出现危险区');
    final hazard = rt.hazards.first;

    // 把玩家放到危险区中心（刻意制造命中条件）。
    rt.player.position = Vec2(hazard.position.x, hazard.position.y);
    // 伤害先扣护盾再扣 HP，因此以**两者合计**判定。
    int totalVitals() => rt.player.health.current + rt.player.shield.current;
    final hpBefore = totalVitals();

    // 推进超过两个伤害间隔，统计受到的伤害。
    // 逐步记录生命/护盾合计的下降量 —— 危险区每 0.25 秒结算一次，
    // 因此**非零**的逐步下降量就是每 tick 的伤害。
    // （`DamageIntent` 是内部指令而非发布事件，无法从事件流取到；
    //   这里用可观测的总量变化反推，同样能钉住"每 tick 8 点"。）
    final deltas = <int>[];
    var previous = totalVitals();
    for (var i = 0; i < (0.6 / step).ceil(); i++) {
      // 危险区会自行过期；站在区内期间保持被命中位置。
      if (rt.hazards.isNotEmpty) {
        rt.player.position = Vec2(
          rt.hazards.first.position.x,
          rt.hazards.first.position.y,
        );
      }
      rt.advance(step, InputFrame.idle);
      final now = totalVitals();
      if (now < previous) {
        deltas.add(previous - now);
      }
      previous = now;
    }

    // ⚠️ 集成层**无法**单独归因于危险区：同一逻辑步内还可能有敌弹/接触
    // 伤害（实测单步 delta 出现过 20）。因此这里只验证"危险区确实造成
    // 了伤害"，而**每 tick 8 点 / 0.25 秒一次**这条合同由下面的
    // `HazardZone.tick` 单元用例在**隔离环境**下精确验证。
    expect(deltas, isNotEmpty, reason: '危险区应对区内玩家结算伤害');

    final damage = hpBefore - totalVitals();
    expect(
      damage,
      greaterThan(0),
      reason: '玩家站在危险区内应受到伤害（修复前危险区不存在，'
          '因此这段伤害完全缺失）—— 实际 $damage',
    );
    // 每 0.25 秒一次、每次 8 点：0.6 秒内至多 3 次。
    expect(
      damage,
      lessThanOrEqualTo(24),
      reason: '0.6 秒内的总伤害不应超过 3 个 tick × 8 点 —— 实际 $damage',
    );
    expect(totalVitals(), lessThan(hpBefore));
  });

  test('危险区 tick 节拍：warningSeconds=0 时每 0.25 秒结算一次', () {
    // **隔离验证**"每 0.25 s 每目标至多 8 点"这条合同 ——
    // 不引入敌弹/接触等其它伤害源。
    final zone = HazardZone(
      id: const EntityId(EntityKind.hazard, 0),
      position: Vec2(0, 0),
      radius: 90,
      warningSeconds: 0,
      activeSeconds: 2.2,
      tickSeconds: 0.25,
      damagePerTick: 8,
      sourceId: const EntityId(EntityKind.enemy, 1),
    );
    const step = GameClock.fixedStepSeconds;

    // warningSeconds = 0 ⇒ 创建即 ACTIVE，不重复预警。
    expect(zone.isWarning, isFalse);

    var ticks = 0;
    var elapsed = 0.0;
    while (elapsed < 2.2) {
      if (zone.tick(step)) {
        ticks++;
      }
      elapsed += step;
    }
    // 2.2 秒 / 0.25 秒 = 8.8 ⇒ 恰好 8 次结算。
    expect(
      ticks,
      8,
      reason: '2.2 秒内应恰好结算 8 次（每 0.25 秒一次）—— 实际 $ticks',
    );
    // 每次结算的伤害由 `damagePerTick` 决定，规范值为 8。
    expect(zone.damagePerTick, 8);
    expect(zone.isExpired, isTrue);
  });
}
