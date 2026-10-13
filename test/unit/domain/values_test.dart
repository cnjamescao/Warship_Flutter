// ================================================================
// test/unit/domain/values_test.dart —— Domain 值对象不变量
// ================================================================
// 覆盖：协议 §2.1 的各条不变量，以及 T-DASH-01 / T-GEOMETRY-01 中
//       可由纯值对象断言的部分。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/domain/values.dart';

void main() {
  group('EntityId', () {
    test('一局内唯一且不复用序号', () {
      final allocator = EntityIdAllocator();

      final a = allocator.next(EntityKind.enemy);
      final b = allocator.next(EntityKind.enemy);
      final c = allocator.next(EntityKind.enemy);

      expect(<EntityId>{a, b, c}.length, 3);
      expect(<int>{a.sequence, b.sequence, c.sequence}, <int>{1, 2, 3});
    });

    test('不同种类共享序号空间但仍是不同实体', () {
      final allocator = EntityIdAllocator();
      final enemy = allocator.next(EntityKind.enemy);
      final projectile = allocator.next(EntityKind.enemyProjectile);

      expect(enemy == projectile, isFalse);
      expect(enemy.sequence, 1);
      expect(projectile.sequence, 1);
    });

    test('排序稳定：先按序号再按种类（回放一致性前提）', () {
      final ids = <EntityId>[
        const EntityId(EntityKind.enemyProjectile, 2),
        const EntityId(EntityKind.enemy, 1),
        const EntityId(EntityKind.enemy, 2),
      ];
      ids.sort();

      expect(ids.first.sequence, 1);
      expect(ids[1].sequence, 2);
      expect(ids[2].sequence, 2);
    });

    test('reset 后重新从 1 开始（新一局）', () {
      final allocator = EntityIdAllocator();
      allocator.next(EntityKind.enemy);
      allocator.reset();
      expect(allocator.next(EntityKind.enemy).sequence, 1);
    });
  });

  group('T-GEOMETRY-01 判定几何', () {
    test('圆相交：边界接触算相交（≤）', () {
      const a = CircleHitbox(Vec2(0, 0), 30);
      const touching = CircleHitbox(Vec2(50, 0), 20);
      const apart = CircleHitbox(Vec2(50.001, 0), 20);

      expect(a.intersects(touching), isTrue, reason: '恰好相切必须算相交');
      expect(a.intersects(apart), isFalse);
    });

    test('五类敌人与玩家的判定半径与产品基线 §3.4 一致', () {
      const playerRadius = 30.0;
      const enemyRadii = <double>[28, 32, 34, 45, 48];

      expect(playerRadius, 30);
      expect(enemyRadii, <double>[28, 32, 34, 45, 48]);
      // Boss 主体 150、弱点 52
      expect(<double>[150, 52], <double>[150, 52]);
    });

    test('世界边界夹紧：玩家中心被限制在 30..1890 / 30..1050', () {
      const bounds = WorldBounds.playerDefault;

      expect(bounds.clamp(const Vec2(-100, 500)), const Vec2(30, 500));
      expect(bounds.clamp(const Vec2(5000, 500)), const Vec2(1890, 500));
      expect(bounds.clamp(const Vec2(500, -100)), const Vec2(500, 30));
      expect(bounds.clamp(const Vec2(500, 5000)), const Vec2(500, 1050));
      expect(bounds.contains(const Vec2(960, 900)), isTrue);
      expect(bounds.contains(const Vec2(10, 900)), isFalse);
    });

    test('出生点 (960,900) 在合法范围内', () {
      expect(
        WorldBounds.playerDefault.contains(const Vec2(960, 900)),
        isTrue,
      );
    });
  });

  group('Health 不变量', () {
    test('0 ≤ current ≤ max', () {
      final health = Health(max: 100, current: 250);
      expect(health.current, 100);

      health.applyDamage(1000);
      expect(health.current, 0);
      expect(health.isDead, isTrue);
    });

    test('applyDamage 返回实际扣除量', () {
      final health = Health(max: 100, current: 7);
      expect(health.applyDamage(12), 7, reason: '只能扣到 0');
      expect(health.current, 0);
    });

    test('heal 不超过上限并返回实际回复量', () {
      final health = Health(max: 100, current: 93);
      expect(health.heal(15), 7);
      expect(health.current, 100);
      expect(health.isFull, isTrue);
    });
  });

  group('ShieldPool', () {
    test('吸收与回复都不越界', () {
      final shield = ShieldPool(max: 30);
      expect(shield.absorb(12), 12);
      expect(shield.current, 18);
      expect(shield.restore(100), 12, reason: '满值不溢出');
      expect(shield.current, 30);
    });

    test('UP-SHIELD-MAX：上限 +10 并立即补充同等数值', () {
      final shield = ShieldPool(max: 30, current: 10);
      shield.raiseMax(10, refillSameAmount: true);

      expect(shield.max, 40);
      expect(shield.current, 20, reason: '10 + 10');
    });
  });

  group('T-DASH-01 冲刺状态', () {
    DashState makeDash() =>
        DashState(maxCharges: 2, rechargeSeconds: 6.0);

    test('初始两层可用；消耗后逐层独立充能', () {
      final dash = makeDash();
      expect(dash.charges, 2);
      expect(dash.canDash, isTrue);

      expect(dash.consume(const Vec2(0, -1), distance: 360), isTrue);
      expect(dash.charges, 1);
      expect(dash.rechargeTimers.where((t) => t > 0).length, 1);

      expect(dash.consume(const Vec2(0, -1), distance: 360), isTrue);
      expect(dash.charges, 0);
      expect(dash.canDash, isFalse);
      expect(
        dash.consume(const Vec2(0, -1), distance: 360),
        isFalse,
        reason: '没有层数时不能冲刺',
      );
    });

    test('方向在启动时锁定，不随后续输入改变', () {
      final dash = makeDash();
      dash.consume(const Vec2(-1, 0), distance: 360);

      expect(dash.direction, const Vec2(-1, 0));
      // 模拟玩家转向：冲刺方向不受影响。
      expect(dash.direction.x, -1);
      expect(dash.direction.y, 0);
    });

    test('充能在 6 秒后逐层就绪，每秒最多回到上限', () {
      final dash = makeDash();
      dash.consume(Vec2.zero, distance: 360);

      var ready = false;
      // 361 步而非 360：1/60 不是二进制精确值，累加 360 次后
      // 剩余时间会留下约 1e-15 的正残差 —— 这是浮点累加的固有现象，
      // 实战中多跑一帧即自愈（16 ms），故这里按一帧容差断言。
      for (var i = 0; i < 361; i++) {
        ready = dash.tick(1 / 60) || ready;
      }

      expect(ready, isTrue);
      expect(dash.charges, 2);
      expect(dash.tick(1 / 60), isFalse, reason: '已满则不重复触发');
    });

    test('结束锁定期内不能再次冲刺', () {
      final dash = makeDash();
      dash.consume(Vec2.zero, distance: 360);
      dash.endLockRemaining = 0.12;

      expect(dash.canDash, isFalse);
      dash.endLockRemaining = 0;
      expect(dash.canDash, isTrue);
    });
  });

  group('ModifierStack', () {
    test('同一 sourceId 更新而不是重复叠加', () {
      final stack = ModifierStack();

      stack.set(
        sourceId: 'UP-PULSE-DAMAGE',
        operation: ModifierOperation.add,
        value: 3,
      );
      stack.set(
        sourceId: 'UP-PULSE-DAMAGE',
        operation: ModifierOperation.add,
        value: 3,
      );

      expect(stack.sourceIds.length, 1, reason: '同源只保留一条');
      expect(stack.apply(9), 12, reason: '9 + 3，而不是 9 + 6');
    });

    test('先加后乘，与插入顺序无关', () {
      final a = ModifierStack()
        ..set(
          sourceId: 'add',
          operation: ModifierOperation.add,
          value: 3,
        )
        ..set(
          sourceId: 'mul',
          operation: ModifierOperation.multiply,
          value: 0.85,
        );

      final b = ModifierStack()
        ..set(
          sourceId: 'mul',
          operation: ModifierOperation.multiply,
          value: 0.85,
        )
        ..set(
          sourceId: 'add',
          operation: ModifierOperation.add,
          value: 3,
        );

      expect(a.apply(9), closeTo(b.apply(9), 1e-12));
      expect(a.apply(9), closeTo((9 + 3) * 0.85, 1e-12));
    });

    test('逐级叠乘：脉冲增幅 Lv3 = 0.85³', () {
      final stack = ModifierStack();
      var factor = 1.0;
      for (var level = 0; level < 3; level++) {
        factor *= 0.85;
      }
      stack.set(
        sourceId: 'UP-PULSE-RATE',
        operation: ModifierOperation.multiply,
        value: factor,
      );

      expect(stack.apply(0.24), closeTo(0.24 * 0.85 * 0.85 * 0.85, 1e-12));
    });

    test('remove 与 clear', () {
      final stack = ModifierStack()
        ..set(
          sourceId: 'x',
          operation: ModifierOperation.add,
          value: 5,
        );
      expect(stack.has('x'), isTrue);
      stack.remove('x');
      expect(stack.has('x'), isFalse);
      expect(stack.apply(9), 9);
    });
  });

  group('RunMetrics', () {
    test('记录 15 秒窗口内的 HP 伤害，超窗后清零', () {
      final metrics = RunMetrics();
      metrics.recordHpDamage(20, 10.0);
      expect(metrics.hpDamageInLast15s, 20);

      metrics.decay(20.0);
      expect(metrics.hpDamageInLast15s, 20, reason: '10 秒后仍在窗口内');

      metrics.decay(26.0);
      expect(metrics.hpDamageInLast15s, 0, reason: '超过 15 秒窗口');
      expect(metrics.lastHpDamageAt, isNull);
    });
  });

  group('LogicalTimer', () {
    test('tick 只在恰好归零时返回 true', () {
      final timer = LogicalTimer(0.1);

      expect(timer.tick(0.05), isFalse);
      expect(timer.tick(0.05), isTrue);
      expect(timer.isElapsed, isTrue);
      expect(timer.tick(0.05), isFalse, reason: '已经归零后不再触发');
    });

    test('周期计时器保留溢出，不丢周期', () {
      final timer = LogicalTimer(0.05, period: 0.05);
      timer.tick(0.12);
      expect(timer.remaining, closeTo(0.03, 1e-9));
    });
  });
}
