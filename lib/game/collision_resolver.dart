// ================================================================
// collision_resolver.dart —— 碰撞检测与伤害裁决
// ================================================================
//
// 规格要求（Warship产品设计.md §5）：
//   「碰撞须用集合或等价唯一标记：
//     bulletsToRemove = Set<Bullet>()
//     aliensToRemove = Set<AlienEnemy>()
//     for each bullet:
//       for each unmarked alien:
//         if overlaps: mark bullet and alien; break
//     remove each marked entity once
//     score += aliensToRemove.length * alienPoints
//     不得以"重复移除通常无害"为理由接受重复计分。」
//
// 旧实现的缺陷（代码审查反馈 P1）：
//   内层循环只保证"一颗子弹只命中一个敌人"，
//   却没有跳过已经被别的子弹标记过的敌人。
//   于是两颗重叠的子弹可以各自把同一个敌人加入列表，
//   分数按列表长度计算 → 同一个敌人被计了两次分（100 分）。
// ================================================================

import 'package:flame/components.dart';
import 'package:warship_flutter/game/components.dart';
import 'package:warship_flutter/game/game_config.dart';

/// 一帧碰撞结算的完整结果。
class CollisionOutcome {
  const CollisionOutcome({
    this.bulletsToRemove = const <Bullet>{},
    this.aliensToRemove = const <AlienEnemy>{},
    this.shipDamaged = false,
    this.fleetCleared = false,
  });

  /// 本帧需要移除的子弹（集合，天然去重）。
  final Set<Bullet> bulletsToRemove;

  /// 本帧需要移除的敌人（集合，天然去重）。
  ///
  /// 计分必须使用 `aliensToRemove.length` —— 它等于"唯一被击毁的敌人数量"。
  final Set<AlienEnemy> aliensToRemove;

  /// 飞船是否应当在本次结算中掉一条命。
  final bool shipDamaged;

  /// 结算后舰队是否已被清空。
  ///
  /// 为 true 时本帧不判伤害，调用方应生成更快的新一波（规格 §5 流程图）。
  final bool fleetCleared;

  bool get hasKills => aliensToRemove.isNotEmpty;
}

/// AABB 碰撞与伤害裁决器。
///
/// 纯规则对象：不持有任何组件，也不修改组件树，
/// 只做判定并返回"谁该被移除、飞船是否受伤"。
class CollisionResolver {
  const CollisionResolver({required this.config});

  final GameConfig config;

  /// 轴对齐包围盒（AABB）重叠判定。
  ///
  /// 两个矩形不重叠的条件是下列任一成立：
  ///   a 完全在 b 左侧 / a 完全在 b 右侧 / a 完全在 b 上方 / a 完全在 b 下方。
  /// 因此"重叠"= 四个条件同时不成立。
  ///
  /// 由于双方都使用 [Anchor.topLeft]，`x` / `y` 就是左上角，无需锚点换算。
  static bool overlaps(PositionComponent a, PositionComponent b) {
    return a.x < b.x + b.width &&
        a.x + a.width > b.x &&
        a.y < b.y + b.height &&
        a.y + a.height > b.y;
  }

  /// 结算一帧的全部碰撞。
  ///
  /// 顺序严格按规格 §5 流程图：
  ///   1. 子弹 × 敌人（唯一命中）
  ///   2. 判断舰队是否已清空
  ///   3. 未清空时才裁决飞船撞击 / 敌人触底
  CollisionOutcome resolve({
    required Iterable<Bullet> bullets,
    required Iterable<AlienEnemy> aliens,
    required PositionComponent ship,
    required double worldHeight,
  }) {
    final alienList = aliens.toList(growable: false);
    final bulletsToRemove = <Bullet>{};
    final aliensToRemove = <AlienEnemy>{};

    // ---- 1. 子弹 × 敌人：唯一命中 ----
    for (final bullet in bullets) {
      for (final alien in alienList) {
        // 关键修复：已被本帧其他子弹标记的敌人直接跳过，
        // 保证"一个敌人一帧最多被销毁、计分一次"。
        if (aliensToRemove.contains(alien)) {
          continue;
        }
        if (overlaps(bullet, alien)) {
          bulletsToRemove.add(bullet);
          aliensToRemove.add(alien);
          break; // 一颗子弹最多命中一个敌人
        }
      }
    }

    // ---- 2. 击毁结算后，舰队还剩谁 ----
    final survivors = <AlienEnemy>[];
    for (final alien in alienList) {
      if (!aliensToRemove.contains(alien)) {
        survivors.add(alien);
      }
    }
    final fleetCleared = survivors.isEmpty;

    // ---- 3. 伤害裁决 ----
    // 舰队已清空时不判伤害：调用方会立刻生成新一波，
    // 否则玩家会在"清屏奖励"的瞬间莫名掉命。
    var shipDamaged = false;
    if (!fleetCleared) {
      for (final alien in survivors) {
        if (overlaps(ship, alien)) {
          shipDamaged = true;
          break;
        }
      }
      if (!shipDamaged) {
        for (final alien in survivors) {
          if (alien.y + alien.height >= worldHeight) {
            shipDamaged = true;
            break;
          }
        }
      }
    }

    return CollisionOutcome(
      bulletsToRemove: bulletsToRemove,
      aliensToRemove: aliensToRemove,
      shipDamaged: shipDamaged,
      fleetCleared: fleetCleared,
    );
  }
}
