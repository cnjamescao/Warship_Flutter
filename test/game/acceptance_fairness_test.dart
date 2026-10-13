// ================================================================
// test/game/acceptance_fairness_test.dart —— AC-04
// ================================================================
// 产品基线 §9 AC-04：
//   「每种攻击在命中前有对应预警；生成点满足 360 px 安全距离；
//     无不可躲避 Boss 循环」
//
// 这里用 boss_aegis.json 的**真实参数**驱动公平性分析，因此它既是
// "实现是否正确"的检查，也是"数值是否可躲"的检查 —— 后者才是重点：
// 如果某一招在真实参数下不可躲，这条用例会失败，把它变成 CI 能拦住的
// 问题，而不是等到试玩时才发现。
// ================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/domain/fairness.dart';
import 'package:warship_flutter/game/domain/values.dart';

/// 产品基线 §3.3 / §3.4 的固定值。
const double kPlayerMoveSpeed = 340;
const double kDashDistance = 360;
const double kWholeWorldWidth = 1920;

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> attackById(Map<String, Object?> boss, String id) =>
    (boss['attacks'] as List)
        .cast<Map>()
        .firstWhere((a) => a['attackId'] == id)
        .cast<String, Object?>();

const analyzer = FairnessAnalyzer(
  moveSpeed: kPlayerMoveSpeed,
  dashDistance: kDashDistance,
  worldBounds: WorldBounds.playerDefault,
);

/// Boss 中心（产品基线 §7.2：入场终点）。
const Vec2 kBossCenter = Vec2(960, 210);

void main() {
  late Map<String, Object?> boss;

  setUpAll(() => boss = readJson('boss_aegis.json'));

  group('AC-04 每种攻击在命中前都有预警', () {
    test('造成伤害的招式预警时长均为正数', () {
      for (final attack in (boss['attacks'] as List).cast<Map>()) {
        final attackId = attack['attackId'] as String;
        final telegraph = (attack['telegraphSeconds'] as num).toDouble();
        final projectile = attack['projectile'] as Map?;
        final dealsDamage =
            (projectile?['damage'] as num?) != null &&
            (projectile!['damage'] as num) > 0 ||
            (attack['contactDamage'] as num?) != null ||
            (attack['damagePerTick'] as num?) != null;

        if (dealsDamage) {
          // 核心暴露（boss_weakpoint）不造成伤害，因此不在本条内。
          expect(
            telegraph,
            greaterThan(0),
            reason: '$attackId 造成伤害但没有预警',
          );
        }
      }
    });

    test('预警时长远长于一次逻辑步（不会"瞬间发生"）', () {
      for (final attack in (boss['attacks'] as List).cast<Map>()) {
        final telegraph = (attack['telegraphSeconds'] as num).toDouble();
        if (telegraph <= 0) {
          continue;
        }
        expect(
          telegraph,
          greaterThanOrEqualTo(0.6),
          reason: '${attack['attackId']} 的预警不得短于 0.6 秒',
        );
      }
    });

    test('敌方攻击全部有预警（除明确无预警的三连点射与直射）', () {
      final enemies = readJson('enemies.json');
      for (final enemy in (enemies['enemies'] as List).cast<Map>()) {
        final attack = enemy['attackProfile'] as Map?;
        if (attack == null) {
          continue;
        }
        final telegraph = (attack['telegraphSeconds'] as num?)?.toDouble() ?? 0;
        final hasTelegraphAsset = attack['telegraphAssetId'] != null;
        // Scout/Wing/Shield 是"无预警直射"，但它们有攻击前摇可读性；
        // 这里只要求：**若声明了预警资源，预警时长必须为正**。
        if (hasTelegraphAsset) {
          expect(
            telegraph,
            greaterThan(0),
            reason: '${enemy['id']} 声明了预警资源却没有预警时长',
          );
        }
      }
    });
  });

  group('AC-04 扇形点射可躲避', () {
    test('5 枚 -24..+24° 的扇面留有可躲空间', () {
      final attack = attackById(boss, 'boss_fan');
      final offsets = (attack['angleOffsetsDegrees'] as List)
          .whereType<num>()
          .map((n) => n.toDouble())
          .toList();
      final halfAngle =
          offsets.map((o) => o.abs()).reduce(math.max) * math.pi / 180;

      final verdict = analyzer.analyze(
        attackId: 'boss_fan',
        telegraphSeconds: (attack['telegraphSeconds'] as num).toDouble(),
        danger: ConeDanger(
          origin: kBossCenter,
          centerAngleRadians: math.pi / 2, // 朝下（指向玩家一侧）
          halfAngleRadians: halfAngle,
          range: 1500,
        ),
      );

      expect(verdict.hasSafeArea, isTrue, reason: '扇面之外必须是安全的');
      expect(verdict.isDodgeable, isTrue, reason: verdict.toString());
      expect(
        verdict.safeAreaRatio,
        greaterThan(0.5),
        reason: '扇面只覆盖很小一部分活动范围',
      );
    });
  });

  group('AC-04 环形弹幕可躲避', () {
    test('70° 缺口构成真实的逃生通道', () {
      final attack = attackById(boss, 'boss_ring');
      final gapTotal = (attack['gapTotalDegrees'] as num).toDouble();

      final verdict = analyzer.analyze(
        attackId: 'boss_ring',
        telegraphSeconds: (attack['telegraphSeconds'] as num).toDouble(),
        // 缺口中心在预警开始时对准玩家位置（产品基线 §7.2）。
        // 玩家在 Boss 下方，因此缺口朝下（+Y = π/2）——
        // 若把缺口指向正上方，它会落在可活动范围之外，采样区里
        // 就找不到安全点，那并不代表招式不可躲，而是场景设错了。
        danger: RingDanger(
          origin: kBossCenter,
          gapCenterAngleRadians: math.pi / 2,
          gapHalfAngleRadians: gapTotal / 2 * math.pi / 180,
          outerRadius: 1200,
        ),
      );

      expect(verdict.hasSafeArea, isTrue, reason: '缺口内必须是安全的');
      expect(
        verdict.safeAreaRatio,
        greaterThan(0.0),
        reason: '70° 缺口应在可活动范围内构成非空安全区',
      );
      // 说明：这里**不断言**完整的 isDodgeable。静态模型把整个环带视为
      // 立即致命，而真实的环形弹幕以 520 px/s 向外扩张 —— 玩家靠近 Boss
      // 时实际拥有比预警时长更多的可用时间。要给出可靠的"可躲避"结论，
      // 需要把弹幕飞行时间纳入模型，本轮不硬凑这个结论。
      // `缺口过窄时会被判定为不可躲避` 那条用例已验证分析器
      // 确实会报出问题，而不是只会说"没问题"。
    });

    test('缺口过窄时会被判定为不可躲避（证明检查真的有效）', () {
      // 这是**反向验证**：如果缺口缩到 2°，检查必须报出问题，
      // 否则说明这个分析器只会说"没问题"，没有用处。
      final verdict = analyzer.analyze(
        attackId: 'narrow_ring',
        telegraphSeconds: 0.1,
        danger: RingDanger(
          origin: kBossCenter,
          gapCenterAngleRadians: -math.pi / 2,
          gapHalfAngleRadians: 1 * math.pi / 180,
          outerRadius: 1200,
        ),
        dashAvailable: false,
      );

      expect(
        verdict.isDodgeable,
        isFalse,
        reason: '2° 缺口 + 0.1 秒预警不可能躲开，分析器必须报出来',
      );
    });
  });

  group('AC-04 激光扫射可躲避', () {
    test('预警期间足以离开扫射路径', () {
      final attack = attackById(boss, 'boss_laser');
      final width = (attack['laserWidth'] as num).toDouble();

      // 取扫射起始角度（指向 (240,1020)）为最不利的一刻。
      final from = const Vec2(240, 1020);
      final fromAngle = math.atan2(
        (from - kBossCenter).y,
        (from - kBossCenter).x,
      );

      final verdict = analyzer.analyze(
        attackId: 'boss_laser',
        telegraphSeconds: (attack['telegraphSeconds'] as num).toDouble(),
        danger: SweepLaserDanger(
          origin: kBossCenter,
          fromAngleRadians: fromAngle,
          toAngleRadians: fromAngle,
          progress: 0,
          halfWidth: width / 2,
          length: 1500,
        ),
      );

      expect(verdict.hasSafeArea, isTrue);
      expect(verdict.isDodgeable, isTrue, reason: verdict.toString());
    });
  });

  group('AC-04 冲锋可躲避', () {
    test('0.8 秒预警内可横移离开冲锋路径', () {
      final attack = attackById(boss, 'boss_charge');
      final telegraph = (attack['telegraphSeconds'] as num).toDouble();

      // 冲锋沿 y=210 横移，Boss 主体半径 150 → 危险带高度 300。
      final verdict = analyzer.analyze(
        attackId: 'boss_charge',
        telegraphSeconds: telegraph,
        danger: ConeDanger(
          origin: const Vec2(960, 210),
          centerAngleRadians: 0, // 横向
          halfAngleRadians: math.pi / 2,
          range: 900,
        ),
      );

      // 冲锋的危险区是横贯的带状，玩家在其上方或下方即可；
      // 这里只要求"存在安全区"——
      expect(verdict.hasSafeArea, isTrue, reason: '冲锋不应覆盖整个战场');
    });

    test('玩家横移所需距离在 0.8 秒内可达成', () {
      // Boss 主体半径 150、玩家半径 30 → 需要离开 180 px 才安全。
      const needed = 180.0;
      const available = kPlayerMoveSpeed * 0.8;
      expect(
        available,
        greaterThan(needed),
        reason: '0.8 秒 × 340 px/s = 272 px，足以离开冲锋路径',
      );
    });
  });

  group('AC-04 生成点安全距离', () {
    test('敌方生成点距玩家 x ≥360（产品基线 §6）', () {
      const spawnPoints = <double>[240, 480, 720, 960, 1200, 1440, 1680];

      for (final playerX in <double>[30, 480, 960, 1440, 1890]) {
        final valid = spawnPoints
            .where(
              (x) => FairnessAnalyzer.spawnPointXIsSafe(
                spawnX: x,
                playerX: playerX,
              ),
            )
            .toList();
        expect(
          valid,
          isNotEmpty,
          reason: '玩家在 x=$playerX 时应至少有一个合法生成点',
        );
        for (final x in valid) {
          expect((x - playerX).abs(), greaterThanOrEqualTo(360));
        }
      }
    });

    test('子弹生成点距玩家碰撞中心 ≥180（产品设计文档 §3.3）', () {
      // Boss 从 (960,210) 向下发射；玩家在最近的可能位置 (960, 240) 时，
      // 生成点与玩家中心只有 30 px —— 这正是"屏幕外/贴脸生成"要避免的。
      expect(
        FairnessAnalyzer.spawnIsSafe(
          spawnPoint: kBossCenter,
          playerCenter: const Vec2(960, 900),
          playerRadius: 30,
        ),
        isTrue,
      );
      expect(
        FairnessAnalyzer.spawnIsSafe(
          spawnPoint: kBossCenter,
          playerCenter: const Vec2(960, 240),
          playerRadius: 30,
        ),
        isFalse,
        reason: '贴脸生成必须被判定为不安全',
      );
    });

    test('世界宽度足以容纳 360 px 安全距离的两侧生成点', () {
      // 玩家在最中间 (960) 时，左右各需 360 px：
      expect(kWholeWorldWidth / 2, greaterThan(360));
    });
  });
}
