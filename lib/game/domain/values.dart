// ================================================================
// lib/game/domain/values.dart —— Domain 值对象
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §2.1
//
// 硬约束（技术架构 §1）：
//   `domain` 禁止 import Flutter、Flame、音频插件、文件系统或 Widget。
//   因此本文件只有 dart:math 依赖，可以在纯 Dart 测试里驱动。
//
// 坐标约定（产品基线 §3.4）：
//   所有战斗坐标使用**实体中心**；逻辑世界 1920×1080，原点左上，Y 轴向下。
// ================================================================

import 'dart:math' as math;

/// 实体种类。用于 [EntityId] 与渲染层区分。
enum EntityKind {
  player,
  enemy,
  boss,
  bossWeakpoint,
  playerProjectile,
  enemyProjectile,
  hazard,
  pickup,
  drone,
}

/// 一局内唯一的实体标识。
///
/// 不变量：一局内唯一、**不复用**。
/// 排序规则固定为 `sequence` 再 `kind`，协议 §3 要求同帧事件按
/// 系统顺序再按实体 ID 排序，以确定性为前提。
final class EntityId implements Comparable<EntityId> {
  const EntityId(this.kind, this.sequence);

  final EntityKind kind;
  final int sequence;

  @override
  int compareTo(EntityId other) {
    if (sequence != other.sequence) {
      return sequence.compareTo(other.sequence);
    }
    return kind.index.compareTo(other.kind.index);
  }

  @override
  bool operator ==(Object other) =>
      other is EntityId && other.kind == kind && other.sequence == sequence;

  @override
  int get hashCode => Object.hash(kind, sequence);

  @override
  String toString() => '${kind.name}#$sequence';
}

/// 一局内单调递增的 ID 分配器。**不复用**已分配的序号。
class EntityIdAllocator {
  final Map<EntityKind, int> _next = <EntityKind, int>{};

  EntityId next(EntityKind kind) {
    final sequence = _next[kind] ?? 1;
    _next[kind] = sequence + 1;
    return EntityId(kind, sequence);
  }

  void reset() => _next.clear();
}

/// 不可变二维向量（logical px）。
final class Vec2 {
  const Vec2(this.x, this.y);

  static const Vec2 zero = Vec2(0, 0);

  final double x;
  final double y;

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double scalar) => Vec2(x * scalar, y * scalar);

  double get length => math.sqrt(x * x + y * y);
  double get lengthSquared => x * x + y * y;

  /// 单位化；零向量返回 [Vec2.zero]（调用方需自行决定回退方向）。
  Vec2 get normalized {
    final len = length;
    return len == 0 ? zero : Vec2(x / len, y / len);
  }

  double distanceTo(Vec2 other) => (this - other).length;
  double distanceSquaredTo(Vec2 other) => (this - other).lengthSquared;

  Vec2 copyWith({double? x, double? y}) => Vec2(x ?? this.x, y ?? this.y);

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => '(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// 圆形判定体。
///
/// 产品基线 §3.4 的全部战斗判定都是圆（或圆 + 正面锥），
/// 相交判定固定为「中心距离 ≤ r1 + r2」。
final class CircleHitbox {
  const CircleHitbox(this.center, this.radius)
    : assert(radius > 0, '半径必须大于 0');

  final Vec2 center;
  final double radius;

  /// 两圆是否相交。**边界接触算相交**（`≤`，协议 §2.2）。
  bool intersects(CircleHitbox other) =>
      center.distanceSquaredTo(other.center) <=
      (radius + other.radius) * (radius + other.radius);

  CircleHitbox movedTo(Vec2 newCenter) => CircleHitbox(newCenter, radius);
}

/// 轴对齐包围盒（协议 §2.1 的 `Bounds`）。
final class Bounds {
  const Bounds({
    required this.center,
    required this.halfWidth,
    required this.halfHeight,
  }) : assert(halfWidth > 0 && halfHeight > 0, '尺寸必须大于 0');

  final Vec2 center;
  final double halfWidth;
  final double halfHeight;

  double get minX => center.x - halfWidth;
  double get maxX => center.x + halfWidth;
  double get minY => center.y - halfHeight;
  double get maxY => center.y + halfHeight;

  bool intersects(Bounds other) =>
      minX <= other.maxX &&
      maxX >= other.minX &&
      minY <= other.maxY &&
      maxY >= other.minY;
}

/// 生命值，恒满足 `0 ≤ current ≤ max`。
final class Health {
  Health({required this.max, int? current})
    : assert(max > 0, 'max 必须为正'),
      current = (current ?? max).clamp(0, max);

  final int max;
  int current;

  bool get isDead => current <= 0;
  bool get isFull => current >= max;
  double get ratio => max == 0 ? 0 : current / max;

  /// 扣血并返回**实际**扣除量（不会低于 0）。
  int applyDamage(int rawDamage) {
    if (rawDamage <= 0) {
      return 0;
    }
    final applied = math.min(rawDamage, current);
    current -= applied;
    return applied;
  }

  /// 治疗并返回**实际**回复量（不超过 max）。
  int heal(int amount) {
    if (amount <= 0) {
      return 0;
    }
    final applied = math.min(amount, max - current);
    current += applied;
    return applied;
  }

  bool isAtOrBelowPercent(int percent) =>
      current * 100 <= max * percent;
}

/// 护盾池（产品基线 §3.3）。
///
/// 与 [Health] 分开是因为它有独立的恢复规则：
/// 「最后一次**实际扣除 HP 或护盾**后 8.0 秒开始；每秒 +3；受伤立即重置计时」。
/// 注意它**不设上限溢出**：恢复不会超过 `max`。
class ShieldPool {
  ShieldPool({required this.max, int? current})
    : assert(max >= 0, 'max 不得为负'),
      current = (current ?? max).clamp(0, max);

  int max;
  int current;

  bool get isFull => current >= max;
  bool get isEmpty => current <= 0;
  double get ratio => max == 0 ? 0 : current / max;

  /// 吸收伤害并返回**实际**吸收量。
  int absorb(int rawDamage) {
    if (rawDamage <= 0) {
      return 0;
    }
    final applied = math.min(rawDamage, current);
    current -= applied;
    return applied;
  }

  /// 回复并返回**实际**回复量（不超过 max）。
  int restore(int amount) {
    if (amount <= 0) {
      return 0;
    }
    final applied = math.min(amount, max - current);
    current += applied;
    return applied;
  }

  /// 提升上限；`refillSameAmount` 对应 UP-SHIELD-MAX 的"立即补充同等数值"。
  void raiseMax(int amount, {bool refillSameAmount = false}) {
    if (amount <= 0) {
      return;
    }
    max += amount;
    if (refillSameAmount) {
      restore(amount);
    } else {
      current = current.clamp(0, max);
    }
  }
}

/// 逻辑计时器（秒）。
///
/// 契约：**冻结状态下不递减** —— 递减只由 [tick] 触发，
/// 而冻结状态不会调用它（技术架构 §4 第 2 步）。
final class LogicalTimer {
  LogicalTimer(this.remaining, {this.period})
    : assert(remaining >= 0, '剩余时间不得为负');

  double remaining;

  /// 周期计时器在归零后自动重置的时长；null 表示一次性计时器。
  final double? period;

  bool get isElapsed => remaining <= 0;

  /// 递减；返回本次是否**恰好**归零（用于触发一次性事件）。
  bool tick(double dt) {
    if (dt <= 0 || remaining <= 0) {
      return false;
    }
    remaining -= dt;
    if (remaining <= 0) {
      final p = period;
      if (p != null && p > 0) {
        // 周期计时器：跨越**多个**周期时也要正确落位。
        // 只加一次 period 会在 dt > period 时把 remaining 留成负数
        // （例如 period=0.05、dt=0.12 → -0.07+0.05 = -0.02），
        // 于是下一次 tick 会被 `remaining <= 0` 提前返回而永久卡死。
        remaining += p * ((-remaining / p).floor() + 1);
      } else {
        remaining = 0;
      }
      return true;
    }
    return false;
  }

  void reset([double? to]) {
    remaining = to ?? period ?? 0;
  }
}

/// 一局的实时指标（协议 §2.1：只由 Domain 更新）。
class RunMetrics {
  /// 最近 15 秒内玩家承受的 HP 伤害总量。
  int hpDamageInLast15s = 0;

  /// 上一次受到 HP 伤害的逻辑时间；从未受伤为 null。
  double? lastHpDamageAt;

  int kills = 0;
  int maxCombo = 0;
  int eliteKills = 0;

  /// 每步调用：把超出 15 秒窗口的伤害移除。
  void decay(double elapsedSeconds) {
    final last = lastHpDamageAt;
    if (last == null) {
      return;
    }
    if (elapsedSeconds - last > 15.0) {
      hpDamageInLast15s = 0;
      lastHpDamageAt = null;
    }
  }

  void recordHpDamage(int amount, double atSeconds) {
    hpDamageInLast15s += amount;
    lastHpDamageAt = atSeconds;
  }

  void reset() {
    hpDamageInLast15s = 0;
    lastHpDamageAt = null;
    kills = 0;
    maxCombo = 0;
    eliteKills = 0;
  }
}

/// 冲刺状态（协议 §2.1：每层独立充能；方向在启动时锁定）。
class DashState {
  DashState({
    required this.maxCharges,
    required this.rechargeSeconds,
    this.invulnerable = false,
  }) : charges = maxCharges,
       _rechargeTimers = List<double>.filled(maxCharges, 0);

  int maxCharges;
  double rechargeSeconds;
  int charges;

  /// 是否处于冲刺无敌帧。
  bool invulnerable;

  /// 每层独立充能计时（元素为剩余充能秒数，0 表示该层可用）。
  final List<double> _rechargeTimers;

  /// 冲刺方向在启动时锁定，不使用启动后的输入。
  Vec2 direction = Vec2.zero;

  /// 本次冲刺剩余位移（px）。
  double remainingDistance = 0;

  /// 结束后的锁定时间（此期间不能再次冲刺）。
  double endLockRemaining = 0;

  bool get canDash => charges > 0 && endLockRemaining <= 0;
  bool get isDashing => remainingDistance > 0;

  List<double> get rechargeTimers =>
      List<double>.unmodifiable(_rechargeTimers);

  /// 消耗一层并开始冲刺。
  bool consume(Vec2 lockedDirection, {required double distance}) {
    if (!canDash) {
      return false;
    }
    final slot = _firstFullSlot();
    charges -= 1;
    if (slot >= 0) {
      _rechargeTimers[slot] = rechargeSeconds;
    }
    direction = lockedDirection;
    remainingDistance = distance;
    return true;
  }

  /// 每逻辑步推进充能；返回本次是否有新层就绪。
  bool tick(double dt) {
    if (dt <= 0) {
      return false;
    }
    var becameReady = false;
    for (var i = 0; i < _rechargeTimers.length; i++) {
      final value = _rechargeTimers[i];
      if (value <= 0) {
        continue;
      }
      final next = value - dt;
      if (next <= 0) {
        _rechargeTimers[i] = 0;
        if (charges < maxCharges) {
          charges += 1;
          becameReady = true;
        }
      } else {
        _rechargeTimers[i] = next;
      }
    }
    return becameReady;
  }

  int _firstFullSlot() {
    for (var i = 0; i < _rechargeTimers.length; i++) {
      if (_rechargeTimers[i] <= 0) {
        return i;
      }
    }
    return -1;
  }

  void reset() {
    charges = maxCharges;
    for (var i = 0; i < _rechargeTimers.length; i++) {
      _rechargeTimers[i] = 0;
    }
    invulnerable = false;
    direction = Vec2.zero;
    remainingDistance = 0;
    endLockRemaining = 0;
  }
}

/// 修饰符的叠加方式。
enum ModifierOperation { add, multiply }

/// 单条修饰符。
///
/// 不变量（协议 §2.1）：**同一 `sourceId` 更新而不是重复叠加** ——
/// 否则同一张卡抽到两次（例如由于 bug）会静默地把数值叠两遍。
class ModifierStack {
  final Map<String, _Modifier> _modifiers = <String, _Modifier>{};

  Iterable<String> get sourceIds => _modifiers.keys;

  /// 写入/覆盖某来源的修饰符。
  void set({
    required String sourceId,
    required ModifierOperation operation,
    required double value,
    int priority = 0,
  }) {
    _modifiers[sourceId] = _Modifier(operation, value, priority);
  }

  void remove(String sourceId) => _modifiers.remove(sourceId);

  bool has(String sourceId) => _modifiers.containsKey(sourceId);

  /// 对 [base] 应用全部修饰符。
  ///
  /// 顺序：先按 priority 升序执行全部 `add`，再执行全部 `multiply`。
  /// 这样"每级 +3"与"间隔 ×0.85"的组合结果与策划表一致且与插入顺序无关。
  double apply(double base) {
    final ordered = _modifiers.values.toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    var value = base;
    for (final modifier in ordered) {
      if (modifier.operation == ModifierOperation.add) {
        value += modifier.value;
      }
    }
    for (final modifier in ordered) {
      if (modifier.operation == ModifierOperation.multiply) {
        value *= modifier.value;
      }
    }
    return value;
  }

  void clear() => _modifiers.clear();
}

class _Modifier {
  const _Modifier(this.operation, this.value, this.priority);

  final ModifierOperation operation;
  final double value;
  final int priority;
}

/// 世界边界（产品基线 §3.4：玩家中心活动范围）。
final class WorldBounds {
  const WorldBounds({
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  static const WorldBounds playerDefault = WorldBounds(
    minX: 30,
    maxX: 1890,
    minY: 30,
    maxY: 1050,
  );

  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  /// 把点夹紧到边界内。
  Vec2 clamp(Vec2 point) => Vec2(
    point.x.clamp(minX, maxX),
    point.y.clamp(minY, maxY),
  );

  bool contains(Vec2 point) =>
      point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY;
}
