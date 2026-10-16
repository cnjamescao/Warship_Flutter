// ================================================================
// components.dart —— Flame 表现组件
//
// **架构位置**：Game（玩法装配与对局生命周期） —— 把 Core/Domain 组装成可运行的对局，并管理对局生命周期。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：规则判定一律在 Core/Domain，本层不重复实现 · 不得绕过 Core 直接改实体。
// 本文件是 Flame 组件的组装点：
//   * 组件只读快照，不得持有或修改规则状态
//   * 新增组件时确认层级 —— 背景/预警/危险区/实体/特效/拾取物的绘制顺序是合同，有独立用例断言
//   * 任何绕过 _drawSpriteOrNull 的绘制都必须自行登记到 drawnAssetMaxRadius（我为此踩过三次，现有静态守卫）
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
