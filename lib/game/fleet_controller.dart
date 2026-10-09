// ================================================================
// fleet_controller.dart —— 舰队生成、边界与推进
// ================================================================
//
// 规格要求（Warship产品设计.md §3.3 [修订]）：
//   「舰队不得"越界后只反向"。每帧按此顺序处理：
//     1. 计算整队左/右边界与目标横向位移；
//     2. 若目标越界，把整队移动到恰好接触边界；
//     3. 只反转一次方向并下移一次；
//     4. 否则应用目标位移；
//     5. 再判定碰撞和底边。」
//
// 旧实现的缺陷（代码审查反馈 P2）：
//   敌人先移动，再「仅反转方向 + 下移」，没有把越界的 x 夹回合法范围。
//   高速度或大 dt 时舰队会明显穿出屏幕；
//   而越界状态下每一帧都会再次触发"触边"，导致舰队连续下移、快速掉命。
// ================================================================

import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:warship_flutter/game/components.dart';
import 'package:warship_flutter/game/game_config.dart';

/// 把敌人加入 Flame 组件树。
typedef AlienAttach = void Function(AlienEnemy alien);

/// 把敌人从 Flame 组件树移除。
typedef AlienDetach = void Function(AlienEnemy alien);

/// 一次舰队横向移动的裁决结果。
///
/// 抽成纯数据是为了让最容易出错的边界数学可以被直接单元测试，
/// 不需要搭建 Flame 组件树。
class FleetMovePlan {
  const FleetMovePlan({required this.appliedDelta, required this.hitBoundary});

  /// 本帧真正应用的横向位移。
  final double appliedDelta;

  /// 本帧是否触碰到边界（触碰后调用方应反转方向并下移一次）。
  final bool hitBoundary;
}

/// 纯函数：计算舰队本帧可用的横向位移。
///
/// 核心思路是"先把想要的位移削到刚好贴住边界"，
/// 这样舰队永远不会跑到画布外面，也就不存在
/// "越界 → 每帧都判定触边 → 连续下移"的连锁问题。
FleetMovePlan planFleetMove({
  required double desiredDelta,
  required double fleetMinX,
  required double fleetMaxX,
  required double worldWidth,
}) {
  if (desiredDelta > 0) {
    // 向右：可移动空间 = 画布右边界 - 舰队最右边缘
    final room = worldWidth - fleetMaxX;
    if (desiredDelta > room) {
      return FleetMovePlan(
        appliedDelta: room > 0 ? room : 0,
        hitBoundary: true,
      );
    }
  } else if (desiredDelta < 0) {
    // 向左：可移动空间 = 舰队最左边缘到画布左边界
    final room = fleetMinX;
    if (-desiredDelta > room) {
      return FleetMovePlan(
        appliedDelta: room > 0 ? -room : 0,
        hitBoundary: true,
      );
    }
  }
  return FleetMovePlan(appliedDelta: desiredDelta, hitBoundary: false);
}

/// 舰队控制器：生成、推进、边界裁决。
///
/// 通过 [attach] / [detach] 回调与 Flame 组件树交互，
/// 因此本类自身不依赖组件树的挂载状态，可以在纯单元测试中使用。
class FleetController {
  FleetController({
    required this.config,
    required this.attach,
    required this.detach,
  }) : _speed = config.alienBaseSpeed;

  final GameConfig config;

  /// 把敌人挂到 Flame 组件树上的回调。
  final AlienAttach attach;

  /// 把敌人从 Flame 组件树摘除的回调。
  final AlienDetach detach;

  /// 敌人精灵，由游戏在资源加载完成后注入。
  /// 允许为 null —— 这样测试可以构造没有贴图的舰队来验证规则。
  Sprite? sprite;

  final List<AlienEnemy> _aliens = <AlienEnemy>[];

  double _speed;
  double _direction = 1;

  /// 当前横向速度（px/s）。
  double get speed => _speed;

  /// 当前推进方向：1 向右，-1 向左。
  double get direction => _direction;

  /// 场上敌人（只读视图）。
  List<AlienEnemy> get aliens => List<AlienEnemy>.unmodifiable(_aliens);

  int get alienCount => _aliens.length;
  bool get isEmpty => _aliens.isEmpty;

  /// 生成一整队敌人，并按 `行 × 列` 均匀排布。
  ///
  /// 行列数由 [GameConfig] 依逻辑画布尺寸推导（默认 800×600 → 7 列 × 5 行）。
  void createFleet() {
    final columns = config.fleetColumns;
    final rows = config.fleetRows;
    final alienSize = Vector2(config.alienWidth, config.alienHeight);

    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        // 每个敌人占 2 倍尺寸（一个敌人 + 一个间隙）
        final alien = AlienEnemy(
          sprite: sprite,
          position: Vector2(
            config.alienWidth + 2 * config.alienWidth * column,
            config.alienHeight + 2 * config.alienHeight * row,
          ),
          size: alienSize.clone(),
        );
        _aliens.add(alien);
        attach(alien);
      }
    }
  }

  /// 推进一帧。
  ///
  /// 严格按规格 §3.3 的顺序：计算边界 → 夹位/位移 → 触边则反向并下移一次。
  void update(double dt) {
    if (_aliens.isEmpty || dt <= 0) {
      return;
    }

    // 1. 计算整队边界
    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    for (final alien in _aliens) {
      if (alien.x < minX) {
        minX = alien.x;
      }
      final right = alien.x + alien.width;
      if (right > maxX) {
        maxX = right;
      }
    }

    // 2. 计算目标位移并裁决是否越界
    final desired = _speed * _direction * dt;
    final plan = planFleetMove(
      desiredDelta: desired,
      fleetMinX: minX,
      fleetMaxX: maxX,
      worldWidth: config.logicalWidth,
    );

    // 3. 应用（可能被削减过的）位移
    if (plan.appliedDelta != 0) {
      for (final alien in _aliens) {
        alien.x += plan.appliedDelta;
      }
    }

    // 4. 触边：只反转一次方向、只下移一次
    if (plan.hitBoundary) {
      _direction = -_direction;
      for (final alien in _aliens) {
        alien.y += config.alienDropDistance;
      }
    }
  }

  /// 清空一波后的难度提升。
  void onWaveCleared() {
    _speed += config.alienSpeedIncrement;
  }

  /// 恢复到初始速度与方向（开新局时调用）。
  void reset() {
    _speed = config.alienBaseSpeed;
    _direction = 1;
  }

  /// 移除指定的敌人（碰撞结算后调用）。
  void removeAll(Iterable<AlienEnemy> targets) {
    for (final alien in targets) {
      detach(alien);
      _aliens.remove(alien);
    }
  }

  /// 移除场上全部敌人。
  void clear() {
    for (final alien in _aliens) {
      detach(alien);
    }
    _aliens.clear();
  }

  /// 当前舰队最左 / 最右边缘（无敌人时返回 null），主要用于测试与调试。
  double? get minX {
    if (_aliens.isEmpty) {
      return null;
    }
    var value = double.infinity;
    for (final alien in _aliens) {
      value = math.min(value, alien.x);
    }
    return value;
  }

  double? get maxX {
    if (_aliens.isEmpty) {
      return null;
    }
    var value = double.negativeInfinity;
    for (final alien in _aliens) {
      value = math.max(value, alien.x + alien.width);
    }
    return value;
  }
}
