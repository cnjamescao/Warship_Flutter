// ================================================================
// components.dart —— Flame 表现组件
// ================================================================
//
// 这些类只负责"长什么样"，不包含任何规则。
// 位置、生死、碰撞全部由 FleetController / CollisionResolver /
// WarshipGame 调度（规格 §4「Components: 飞船、敌人、子弹的显示与局部数据」）。
//
// 关于 sprite 为何可空：
//   SpriteComponent 的 sprite 本身允许为 null。
//   让 sprite 可选，使得这些组件可以在**没有加载任何资源**的情况下构造，
//   从而让碰撞、边界等纯规则可以在普通单元测试里直接验证
//   —— 这是代码审查反馈 P2「把碰撞/规则抽至纯 Dart 对象」的落地方式。
// ================================================================

import 'package:flame/components.dart';

/// 玩家飞船。
class PlayerShip extends SpriteComponent {
  PlayerShip({
    required super.size,
    super.sprite,
    super.position,
    // 锚点取左上角，使 x / y 直接就是 AABB 的左上角，
    // 碰撞公式无需再做锚点换算。
    super.anchor = Anchor.topLeft,
  });
}

/// 外星敌人。
class AlienEnemy extends SpriteComponent {
  AlienEnemy({
    required super.position,
    required super.size,
    super.sprite,
    super.anchor = Anchor.topLeft,
  });
}

/// 子弹：纯色矩形，不需要图片资源（几何绘制比贴图更轻量）。
class Bullet extends RectangleComponent {
  Bullet({
    required super.position,
    required super.size,
    required super.paint,
    super.anchor = Anchor.topLeft,
  });
}
