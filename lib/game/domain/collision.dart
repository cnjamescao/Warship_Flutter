// ================================================================
// lib/game/domain/collision.dart —— 碰撞层与宽相位
//
// **架构位置**：Domain（纯规则） —— 无 I/O、无 Flutter 依赖、不持有渲染状态；由 `GameRuntime` 驱动，
//   产出**意图/事件**，不直接改动 Core 的实体集合。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：确定性（同 seed + 同输入必同结果）· 表现无关（不得因"要画什么"改变规则）。
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §2.2
//   「Broad phase 使用均匀网格或等价空间索引；**不得以所有实体两两遍历**。」
//   「碰撞判定放在 Domain；Flame 的碰撞检测不得成为规则唯一来源。」
//
// 产出是 [CollisionPair]（不直接扣血）—— 由 DamageSystem 统一结算，
// 因为协议 §2.2 规定 DamageSystem 是唯一可更改 HP 的系统。
// ================================================================

import 'values.dart';

/// 碰撞层（协议 §2.2 表格的逐行对应）。
enum CollisionLayer {
  playerBody,
  playerProjectile,
  playerArea,
  enemyBody,
  bossWeakpoint,
  enemyProjectile,
  hazard,
  pickup,
}

/// 参与碰撞的一个实体。
class CollisionBody {
  const CollisionBody({
    required this.id,
    required this.layer,
    required this.center,
    required this.radius,
    this.enabled = true,
    this.isElite = false,
    this.enemyId,
    this.attackId,
  });

  final EntityId id;
  final CollisionLayer layer;
  final Vec2 center;
  final double radius;

  /// 是否参与碰撞。
  ///
  /// 冲刺无敌期间玩家 Body **仍然存在**（用于边界与表现），
  /// 但它与敌方层的配对会被过滤掉 —— 这就是"冲刺期忽略敌方伤害与阻挡"
  /// 在碰撞层的实现方式，而不是简单地把玩家移除。
  final bool enabled;

  final bool isElite;
  final String? enemyId;
  final String? attackId;

  CircleHitbox get hitbox => CircleHitbox(center, radius);

  /// 网格键：按中心点落入的格子。
  int cellKey(int cellSize) {
    final cx = (center.x / cellSize).floor();
    final cy = (center.y / cellSize).floor();
    // 逻辑世界 1920×1080，格子数远小于 65536，用位移拼键足够且无哈希开销。
    return (cx << 20) | (cy & 0xFFFFF);
  }
}

/// 一对发生重叠的实体。
class CollisionPair {
  const CollisionPair(this.a, this.b, {required this.overlap});

  final CollisionBody a;
  final CollisionBody b;

  /// 重叠深度（半径和 - 中心距），可用于表现层。
  final double overlap;

  /// 稳定排序键：保证同一帧的配对顺序确定（回放一致性）。
  int get sortKeyA => a.id.sequence * 16 + a.id.kind.index;
  int get sortKeyB => b.id.sequence * 16 + b.id.kind.index;

  @override
  String toString() => 'CollisionPair(${a.id} × ${b.id})';
}

/// 允许产生碰撞的层组合。
///
/// 键为两个层索引排序后的组合。只有列出的组合会被收集 ——
/// 例如 `enemyBody × enemyBody` 与 `playerProjectile × playerBody`
/// 都不在表中，因此永远不会产生配对。
final Set<int> _allowedPairs = <int>{
  _pairKey(CollisionLayer.playerBody, CollisionLayer.enemyBody),
  _pairKey(CollisionLayer.playerBody, CollisionLayer.enemyProjectile),
  _pairKey(CollisionLayer.playerBody, CollisionLayer.hazard),
  _pairKey(CollisionLayer.playerProjectile, CollisionLayer.enemyBody),
  _pairKey(CollisionLayer.playerProjectile, CollisionLayer.bossWeakpoint),
  _pairKey(CollisionLayer.playerArea, CollisionLayer.enemyBody),
  _pairKey(CollisionLayer.pickup, CollisionLayer.playerBody),
};

int _pairKey(CollisionLayer a, CollisionLayer b) {
  final i = a.index;
  final j = b.index;
  return i <= j ? (i << 8) | j : (j << 8) | i;
}

/// 均匀网格宽相位。
class SpatialGrid {
  SpatialGrid({this.cellSize = 96})
    : assert(cellSize > 0, '格子尺寸必须为正');

  final double cellSize;

  final Map<int, List<CollisionBody>> _cells = <int, List<CollisionBody>>{};

  /// 重建索引。每个逻辑步调用一次，避免增删实体时维护索引的开销。
  void rebuild(Iterable<CollisionBody> bodies) {
    _cells.clear();
    for (final body in bodies) {
      if (!body.enabled) {
        // 仍然入库：玩家在冲刺无敌时仍需被查询到，
        // 配对过滤在 CollisionSystem 里做，语义更集中。
      }
      final key = body.cellKey(cellSize.round());
      _cells.putIfAbsent(key, () => <CollisionBody>[]).add(body);
    }
  }

  /// 查询与给定圆可能相交的全部实体。
  ///
  /// 返回的是**候选集**，仍需精确判定；但它把 O(n²) 降到了
  /// 「每个实体 × 邻域格子内实体数」。
  List<CollisionBody> queryCircle(Vec2 center, double radius) {
    final result = <CollisionBody>[];
    final cs = cellSize.round();
    final minX = ((center.x - radius) / cs).floor();
    final maxX = ((center.x + radius) / cs).floor();
    final minY = ((center.y - radius) / cs).floor();
    final maxY = ((center.y + radius) / cs).floor();

    for (var cx = minX; cx <= maxX; cx++) {
      for (var cy = minY; cy <= maxY; cy++) {
        final bucket = _cells[(cx << 20) | (cy & 0xFFFFF)];
        if (bucket == null) {
          continue;
        }
        for (final body in bucket) {
          final dx = body.center.x - center.x;
          final dy = body.center.y - center.y;
          final reach = body.radius + radius;
          if (dx * dx + dy * dy <= reach * reach) {
            result.add(body);
          }
        }
      }
    }
    return result;
  }

  int get occupiedCellCount => _cells.length;

  void clear() => _cells.clear();
}

/// 碰撞收集器：产出确定顺序的 [CollisionPair]。
class CollisionSystem {
  CollisionSystem({SpatialGrid? grid}) : grid = grid ?? SpatialGrid();

  final SpatialGrid grid;

  /// 收集本步的全部碰撞对。
  ///
  /// [isPlayerInvulnerable] 为 true 时，玩家 Body 与敌方层的配对被跳过
  /// （产品基线 §3.3：冲刺期间忽略 EnemyBody/EnemyProjectile/Hazard）。
  List<CollisionPair> collect(
    List<CollisionBody> bodies, {
    bool isPlayerInvulnerable = false,
  }) {
    grid.rebuild(bodies);

    final pairs = <CollisionPair>[];
    final seenKeys = <int>{};

    for (final body in bodies) {
      if (!body.enabled) {
        continue;
      }
      final candidates = grid.queryCircle(body.center, body.radius);
      for (final other in candidates) {
        if (identical(other, body)) {
          continue;
        }
        if (!other.enabled) {
          continue;
        }
        if (!_allowedPairs.contains(_pairKey(body.layer, other.layer))) {
          continue;
        }

        // 无敌帧：过滤玩家与敌方层的配对。
        if (isPlayerInvulnerable && _isPlayerVersusHostile(body, other)) {
          continue;
        }

        // 去重：无向配对只保留一次，键由两端 ID 排序产生。
        final k1 = body.id.sequence * 16 + body.id.kind.index;
        final k2 = other.id.sequence * 16 + other.id.kind.index;
        final dedupeKey = k1 <= k2 ? (k1 << 32) | k2 : (k2 << 32) | k1;
        if (!seenKeys.add(dedupeKey)) {
          continue;
        }

        // 精确判定（网格只保证候选）。
        final dx = body.center.x - other.center.x;
        final dy = body.center.y - other.center.y;
        final sum = body.radius + other.radius;
        final distanceSquared = dx * dx + dy * dy;
        if (distanceSquared > sum * sum) {
          continue;
        }

        pairs.add(
          CollisionPair(
            body,
            other,
            overlap: sum - _sqrt(distanceSquared),
          ),
        );
      }
    }

    // 稳定排序：先按较大的实体序号，再按较小的 —— 保证同一帧顺序确定。
    pairs.sort((p, q) {
      final byFirst = p.sortKeyA.compareTo(q.sortKeyA);
      if (byFirst != 0) {
        return byFirst;
      }
      final bySecond = p.sortKeyB.compareTo(q.sortKeyB);
      if (bySecond != 0) {
        return bySecond;
      }
      return p.a.id.kind.index.compareTo(q.a.id.kind.index);
    });

    return pairs;
  }

  static bool _isPlayerVersusHostile(CollisionBody a, CollisionBody b) {
    bool hostile(CollisionLayer layer) =>
        layer == CollisionLayer.enemyBody ||
        layer == CollisionLayer.enemyProjectile ||
        layer == CollisionLayer.hazard;

    if (a.layer == CollisionLayer.playerBody) {
      return hostile(b.layer);
    }
    if (b.layer == CollisionLayer.playerBody) {
      return hostile(a.layer);
    }
    return false;
  }

  void reset() => grid.clear();
}

/// 小整数平方根近似：碰撞只需要比较与重叠深度，
/// 用牛顿迭代两步即可，避免每次配对调用 `math.sqrt`。
double _sqrt(double value) {
  if (value <= 0) {
    return 0;
  }
  var guess = value;
  for (var i = 0; i < 2; i++) {
    guess = 0.5 * (guess + value / guess);
  }
  return guess;
}
