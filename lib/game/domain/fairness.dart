// ================================================================
// lib/game/domain/fairness.dart —— 公平性可判定检查
//
// **架构位置**：Domain（纯规则） —— 无 I/O、无 Flutter 依赖、不持有渲染状态；由 `GameRuntime` 驱动，
//   产出**意图/事件**，不直接改动 Core 的实体集合。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：确定性（同 seed + 同输入必同结果）· 表现无关（不得因"要画什么"改变规则）。
// ================================================================
// 依据：产品基线 §9 AC-04
//   「每种攻击在命中前有对应预警；生成点满足 360 px 安全距离；
//     无不可躲避 Boss 循环」
//   产品设计文档 §3.3
//   「敌人与子弹生成点距玩家碰撞中心不得小于 180 逻辑像素」
//
// 「无不可躲避」是一个**可判定**的性质，把它拆成三个可计算的检查：
//
//   1. **有安全区**：伤害生效瞬间，可活动范围内存在不被覆盖的位置。
//      若某个招式覆盖全部活动范围，那它就不是"难"而是"不可能躲"。
//   2. **来得及到达**：从最不利的起始位置出发，在预警时长内按最大
//      移动速度（或一次冲刺）能抵达某个安全位置。
//   3. **不在脸上生成**：任何伤害来源的生成点与玩家的距离 ≥ 安全半径。
//
// 这三个检查都可能因为**数值配置**而失败，而不是因为实现有 bug ——
// 那正是它的价值：它把"手感问题"变成 CI 能拦住的问题。
// ================================================================

import 'dart:math' as math;

import 'values.dart';

/// 一处危险区域的抽象：以 [origin] 为顶点的几何形状。
sealed class DangerShape {
  const DangerShape({required this.origin});

  final Vec2 origin;

  /// 该点是否处于危险中。
  bool contains(Vec2 point);

  /// 在采样网格上估算被覆盖的面积占比（0–1）。
  double coverageRatio({
    required WorldBounds bounds,
    int samples = 24,
  }) {
    var inside = 0;
    var total = 0;
    for (var ix = 0; ix <= samples; ix++) {
      for (var iy = 0; iy <= samples; iy++) {
        final point = Vec2(
          bounds.minX + (bounds.maxX - bounds.minX) * ix / samples,
          bounds.minY + (bounds.maxY - bounds.minY) * iy / samples,
        );
        total++;
        if (contains(point)) {
          inside++;
        }
      }
    }
    return total == 0 ? 0 : inside / total;
  }
}

/// 扇形（Boss 扇形点射）。
class ConeDanger extends DangerShape {
  const ConeDanger({
    required super.origin,
    required this.centerAngleRadians,
    required this.halfAngleRadians,
    required this.range,
  });

  final double centerAngleRadians;
  final double halfAngleRadians;
  final double range;

  @override
  bool contains(Vec2 point) {
    final delta = point - origin;
    final distance = delta.length;
    if (distance > range || distance == 0) {
      return false;
    }
    final angle = math.atan2(delta.y, delta.x);
    var diff = angle - centerAngleRadians;
    while (diff > math.pi) {
      diff -= 2 * math.pi;
    }
    while (diff < -math.pi) {
      diff += 2 * math.pi;
    }
    return diff.abs() <= halfAngleRadians;
  }
}

/// 环形弹幕：一个圆环，但留有 [gapHalfAngleRadians] 的连续安全缺口。
class RingDanger extends DangerShape {
  const RingDanger({
    required super.origin,
    required this.gapCenterAngleRadians,
    required this.gapHalfAngleRadians,
    required this.outerRadius,
    this.innerRadius = 0,
  });

  final double gapCenterAngleRadians;
  final double gapHalfAngleRadians;
  final double outerRadius;
  final double innerRadius;

  @override
  bool contains(Vec2 point) {
    final delta = point - origin;
    final distance = delta.length;
    if (distance > outerRadius || distance < innerRadius) {
      return false;
    }
    final angle = math.atan2(delta.y, delta.x);
    var diff = angle - gapCenterAngleRadians;
    while (diff > math.pi) {
      diff -= 2 * math.pi;
    }
    while (diff < -math.pi) {
      diff += 2 * math.pi;
    }
    // 缺口内是安全的。
    return diff.abs() > gapHalfAngleRadians;
  }
}

/// 横扫激光：以 [origin] 为起点、沿扫射角度随时间推进的一条带状区域。
class SweepLaserDanger extends DangerShape {
  const SweepLaserDanger({
    required super.origin,
    required this.fromAngleRadians,
    required this.toAngleRadians,
    required this.progress,
    required this.halfWidth,
    required this.length,
  });

  final double fromAngleRadians;
  final double toAngleRadians;

  /// 扫射进度 0–1。
  final double progress;
  final double halfWidth;
  final double length;

  double get currentAngle =>
      fromAngleRadians + (toAngleRadians - fromAngleRadians) * progress;

  @override
  bool contains(Vec2 point) {
    final direction = Vec2(math.cos(currentAngle), math.sin(currentAngle));
    final delta = point - origin;
    final along = delta.x * direction.x + delta.y * direction.y;
    if (along < 0 || along > length) {
      return false;
    }
    final perpendicular =
        (delta - direction * along).length;
    return perpendicular <= halfWidth;
  }
}

/// 一次"躲得掉吗"的判定结果。
class DodgeVerdict {
  const DodgeVerdict({
    required this.attackId,
    required this.hasSafeArea,
    required this.reachableInTime,
    required this.safeAreaRatio,
    required this.requiredTravelPx,
    required this.availableTravelPx,
    this.note,
  });

  final String attackId;

  /// 伤害生效瞬间是否存在安全位置。
  final bool hasSafeArea;

  /// 在预警时长内能否从最不利位置到达安全位置。
  final bool reachableInTime;

  /// 安全区域占可活动范围的比例。
  final double safeAreaRatio;

  /// 从最不利位置到最近安全点所需的位移。
  final double requiredTravelPx;

  /// 预警时长内可用的位移（含一次冲刺）。
  final double availableTravelPx;

  final String? note;

  /// 是否可躲避。
  bool get isDodgeable => hasSafeArea && reachableInTime;

  @override
  String toString() =>
      'DodgeVerdict($attackId, dodgeable=$isDodgeable, '
      'safeArea=${(safeAreaRatio * 100).toStringAsFixed(1)}%, '
      'need=${requiredTravelPx.toStringAsFixed(0)}px / '
      'have=${availableTravelPx.toStringAsFixed(0)}px)';
}

/// 公平性分析器。
class FairnessAnalyzer {
  const FairnessAnalyzer({
    required this.moveSpeed,
    required this.dashDistance,
    required this.worldBounds,
    this.gridSamples = 32,
  });

  final double moveSpeed;

  /// 一次冲刺的固定位移（产品基线 §3.3：360 px）。
  final double dashDistance;

  final WorldBounds worldBounds;
  final int gridSamples;

  /// 分析一个招式是否可躲避。
  ///
  /// [telegraphSeconds] 是预警时长；玩家在预警期间可以移动，
  /// 并且**最多用掉一次冲刺**（冲刺 2 层、6 秒充能，
  /// 因此一次循环里按一层计是保守的）。
  DodgeVerdict analyze({
    required String attackId,
    required DangerShape danger,
    required double telegraphSeconds,
    bool dashAvailable = true,
  }) {
    // 1) 采样可活动范围，找出安全点。
    final safePoints = <Vec2>[];
    final allPoints = <Vec2>[];
    for (var ix = 0; ix <= gridSamples; ix++) {
      for (var iy = 0; iy <= gridSamples; iy++) {
        final point = Vec2(
          worldBounds.minX +
              (worldBounds.maxX - worldBounds.minX) * ix / gridSamples,
          worldBounds.minY +
              (worldBounds.maxY - worldBounds.minY) * iy / gridSamples,
        );
        allPoints.add(point);
        if (!danger.contains(point)) {
          safePoints.add(point);
        }
      }
    }

    final safeRatio = allPoints.isEmpty
        ? 0.0
        : safePoints.length / allPoints.length;

    // 2) 最不利的起始位置：**危险区内的点里离最近安全点最远的那个**。
    //    只考虑危险区内的点 —— 本来就在安全区的话没有躲避压力。
    var worstDistance = 0.0;
    var anyStartInDanger = false;
    for (final start in allPoints) {
      if (!danger.contains(start)) {
        continue;
      }
      anyStartInDanger = true;
      var nearest = double.infinity;
      for (final safe in safePoints) {
        final distance = start.distanceTo(safe);
        if (distance < nearest) {
          nearest = distance;
        }
      }
      if (nearest != double.infinity && nearest > worstDistance) {
        worstDistance = nearest;
      }
    }

    final available =
        moveSpeed * telegraphSeconds + (dashAvailable ? dashDistance : 0);

    return DodgeVerdict(
      attackId: attackId,
      hasSafeArea: safePoints.isNotEmpty,
      // 如果没有任何起始点在危险区里，那这个招式在当前几何下不构成威胁，
      // 视为可躲避（没有"必须躲"的情况）。
      reachableInTime: !anyStartInDanger || worstDistance <= available,
      safeAreaRatio: safeRatio,
      requiredTravelPx: worstDistance,
      availableTravelPx: available,
    );
  }

  /// 生成点安全距离检查（产品设计文档 §3.3：≥180 px）。
  static bool spawnIsSafe({
    required Vec2 spawnPoint,
    required Vec2 playerCenter,
    required double playerRadius,
    double minDistance = 180,
  }) => (spawnPoint - playerCenter).length >= minDistance;

  /// 产品基线 §6：敌人生成点距玩家 x 不得小于 360。
  static bool spawnPointXIsSafe({
    required double spawnX,
    required double playerX,
    double minDistance = 360,
  }) => (spawnX - playerX).abs() >= minDistance;
}
