// ================================================================
// test/unit/fleet_controller_test.dart —— 舰队边界与推进
// ================================================================
// 覆盖规格 §3.3 [修订] 与验收项 T08。
// 旧实现的缺陷：越界后只反向、不夹位，
// 于是越界状态下每帧都判定"触边"，导致连续下移、快速掉命。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/components.dart';
import 'package:warship_flutter/game/fleet_controller.dart';
import 'package:warship_flutter/game/game_config.dart';

void main() {
  const config = GameConfig();

  /// 构造一个脱离组件树的控制器（attach/detach 只记录，不触碰 Flame）。
  ({FleetController fleet, List<AlienEnemy> attached, List<AlienEnemy> detached})
  buildController({GameConfig cfg = config}) {
    final attached = <AlienEnemy>[];
    final detached = <AlienEnemy>[];
    final fleet = FleetController(
      config: cfg,
      attach: attached.add,
      detach: detached.add,
    );
    return (fleet: fleet, attached: attached, detached: detached);
  }

  group('planFleetMove 纯函数', () {
    test('未触边时原样应用目标位移', () {
      final plan = planFleetMove(
        desiredDelta: 10,
        fleetMinX: 48,
        fleetMaxX: 672,
        worldWidth: 800,
      );
      expect(plan.appliedDelta, 10);
      expect(plan.hitBoundary, isFalse);
    });

    test('向右越界时，削到恰好贴住右边界并报告触边', () {
      final plan = planFleetMove(
        desiredDelta: 200,
        fleetMinX: 48,
        fleetMaxX: 672,
        worldWidth: 800,
      );
      expect(plan.appliedDelta, 128, reason: '只剩 800-672=128 的空间');
      expect(plan.hitBoundary, isTrue);
    });

    test('向左越界时，削到恰好贴住左边界并报告触边', () {
      final plan = planFleetMove(
        desiredDelta: -200,
        fleetMinX: 48,
        fleetMaxX: 672,
        worldWidth: 800,
      );
      expect(plan.appliedDelta, -48);
      expect(plan.hitBoundary, isTrue);
    });

    test('已经贴着边界时，位移为 0 且报告触边（而不是继续越界）', () {
      final plan = planFleetMove(
        desiredDelta: 30,
        fleetMinX: 128,
        fleetMaxX: 800,
        worldWidth: 800,
      );
      expect(plan.appliedDelta, 0);
      expect(plan.hitBoundary, isTrue);
    });

    test('位移为 0 时不报告触边', () {
      final plan = planFleetMove(
        desiredDelta: 0,
        fleetMinX: 100,
        fleetMaxX: 400,
        worldWidth: 800,
      );
      expect(plan.appliedDelta, 0);
      expect(plan.hitBoundary, isFalse);
    });

    test('舰队比世界还宽（异常输入）时不抛出，且不产生负位移', () {
      final plan = planFleetMove(
        desiredDelta: 50,
        fleetMinX: -20,
        fleetMaxX: 900,
        worldWidth: 800,
      );
      expect(plan.appliedDelta, 0);
      expect(plan.hitBoundary, isTrue);
    });
  });

  group('舰队生成', () {
    test('按 7 列 × 5 行生成 35 个敌人，并全部挂到组件树', () {
      final ctx = buildController();
      ctx.fleet.createFleet();

      expect(ctx.fleet.alienCount, 35);
      expect(ctx.attached.length, 35);
      expect(ctx.fleet.aliens.length, 35);
    });

    test('舰队初始完全位于逻辑画布内', () {
      final ctx = buildController();
      ctx.fleet.createFleet();

      expect(ctx.fleet.minX, greaterThanOrEqualTo(0));
      expect(
        ctx.fleet.maxX,
        lessThanOrEqualTo(config.logicalWidth),
        reason: '舰队一开始就必须能完整显示在 800 宽的逻辑画布内',
      );
    });

    test('初始方向向右、速度为基准速度', () {
      final ctx = buildController();
      expect(ctx.fleet.direction, 1);
      expect(ctx.fleet.speed, config.alienBaseSpeed);
    });
  });

  group('T08 大 dt / 高速度下的边界正确性', () {
    test('单次巨大 dt 只反向一次、只下移一次，并留在边界内', () {
      final ctx = buildController();
      ctx.fleet.createFleet();

      final dirBefore = ctx.fleet.direction;
      final yBefore = ctx.fleet.aliens.first.y;

      // 模拟一次严重卡顿：10 秒的步长
      ctx.fleet.update(10);

      expect(
        ctx.fleet.direction,
        -dirBefore,
        reason: '一帧只允许反转一次方向',
      );
      expect(
        ctx.fleet.aliens.first.y,
        yBefore + config.alienDropDistance,
        reason: '一帧只允许下移一次',
      );
      expect(ctx.fleet.maxX, lessThanOrEqualTo(config.logicalWidth + 1e-9));
      expect(ctx.fleet.minX, greaterThanOrEqualTo(-1e-9));
    });

    test('连续超大 dt 推进 200 帧，舰队始终留在边界内', () {
      final ctx = buildController();
      ctx.fleet.createFleet();

      for (var i = 0; i < 200; i++) {
        ctx.fleet.update(0.5);
        expect(
          ctx.fleet.maxX,
          lessThanOrEqualTo(config.logicalWidth + 1e-9),
          reason: '第 $i 帧舰队右缘越界',
        );
        expect(
          ctx.fleet.minX,
          greaterThanOrEqualTo(-1e-9),
          reason: '第 $i 帧舰队左缘越界',
        );
      }
    });

    test('高速度（高波次）下依然不越界', () {
      final ctx = buildController();
      ctx.fleet.createFleet();

      // 模拟 50 波之后的极端速度
      for (var i = 0; i < 50; i++) {
        ctx.fleet.onWaveCleared();
      }
      expect(ctx.fleet.speed, config.alienBaseSpeed + 50 * config.alienSpeedIncrement);

      for (var i = 0; i < 100; i++) {
        ctx.fleet.update(0.05);
        expect(ctx.fleet.maxX, lessThanOrEqualTo(config.logicalWidth + 1e-9));
        expect(ctx.fleet.minX, greaterThanOrEqualTo(-1e-9));
      }
    });

    test('触边后下一帧能正常离开边界（不会卡死在边界上）', () {
      final ctx = buildController();
      ctx.fleet.createFleet();

      ctx.fleet.update(10); // 触右边并反向
      final xAfterBounce = ctx.fleet.minX!;

      ctx.fleet.update(0.05); // 应向左移动
      expect(
        ctx.fleet.minX,
        lessThan(xAfterBounce),
        reason: '反向后必须真的能移动，否则会卡在边界反复掉命',
      );
    });

    test('dt 为 0 或负数时不推进', () {
      final ctx = buildController();
      ctx.fleet.createFleet();
      final x = ctx.fleet.minX;
      ctx.fleet.update(0);
      ctx.fleet.update(-1);
      expect(ctx.fleet.minX, x);
    });
  });

  group('波次与清空', () {
    test('清空一波后速度按配置递增', () {
      final ctx = buildController();
      expect(ctx.fleet.speed, 90);
      ctx.fleet.onWaveCleared();
      expect(ctx.fleet.speed, 100);
    });

    test('reset 恢复初始速度与方向', () {
      final ctx = buildController();
      ctx.fleet.createFleet();
      ctx.fleet.onWaveCleared();
      ctx.fleet.update(10); // 反向

      ctx.fleet.reset();

      expect(ctx.fleet.speed, config.alienBaseSpeed);
      expect(ctx.fleet.direction, 1);
    });

    test('clear 移除全部敌人并调用 detach', () {
      final ctx = buildController();
      ctx.fleet.createFleet();
      expect(ctx.attached.length, 35);

      ctx.fleet.clear();

      expect(ctx.fleet.alienCount, 0);
      expect(ctx.fleet.isEmpty, isTrue);
      expect(ctx.detached.length, 35);
    });

    test('removeAll 只移除指定敌人', () {
      final ctx = buildController();
      ctx.fleet.createFleet();
      final targets = ctx.fleet.aliens.take(3).toList();

      ctx.fleet.removeAll(targets);

      expect(ctx.fleet.alienCount, 32);
      expect(ctx.detached.length, 3);
      for (final target in targets) {
        expect(ctx.fleet.aliens, isNot(contains(target)));
      }
    });

    test('空舰队时 update 是安全的空操作', () {
      final ctx = buildController();
      expect(() => ctx.fleet.update(1), returnsNormally);
      expect(ctx.fleet.minX, isNull);
      expect(ctx.fleet.maxX, isNull);
    });
  });
}
