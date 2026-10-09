// ================================================================
// test/unit/collision_resolver_test.dart —— 唯一命中与伤害裁决
// ================================================================
// 覆盖规格 §5 [新增，P1]「碰撞须用集合或等价唯一标记」
// 与验收项 T03（两颗子弹同帧命中同一敌人只加 50 分）。
//
// 旧实现的缺陷：内层循环没有跳过已被标记的敌人，
// 于是两颗重叠的子弹可以各自把同一个敌人加入待删除列表，
// 分数按列表长度计算 → 同一个敌人被计了双倍分。
// ================================================================

import 'dart:ui' show Paint;

import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/collision_resolver.dart';
import 'package:warship_flutter/game/components.dart';
import 'package:warship_flutter/game/game_config.dart';

void main() {
  const config = GameConfig();
  const resolver = CollisionResolver(config: config);

  AlienEnemy alienAt(double x, double y) =>
      AlienEnemy(position: Vector2(x, y), size: Vector2(config.alienWidth, config.alienHeight));

  Bullet bulletAt(double x, double y) => Bullet(
    position: Vector2(x, y),
    size: Vector2(config.bulletWidth, config.bulletHeight),
    paint: Paint(),
  );

  /// 飞船放在底部中央，远离默认的舰队位置。
  PlayerShip parkedShip() => PlayerShip(
    position: Vector2((config.logicalWidth - config.shipWidth) / 2, config.shipStartY),
    size: Vector2(config.shipWidth, config.shipHeight),
  );

  group('AABB 判定', () {
    test('部分重叠算命中', () {
      final a = alienAt(100, 100);
      final b = bulletAt(110, 110);
      expect(CollisionResolver.overlaps(a, b), isTrue);
      expect(CollisionResolver.overlaps(b, a), isTrue);
    });

    test('仅边缘接触不算命中', () {
      // b 的左边缘正好等于 a 的右边缘
      final a = alienAt(100, 100);
      final b = bulletAt(100 + config.alienWidth, 100);
      expect(CollisionResolver.overlaps(a, b), isFalse);
    });

    test('完全分离不算命中', () {
      expect(
        CollisionResolver.overlaps(alienAt(0, 0), bulletAt(500, 500)),
        isFalse,
      );
    });
  });

  group('T03 唯一命中', () {
    test('两颗子弹同帧命中同一敌人：只移除一次，只计 50 分', () {
      final alien = alienAt(100, 100);
      // 两颗子弹都覆盖同一个敌人
      final bulletA = bulletAt(105, 105);
      final bulletB = bulletAt(120, 110);

      final outcome = resolver.resolve(
        bullets: <Bullet>[bulletA, bulletB],
        aliens: <AlienEnemy>[alien],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(
        outcome.aliensToRemove.length,
        1,
        reason: '同一个敌人一帧只能被结算一次（旧实现会得到 2）',
      );
      expect(outcome.aliensToRemove, contains(alien));
      expect(
        (outcome.aliensToRemove.length * config.alienPoints).round(),
        50,
        reason: '计分必须基于唯一击毁数量',
      );
    });

    test('已被标记的敌人不再参与判定：第二颗子弹不被消耗', () {
      // 规格 §5 的伪代码是 "for each unmarked alien"：
      // 一旦某个敌人在本帧已被标记，它就退出后续子弹的判定，
      // 因此第二颗子弹既不会被消耗，也不会重复计分。
      final alien = alienAt(100, 100);
      final bulletA = bulletAt(105, 105);
      final bulletB = bulletAt(120, 110);

      final outcome = resolver.resolve(
        bullets: <Bullet>[bulletA, bulletB],
        aliens: <AlienEnemy>[alien],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.bulletsToRemove, contains(bulletA));
      expect(
        outcome.bulletsToRemove,
        isNot(contains(bulletB)),
        reason: '目标已被标记，第二颗子弹继续飞行',
      );
      expect(outcome.aliensToRemove.length, 1);
    });

    test('三颗子弹命中同一敌人，仍然只计 50 分', () {
      final alien = alienAt(100, 100);
      final outcome = resolver.resolve(
        bullets: <Bullet>[
          bulletAt(101, 101),
          bulletAt(110, 105),
          bulletAt(120, 120),
        ],
        aliens: <AlienEnemy>[alien],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.aliensToRemove.length, 1);
      expect(
        (outcome.aliensToRemove.length * config.alienPoints).round(),
        50,
      );
    });

    test('第二颗子弹可以命中另一个未被标记的敌人', () {
      // 两个敌人纵向部分重叠：alienA(y 100-140) 与 alienB(y 92-132)。
      // 两颗子弹同时压住两者，因此：
      //   子弹 1 → 命中列表里第一个未标记的 alienA 并标记它；
      //   子弹 2 → 跳过已标记的 alienA，转而结算仍未标记的 alienB。
      final alienA = alienAt(100, 100);
      final alienB = alienAt(100, 92);

      final outcome = resolver.resolve(
        bullets: <Bullet>[bulletAt(105, 108), bulletAt(105, 104)],
        aliens: <AlienEnemy>[alienA, alienB],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.aliensToRemove, contains(alienA));
      expect(
        outcome.aliensToRemove,
        contains(alienB),
        reason: 'A 被标记后，子弹仍可结算尚未标记的 B',
      );
      expect(outcome.aliensToRemove.length, 2);
      expect((outcome.aliensToRemove.length * config.alienPoints).round(), 100);
    });

    test('两颗子弹命中两个不同敌人：各得 50 分（共 100）', () {
      final alienA = alienAt(100, 100);
      final alienB = alienAt(400, 100);

      final outcome = resolver.resolve(
        bullets: <Bullet>[bulletAt(105, 105), bulletAt(405, 105)],
        aliens: <AlienEnemy>[alienA, alienB],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.aliensToRemove.length, 2);
      expect((outcome.aliensToRemove.length * config.alienPoints).round(), 100);
    });

    test('一颗子弹只命中一个敌人（即使同时覆盖两个）', () {
      // 两个敌人位置非常接近，一颗子弹同时压住两者
      final alienA = alienAt(100, 100);
      final alienB = alienAt(104, 100);

      final outcome = resolver.resolve(
        bullets: <Bullet>[bulletAt(106, 100)],
        aliens: <AlienEnemy>[alienA, alienB],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.aliensToRemove.length, 1);
      expect(outcome.bulletsToRemove.length, 1);
    });

    test('没有命中的子弹不会被移除', () {
      final outcome = resolver.resolve(
        bullets: <Bullet>[bulletAt(10, 10)],
        aliens: <AlienEnemy>[alienAt(400, 300)],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.bulletsToRemove, isEmpty);
      expect(outcome.hasKills, isFalse);
    });

    test('结算器不修改传入的集合（纯规则对象）', () {
      final bullets = <Bullet>[bulletAt(105, 105)];
      final aliens = <AlienEnemy>[alienAt(100, 100)];

      resolver.resolve(
        bullets: bullets,
        aliens: aliens,
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(bullets.length, 1);
      expect(aliens.length, 1);
    });
  });

  group('伤害裁决', () {
    test('飞船撞到敌人 → 受伤', () {
      final ship = parkedShip();
      final colliding = alienAt(ship.x + 10, ship.y + 10);

      final outcome = resolver.resolve(
        bullets: const <Bullet>[],
        aliens: <AlienEnemy>[colliding, alienAt(0, 0)],
        ship: ship,
        worldHeight: config.logicalHeight,
      );

      expect(outcome.shipDamaged, isTrue);
    });

    test('敌人触底 → 受伤', () {
      final outcome = resolver.resolve(
        bullets: const <Bullet>[],
        aliens: <AlienEnemy>[
          alienAt(0, config.logicalHeight - config.alienHeight),
        ],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.shipDamaged, isTrue);
    });

    test('敌人还没到底、也没撞船 → 不受伤', () {
      final outcome = resolver.resolve(
        bullets: const <Bullet>[],
        aliens: <AlienEnemy>[alienAt(0, 0), alienAt(100, 0)],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.shipDamaged, isFalse);
      expect(outcome.fleetCleared, isFalse);
    });

    test('清空舰队的同一帧不判伤害（避免"清屏奖励"瞬间掉命）', () {
      final ship = parkedShip();
      // 这个敌人同时压着飞船、又会被子弹击毁
      final doomed = alienAt(ship.x + 10, ship.y + 10);

      final outcome = resolver.resolve(
        bullets: <Bullet>[bulletAt(ship.x + 12, ship.y + 12)],
        aliens: <AlienEnemy>[doomed],
        ship: ship,
        worldHeight: config.logicalHeight,
      );

      expect(outcome.hasKills, isTrue);
      expect(outcome.fleetCleared, isTrue);
      expect(
        outcome.shipDamaged,
        isFalse,
        reason: '舰队已清空时本帧由调用方生成新一波，不应扣命',
      );
    });

    test('舰队清空但仍有存活敌人时，正常判定伤害', () {
      final ship = parkedShip();
      final doomed = alienAt(0, 0);
      final survivorOnShip = alienAt(ship.x + 5, ship.y + 5);

      final outcome = resolver.resolve(
        bullets: <Bullet>[bulletAt(2, 2)],
        aliens: <AlienEnemy>[doomed, survivorOnShip],
        ship: ship,
        worldHeight: config.logicalHeight,
      );

      expect(outcome.aliensToRemove, contains(doomed));
      expect(outcome.fleetCleared, isFalse);
      expect(outcome.shipDamaged, isTrue);
    });

    test('没有敌人时不受伤、不清空', () {
      final outcome = resolver.resolve(
        bullets: const <Bullet>[],
        aliens: const <AlienEnemy>[],
        ship: parkedShip(),
        worldHeight: config.logicalHeight,
      );

      expect(outcome.shipDamaged, isFalse);
      expect(outcome.fleetCleared, isTrue, reason: '空舰队等价于已清空');
    });
  });
}
