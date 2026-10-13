// ================================================================
// test/unit/domain/director_enemy_test.dart —— 波次、导演器与敌人行为
// ================================================================
// 覆盖 P0：T-WAVE-01 / T-WAVE-02 / T-ENEMY-01 / T-ENEMY-02 / T-ENEMY-03
// 直接读取**真实** assets/config/v2/enemies.json 与 waves_normal.json，
// 因此它同时验证配置内容与规则实现两侧。
// ================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/values.dart';

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

const double kStep = 1 / 60;

/// 从真实配置构建导演器。
DirectorSystem buildDirector(Map<String, Object?> waves) {
  final windows = ((waves['dynamicAdjustment'] as Map)['minimumUpgradeCountBySecond']
          as List)
      .cast<Map>()
      .map((m) => MinimumUpgradeWindow.fromConfig(m.cast<String, Object?>()))
      .toList();
  final rows = (waves['waves'] as List)
      .cast<Map>()
      .map((m) => WaveRow.fromConfig(m.cast<String, Object?>()))
      .toList();

  return DirectorSystem(
    rows: rows,
    minimumUpgradeWindows: windows,
    eliteRules: const <String, int>{'hp': 6, 'xp': 3, 'score': 8},
  );
}

Map<String, EnemyTuning> buildEnemies(Map<String, Object?> enemies) {
  final result = <String, EnemyTuning>{};
  for (final raw in (enemies['enemies'] as List).cast<Map>()) {
    final tuning = EnemyTuning.fromConfig(raw.cast<String, Object?>());
    result[tuning.id] = tuning;
  }
  return result;
}

void main() {
  late Map<String, Object?> wavesConfig;
  late Map<String, Object?> enemiesConfig;
  late Map<String, EnemyTuning> tunings;

  setUpAll(() {
    wavesConfig = readJson('waves_normal.json');
    enemiesConfig = readJson('enemies.json');
    tunings = buildEnemies(enemiesConfig);
  });

  group('配置加载', () {
    test('五类敌人全部可解析', () {
      expect(tunings.keys.toSet(), <String>{
        'EN-SCOUT',
        'EN-WING',
        'EN-SNIPER',
        'EN-BOMBER',
        'EN-SHIELD',
      });
    });

    test('数值与产品基线 §5 一致', () {
      expect(tunings['EN-SCOUT']!.hp, 18);
      expect(tunings['EN-SCOUT']!.move.speed, 180);
      expect(tunings['EN-SCOUT']!.move.amplitude, 80);
      expect(tunings['EN-SCOUT']!.move.periodSeconds, 1.6);
      expect(tunings['EN-SCOUT']!.attack, isNull, reason: 'Scout 不攻击');

      expect(tunings['EN-WING']!.hp, 32);
      expect(tunings['EN-WING']!.move.formationOffsets.length, 3);
      expect(tunings['EN-WING']!.attack!.intervalSeconds, 1.8);
      expect(tunings['EN-WING']!.attack!.projectile!.damage, 8);
      expect(tunings['EN-WING']!.attack!.projectile!.speed, 720);

      expect(tunings['EN-SNIPER']!.hp, 50);
      expect(tunings['EN-SNIPER']!.move.holdY, 260);
      expect(tunings['EN-SNIPER']!.attack!.telegraphSeconds, 0.75);
      expect(tunings['EN-SNIPER']!.attack!.projectile!.damage, 18);
      expect(tunings['EN-SNIPER']!.attack!.intervalSeconds, 3.0);

      expect(tunings['EN-BOMBER']!.hp, 95);
      expect(tunings['EN-BOMBER']!.attack!.intervalSeconds, 3.5);
      expect(tunings['EN-BOMBER']!.attack!.hazard!.radius, 90);
      expect(tunings['EN-BOMBER']!.attack!.hazard!.activeSeconds, 2.2);
      expect(tunings['EN-BOMBER']!.attack!.hazard!.damagePerTick, 8);

      expect(tunings['EN-SHIELD']!.hp, 110);
      expect(tunings['EN-SHIELD']!.frontShieldReduction, 0.75);
      expect(tunings['EN-SHIELD']!.frontShieldFacing, const Vec2(0, 1));
      expect(tunings['EN-SHIELD']!.attack!.intervalSeconds, 2.5);
      expect(tunings['EN-SHIELD']!.attack!.burstCount, 3);
      expect(tunings['EN-SHIELD']!.attack!.burstAngleOffsetsDegrees,
          <double>[-10, 0, 10]);
    });

    test('越界伤害普通 8、精英 15', () {
      for (final tuning in tunings.values) {
        expect(tuning.breachDamage, 8);
      }
      expect(enemiesConfig['elite'], isNotNull);
    });
  });

  group('T-WAVE-01 0–150 秒固定生成表', () {
    test('31 行、5 秒间隔、风险门在 55/115、Boss 在 150', () {
      final director = buildDirector(wavesConfig);
      expect(director.rows.length, 31);

      final gateSeconds = director.rows
          .where((r) => r.isRiskGate)
          .map((r) => r.startSecond)
          .toList();
      expect(gateSeconds, <int>[55, 115]);

      final bossRows = director.rows.where((r) => r.isBossEntry).toList();
      expect(bossRows.length, 1);
      expect(bossRows.single.startSecond, 150);
    });

    test('逐秒推进 0–150 秒，每行恰好触发一次且顺序正确', () {
      final director = buildDirector(wavesConfig);
      final fired = <int>[];

      // 玩家固定在中心，保证所有生成点都合法。
      const player = Vec2(960, 1050);

      for (var frame = 0; frame <= 150 * 60; frame++) {
        final seconds = frame * kStep;
        final triggers = director.step(
          combatSeconds: seconds,
          playerPosition: player,
          playerHp: 100,
          hpDamageInLast15s: 0,
          upgradeCount: 0,
          activeEnemyCount: 0,
        );
        for (final trigger in triggers) {
          if (trigger.row.spawns.isNotEmpty) {
            fired.add(trigger.row.startSecond);
          }
        }
      }

      final expected = director.rows
          .where((r) => r.spawns.isNotEmpty)
          .map((r) => r.startSecond)
          .toList();

      expect(fired, expected, reason: '每行恰好触发一次且按时间顺序');
    });

    test('固定精英事件为 65/105/130 秒，且敌人类型与词缀正确', () {
      final rows = (wavesConfig['waves'] as List).cast<Map>();
      final elites = <int, Map>{};
      for (final row in rows) {
        for (final spawn in (row['spawns'] as List).cast<Map>()) {
          if (spawn['isElite'] == true) {
            elites[row['startSecond'] as int] = spawn;
          }
        }
      }

      expect(elites.keys.toSet(), <int>{65, 105, 130});
      expect(elites[65]!['enemyId'], 'EN-WING');
      expect(elites[65]!['affixId'], 'AFFIX-ACCEL');
      expect(elites[105]!['enemyId'], 'EN-SNIPER');
      expect(elites[105]!['affixId'], 'AFFIX-SHIELD');
      expect(elites[130]!['enemyId'], 'EN-SHIELD');
      expect(elites[130]!['affixId'], 'AFFIX-BARRAGE');
    });

    test('精英倍率为 HP×6 / 经验×3 / 得分×8', () {
      final elite = enemiesConfig['elite'] as Map;
      expect(elite['hpMultiplier'], 6);
      expect(elite['xpMultiplier'], 3);
      expect(elite['scoreMultiplier'], 8);
      expect(elite['coreShieldRestore'], 10);
      expect(elite['coreXpIfShieldFull'], 15);
    });

    test('三个词缀的效果与产品基线 §5 一致', () {
      final affixes = <String, EliteAffix>{
        for (final raw in (enemiesConfig['affixes'] as List).cast<Map>())
          (raw['id'] as String):
              EliteAffix.fromConfig(raw.cast<String, Object?>()),
      };

      expect(affixes['AFFIX-ACCEL']!.moveSpeedMultiplier, 1.3);
      expect(affixes['AFFIX-SHIELD']!.shieldGrantAmount, 20);
      expect(affixes['AFFIX-SHIELD']!.shieldGrantIntervalSeconds, 8.0);
      expect(affixes['AFFIX-BARRAGE']!.extraProjectiles, 2);
      expect(affixes['AFFIX-BARRAGE']!.telegraphExtraSeconds, 0.2);
    });
  });

  group('T-WAVE-02 动态校正', () {
    test('最低升级数时段与产品基线 §6 一致', () {
      final director = buildDirector(wavesConfig);

      expect(director.minimumUpgradesAt(0), 0);
      expect(director.minimumUpgradesAt(19.99), 0);
      expect(director.minimumUpgradesAt(20), 1);
      expect(director.minimumUpgradesAt(44.99), 1);
      expect(director.minimumUpgradesAt(45), 2);
      expect(director.minimumUpgradesAt(75), 3);
      expect(director.minimumUpgradesAt(105), 4);
      expect(director.minimumUpgradesAt(135), 5);
    });

    test('HP ≤35 时下两批各减 1 个 Scout', () {
      final director = buildDirector(wavesConfig);
      const player = Vec2(960, 1050);

      // 首次评估在 10 秒（t=0 时"过去 15 秒未受伤"平凡成立，不应评估）。
      director.step(
        combatSeconds: 10,
        playerPosition: player,
        playerHp: 30,
        hpDamageInLast15s: 0,
        upgradeCount: 0,
        activeEnemyCount: 0,
      );

      expect(director.decisions.first.kind, AdjustmentKind.reduce);
      expect(director.decisions.first.scoutDelta, -1);

      // 第 0 秒这一批 Scout×3 → 2。
      final spawns = director.rows
          .firstWhere((r) => r.startSecond == 0)
          .spawns;
      expect(spawns.first.count, 3, reason: '原始配置不被就地修改');
    });

    test('HP ≥80 且未受伤且升级达标时各加 1 个 Scout', () {
      final director = buildDirector(wavesConfig);
      const player = Vec2(960, 1050);

      director.step(
        combatSeconds: 10,
        playerPosition: player,
        playerHp: 100,
        hpDamageInLast15s: 0,
        upgradeCount: 1, // 10 秒的最低升级数为 0，1 也达标
        activeEnemyCount: 0,
      );

      expect(director.decisions.first.kind, AdjustmentKind.increase);
      expect(director.decisions.first.scoutDelta, 1);
    });

    test('HP 健康但升级数未达标时不增加', () {
      final director = buildDirector(wavesConfig);
      const player = Vec2(960, 1050);

      // 30 秒：最低升级数为 1，但玩家只有 0 次升级。
      director.step(
        combatSeconds: 30,
        playerPosition: player,
        playerHp: 100,
        hpDamageInLast15s: 0,
        upgradeCount: 0,
        activeEnemyCount: 0,
      );

      expect(director.decisions.first.kind, AdjustmentKind.none);
    });

    test('近 15 秒受到 ≥30 HP 伤害时同样触发减少', () {
      final director = buildDirector(wavesConfig);
      const player = Vec2(960, 1050);

      director.step(
        combatSeconds: 10,
        playerPosition: player,
        playerHp: 90,
        hpDamageInLast15s: 30,
        upgradeCount: 0,
        activeEnemyCount: 0,
      );

      expect(director.decisions.first.kind, AdjustmentKind.reduce);
    });

    test('减少时若该批没有 Scout 则改减 Wing', () {
      final director = buildDirector(wavesConfig);
      const player = Vec2(960, 1050);

      // 先制造"减少"的待生效状态（首次评估在 10 秒）。
      director.step(
        combatSeconds: 10,
        playerPosition: player,
        playerHp: 30,
        hpDamageInLast15s: 0,
        upgradeCount: 0,
        activeEnemyCount: 0,
      );

      // 20 秒批次是 Wing×3（无 Scout），应改减 Wing。
      List<DirectorTrigger> triggers = const [];
      for (var frame = 0; frame <= 20 * 60; frame++) {
        triggers = director.step(
          combatSeconds: frame * kStep,
          playerPosition: player,
          playerHp: 30,
          hpDamageInLast15s: 0,
          upgradeCount: 0,
          activeEnemyCount: 0,
        );
        if (triggers.isNotEmpty &&
            triggers.first.row.startSecond == 20 &&
            triggers.first.spawns.isNotEmpty) {
          break;
        }
      }

      final wing = triggers.first.spawns.firstWhere(
        (s) => s.enemyId == 'EN-WING',
      );
      expect(wing.count, 2, reason: 'Wing×3 → 2');
    });

    test('固定精英批次不受动态校正影响', () {
      final director = buildDirector(wavesConfig);
      const player = Vec2(960, 1050);

      List<DirectorTrigger> triggers = const [];
      for (var frame = 0; frame <= 65 * 60; frame++) {
        triggers = director.step(
          combatSeconds: frame * kStep,
          playerPosition: player,
          playerHp: 30, // 持续处于"减少"条件
          hpDamageInLast15s: 0,
          upgradeCount: 0,
          activeEnemyCount: 0,
        );
        if (triggers.isNotEmpty && triggers.first.row.startSecond == 65) {
          break;
        }
      }

      final elite = triggers.first.spawns.firstWhere((s) => s.isElite);
      expect(elite.count, 1, reason: '精英数量永不被校正');
      expect(elite.enemyId, 'EN-WING');
    });
  });

  group('生成点安全规则（产品基线 §6）', () {
    test('只选距玩家 x ≥360 的生成点', () {
      final director = buildDirector(wavesConfig);

      final chosen = director.selectSpawnCenterX(
        playerX: 960,
        desiredCenterX: 960,
      );

      expect(chosen, isNotNull);
      expect((chosen! - 960).abs(), greaterThanOrEqualTo(360));
    });

    test('所有点都太近时返回 null（调用方必须延后，不可贴脸生成）', () {
      // 把玩家放在正中间时，最远的点是 240/1680（距 720）——都合法。
      // 因此改写 spawnXPoints 制造"无合法点"的极端场景。
      final tight = DirectorSystem(
        rows: const <WaveRow>[],
        minimumUpgradeWindows: const <MinimumUpgradeWindow>[],
        eliteRules: const <String, int>{},
        spawnXPoints: const <double>[900, 1000],
        minDistanceFromPlayerX: 360,
      );

      expect(
        tight.selectSpawnCenterX(playerX: 950, desiredCenterX: 950),
        isNull,
      );
    });

    test('越界预警线 920 与移除线 1140', () {
      final system = EnemySystem(
        breachWarningY: (wavesConfig['spawn'] as Map?)?['y'] != null
            ? 920
            : 920,
        breachRemoveY: 1140,
      );
      expect(system.breachWarningY, 920);
      expect(system.breachRemoveY, 1140);
    });
  });

  group('T-ENEMY-03 移动档案', () {
    test('Scout 以出生 x 为中心作振幅 80、周期 1.6 秒的正弦横摆并下行', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final scout = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-SCOUT']!,
        spawnX: 960,
      );

      const player = Vec2(960, 900);

      // 推进 0.4 秒（= 1/4 周期）：正弦达到峰值 +80。
      for (var i = 0; i < 24; i++) {
        system.step(enemy: scout, dt: kStep, playerPosition: player);
      }

      expect(scout.position.x, closeTo(1040, 1.0));
      expect(scout.position.y, closeTo(-80 + 180 * 0.4, 1.0));
    });

    test('Sniper 移动到 y=260 后停驻', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final sniper = system.spawn(
        id: const EntityId(EntityKind.enemy, 2),
        tuning: tunings['EN-SNIPER']!,
        spawnX: 960,
        spawnY: 0,
      );

      const player = Vec2(960, 900);
      for (var i = 0; i < 60 * 10; i++) {
        system.step(enemy: sniper, dt: kStep, playerPosition: player);
      }

      expect(sniper.position.y, 260);
      expect(sniper.isHolding, isTrue);
    });

    test('Wing 队形偏移为 (-100,40)/(0,0)/(100,40)', () {
      final offsets = tunings['EN-WING']!.move.formationOffsets;
      expect(offsets, <Vec2>[
        const Vec2(-100, 40),
        const Vec2(0, 0),
        const Vec2(100, 40),
      ]);
    });

    test('Bomber 与 Shield 直线下行', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      const player = Vec2(960, 900);

      final bomber = system.spawn(
        id: const EntityId(EntityKind.enemy, 3),
        tuning: tunings['EN-BOMBER']!,
        spawnX: 500,
        spawnY: 0,
      );
      final shield = system.spawn(
        id: const EntityId(EntityKind.enemy, 4),
        tuning: tunings['EN-SHIELD']!,
        spawnX: 1400,
        spawnY: 0,
      );

      for (var i = 0; i < 60; i++) {
        system.step(enemy: bomber, dt: kStep, playerPosition: player);
        system.step(enemy: shield, dt: kStep, playerPosition: player);
      }

      expect(bomber.position.x, 500, reason: '直线下行，x 不变');
      expect(bomber.position.y, closeTo(55, 1.0));
      expect(shield.position.x, 1400);
      expect(shield.position.y, closeTo(85, 1.0));
    });
  });

  group('T-ENEMY-01 攻击时序', () {
    test('第一发在完全进入后等待**完整**冷却时间', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      // Wing 从 y=-80 出发，140 px/s，约 0.57 秒后中心才到 y=0。
      final wing = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-WING']!,
        spawnX: 960,
      );
      const player = Vec2(960, 900);

      var firstAttackAt = -1.0;
      for (var frame = 0; frame < 60 * 5; frame++) {
        final event = system.step(
          enemy: wing,
          dt: kStep,
          playerPosition: player,
        );
        if (event.attackRequests.isNotEmpty && firstAttackAt < 0) {
          firstAttackAt = frame * kStep;
        }
      }

      // 进入时刻 ≈ 80/140 ≈ 0.571 s，再加 1.8 s 冷却 ≈ 2.371 s。
      expect(firstAttackAt, greaterThan(0.571));
      expect(firstAttackAt, closeTo(0.571 + 1.8, 0.05));
    });

    test('屏幕外不攻击', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final wing = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-WING']!,
        spawnX: 960,
      );
      const player = Vec2(960, 900);

      // 在 y<0 期间推进：不应有任何攻击请求。
      for (var i = 0; i < 30; i++) {
        final event = system.step(
          enemy: wing,
          dt: kStep,
          playerPosition: player,
        );
        expect(event.attackRequests, isEmpty);
      }
      expect(wing.position.y, lessThan(0));
    });

    test('攻击请求带正确的 attackId 与投射物参数', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final shield = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-SHIELD']!,
        spawnX: 960,
        spawnY: 0,
      );
      const player = Vec2(960, 900);

      EnemyAttackRequest? request;
      for (var i = 0; i < 60 * 5; i++) {
        final event = system.step(
          enemy: shield,
          dt: kStep,
          playerPosition: player,
        );
        if (event.attackRequests.isNotEmpty) {
          request = event.attackRequests.first;
          break;
        }
      }

      expect(request, isNotNull);
      expect(request!.attackId, 'shield_shot');
      expect(request.enemyId, 'EN-SHIELD');
      expect(request.projectile!.damage, 8);
      expect(request.projectile!.speed, 800);
      expect(request.projectile!.radius, 14);
      expect(request.projectile!.lifetimeSeconds, 2.0);
      expect(request.projectileCount, 3, reason: '三连点射');
    });

    test('弹幕词缀增加 2 枚投射物并延长 0.2 秒预警', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final elite = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-SHIELD']!,
        spawnX: 960,
        spawnY: 0,
        isElite: true,
        affix: const EliteAffix(
          id: 'AFFIX-BARRAGE',
          extraProjectiles: 2,
          telegraphExtraSeconds: 0.2,
        ),
      );

      expect(elite.effectiveProjectileCount, 5);
      expect(elite.effectiveTelegraphSeconds, closeTo(0.2, 1e-9));
      expect(elite.health.max, 110 * 6, reason: '精英 HP ×6');
    });

    test('加速词缀提升 30% 移速', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final elite = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-SCOUT']!,
        spawnX: 960,
        isElite: true,
        affix: const EliteAffix(id: 'AFFIX-ACCEL', moveSpeedMultiplier: 1.3),
      );

      expect(elite.effectiveSpeed, closeTo(180 * 1.3, 1e-9));
    });

    test('护体词缀每 8 秒给 20 护盾', () {
      final system = EnemySystem(breachWarningY: 9200, breachRemoveY: 99999);
      final elite = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-SCOUT']!,
        spawnX: 960,
        spawnY: 0,
        isElite: true,
        affix: const EliteAffix(
          id: 'AFFIX-SHIELD',
          shieldGrantAmount: 20,
          shieldGrantIntervalSeconds: 8.0,
        ),
      );
      const player = Vec2(960, 900);

      for (var i = 0; i < 60 * 8 + 2; i++) {
        system.step(enemy: elite, dt: kStep, playerPosition: player);
      }
      expect(elite.shield, greaterThanOrEqualTo(20));
    });
  });

  group('T-ENEMY-02 越界突破', () {
    test('中心越过 y=1140 触发一次突破', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final scout = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-SCOUT']!,
        spawnX: 960,
        spawnY: 1100,
      );
      const player = Vec2(960, 900);

      EnemyState? breached;
      for (var i = 0; i < 60; i++) {
        final event = system.step(
          enemy: scout,
          dt: kStep,
          playerPosition: player,
        );
        if (event.breached != null) {
          breached = event.breached;
          break;
        }
      }

      expect(breached, isNotNull);
      expect(scout.position.y, greaterThan(1140));
    });

    test('y=920 首次进入时发出逃逸预警，且只发一次', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final scout = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-SCOUT']!,
        spawnX: 960,
        spawnY: 900,
      );
      const player = Vec2(960, 900);

      var warnings = 0;
      for (var i = 0; i < 60; i++) {
        final event = system.step(
          enemy: scout,
          dt: kStep,
          playerPosition: player,
        );
        if (event.breachWarning != null) {
          warnings++;
        }
      }

      expect(warnings, 1, reason: '预警只发一次');
    });

    test('越过 1140 之后不再继续更新攻击', () {
      final system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
      final wing = system.spawn(
        id: const EntityId(EntityKind.enemy, 1),
        tuning: tunings['EN-WING']!,
        spawnX: 960,
        spawnY: 1135,
      );
      const player = Vec2(960, 900);

      final event = system.step(
        enemy: wing,
        dt: kStep * 10,
        playerPosition: player,
      );

      expect(event.breached, isNotNull);
      expect(event.attackRequests, isEmpty);
    });
  });

  group('Shield 正面锥减伤（产品基线 §3.4）', () {
    late EnemySystem system;

    setUp(() {
      system = EnemySystem(breachWarningY: 920, breachRemoveY: 1140);
    });

    test('玩家在正下方（锥内）时减伤 75%', () {
      final damage = system.applyFrontShield(
        tunings['EN-SHIELD']!,
        const Vec2(960, 300),
        const Vec2(960, 900), // 正下方，与朝向 (0,1) 一致
        100,
      );

      expect(damage, 25);
    });

    test('玩家在正上方（锥外）时全额伤害', () {
      final damage = system.applyFrontShield(
        tunings['EN-SHIELD']!,
        const Vec2(960, 300),
        const Vec2(960, 0), // 正上方
        100,
      );

      expect(damage, 100);
    });

    test('120° 锥的边界附近：略小于半角 60° 仍在锥内', () {
      // 半角 60° → cos 60° = 0.5。构造与朝向夹角 50° 的方向。
      final enemy = const Vec2(0, 0);
      final angle50 = 50 * 3.141592653589793 / 180;
      final inside = Vec2(
        100 * math.sin(angle50),
        100 * math.cos(angle50),
      );
      expect(
        system.applyFrontShield(tunings['EN-SHIELD']!, enemy, inside, 100),
        25,
      );

      // 夹角 70° 时已在锥外。
      final angle70 = 70 * 3.141592653589793 / 180;
      final outside = Vec2(
        100 * math.sin(angle70),
        100 * math.cos(angle70),
      );
      expect(
        system.applyFrontShield(tunings['EN-SHIELD']!, enemy, outside, 100),
        100,
      );
    });

    test('非 Shield 敌人没有正面减伤', () {
      expect(
        system.applyFrontShield(
          tunings['EN-SCOUT']!,
          const Vec2(0, 0),
          const Vec2(0, 100),
          100,
        ),
        100,
      );
    });
  });
}
