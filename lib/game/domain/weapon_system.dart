// ================================================================
// lib/game/domain/weapon_system.dart —— 目标选择与武器运行合同
//
// **⚠️ 易错点**：
//   * 高阶武器的伤害目标**只含** `EnemyBody` / `BossWeakpoint` ——
//     **永不伤害玩家或拾取物**，这是合同而非巧合；
//   * 所有距离语义统一为 logical px，不得混入屏幕像素；
//   * 目标选择必须**确定性**（同帧同输入结果一致），
//     不得依赖集合遍历顺序的偶然性。
// ================================================================
// 依据：产品基线 §4.1（初始脉冲炮）、§4.3（高阶武器的完整运行合同）
//
// **架构位置**：Domain 层 —— **纯规则**，无 I/O、无 Flutter 依赖、
//   不持有渲染状态。由 `GameRuntime` 按固定顺序驱动，每步产出的
//   是**意图/事件**，由 Core 统一结算与提交。
//
// **与谁交互**：
//   * 上游：`GameRuntime._stepOnce()` 传入本步的 `dt`/输入/世界状态
//   * 下游：返回"待施加的意图"（移动、伤害、生成请求…），
//     **本层不直接改动 Core 的实体集合**
//
// **关键约束**：
//   * **确定性**：同一 seed + 同一输入序列必须产出完全相同的结果 ——
//     禁止使用 `DateTime.now()`、未播种随机、或集合遍历顺序依赖
//   * **表现无关**：本层不得因"要画什么"而改变规则
//     （由 `acceptance_visual_must_not_affect_rules_test.dart` 守住）
// 统一规则：所有距离均为 logical px；高阶武器的伤害只影响
// EnemyBody / BossWeakpoint，**永不伤害玩家或拾取物**。
//
// 目标优先级（§4.1）：Boss 弱点 > 最近精英 > 最近普通敌人 > 正前方。
// 导弹与激光使用同一优先级的前三档。
//
// 折射与电弧共用同一条链式规则（§4.3）：
//   候选在上一目标 360 距离内；按距离再按 EntityId 排序；
//   一次激活内同一目标最多受一次链式伤害。
// ================================================================

import 'dart:math' as math;

import '../core/random_source.dart';
import 'values.dart';

/// Domain 传给武器系统的只读目标快照。
///
/// 刻意不直接引用敌人实体：武器系统只关心"能否被命中"，
/// 这样它既能在战斗中运行，也能在纯 Dart 测试里用几个值构造输入。
class TargetView {
  const TargetView({
    required this.id,
    required this.position,
    required this.radius,
    this.isElite = false,
    this.isBoss = false,
    this.isWeakpoint = false,
    this.weakpointActive = false,
  });

  final EntityId id;
  final Vec2 position;
  final double radius;
  final bool isElite;
  final bool isBoss;

  /// 是否为 Boss 弱点实体。
  final bool isWeakpoint;

  /// 弱点是否处于暴露期（仅暴露时可选）。
  final bool weakpointActive;

  bool get isTargetable => !isWeakpoint || weakpointActive;
}

/// 目标优先级档位。
enum TargetPriority { bossWeakpoint, nearestElite, nearestNormal, forward }

/// 目标选择。
class TargetingSystem {
  const TargetingSystem();

  /// 按优先级选择目标。
  ///
  /// 逐档降级：先找暴露中的 Boss 弱点，其次射程内最近的精英，
  /// 再次最近的普通敌人，都没有则返回 null（调用方回退到"正前方"）。
  /// 每一档内部按距离再按 [EntityId] 排序，保证回放确定。
  TargetView? select({
    required List<TargetView> targets,
    required Vec2 origin,
    required double range,
  }) {
    final inRange = targets
        .where((t) => t.isTargetable)
        .where((t) => origin.distanceTo(t.position) <= range)
        .toList();

    if (inRange.isEmpty) {
      return null;
    }

    // 第 1 档：Boss 弱点
    final weakpoint = _nearest(
      inRange.where((t) => t.isWeakpoint && t.weakpointActive),
      origin,
    );
    if (weakpoint != null) {
      return weakpoint;
    }

    // 第 2 档：最近精英
    final elite = _nearest(inRange.where((t) => t.isElite), origin);
    if (elite != null) {
      return elite;
    }

    // 第 3 档：最近普通敌人（含 Boss 本体）
    return _nearest(
      inRange.where((t) => !t.isElite && !t.isWeakpoint),
      origin,
    );
  }

  /// 链式候选：在 [from] 的 [radius] 内、排除已命中过的目标。
  ///
  /// 排序为**先距离再 EntityId** —— 距离相等时用实体 ID 打破平局，
  /// 否则同一帧的链式结果会随集合遍历顺序漂移，破坏回放一致性。
  List<TargetView> chainCandidates({
    required List<TargetView> targets,
    required Vec2 from,
    required double radius,
    required Set<EntityId> exclude,
  }) {
    final candidates = targets
        .where((t) => t.isTargetable && !exclude.contains(t.id))
        .where((t) => from.distanceTo(t.position) <= radius)
        .toList();

    candidates.sort((a, b) {
      final da = from.distanceSquaredTo(a.position);
      final db = from.distanceSquaredTo(b.position);
      if (da != db) {
        return da.compareTo(db);
      }
      return a.id.compareTo(b.id);
    });
    return candidates;
  }

  TargetView? _nearest(Iterable<TargetView> candidates, Vec2 origin) {
    TargetView? best;
    var bestDistance = double.infinity;
    for (final candidate in candidates) {
      final distance = origin.distanceSquaredTo(candidate.position);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      } else if (distance == bestDistance && best != null) {
        // 距离完全相等时用实体 ID 保证确定性。
        if (candidate.id.compareTo(best.id) < 0) {
          best = candidate;
        }
      }
    }
    return best;
  }
}

/// 一次发射请求（交给上层生成投射物实体）。
/// **五种主弹道形态的不可变规格**（v2.1 / 蓝图 §3.4、冻结表 §3）。
///
/// **无 style 时（`activeStyle == null`）必须与 v2.0 行为字节级等价** ——
/// 因此所有形态效果只在 style 非空时生效，绝不影响既有武器。
class WeaponStyleSpec {
  const WeaponStyleSpec({
    required this.styleId,
    required this.cardId,
    required this.damageMultiplier,
    required this.speedMultiplier,
    required this.radiusMultiplier,
    required this.extraPierce,
    required this.bounce,
    required this.homing,
    required this.projectileAssetId,
    required this.impactAssetId,
    required this.impactCueId,
    required this.projectileWidth,
    required this.projectileHeight,
    required this.impactSize,
    this.impactDamageRadius = 0,
  });

  final String styleId;
  final String cardId;
  final double damageMultiplier;
  final double speedMultiplier;
  final double radiusMultiplier;

  /// 命中后**还能再命中**几个不同目标（Prism 1 / Needle 2）。
  final int extraPierce;

  /// 首次命中后**弹跳**次数（Arc 1）；0 表示不弹跳。
  final int bounce;

  /// 是否追踪最近合法目标（Missile）。
  final bool homing;

  final String projectileAssetId;
  final String impactAssetId;
  final String impactCueId;

  final double projectileWidth;
  final double projectileHeight;
  final double impactSize;

  /// **爆裂伤害半径**（logical px）。
  ///
  /// ⚠️ 蓝图 §3.4 要求它**显式配置**且「**绝不从 96px 图片尺寸推断**」。
  /// 当前 v2.1 文档**未给出该数值**（见 `docs/研发反馈意见.md` 的 **FV21-03**），
  /// 因此这里默认为 0（= 无范围伤害），**待裁决后由配置补入**。
  /// **不得**用 `impactSize` 充当半径。
  final double impactDamageRadius;

  static WeaponStyleSpec? fromConfig(Map<String, Object?> c) {
    final styleId = c['styleId'];
    if (styleId is! String || styleId.isEmpty) {
      return null;
    }
    final psz = (c['projectileSize'] as List?) ?? const <Object?>[];
    final isz = (c['impactSize'] as List?) ?? const <Object?>[];
    return WeaponStyleSpec(
      styleId: styleId,
      cardId: c['cardId'] as String? ?? '',
      damageMultiplier: (c['damageMultiplier'] as num?)?.toDouble() ?? 1,
      speedMultiplier: (c['speedMultiplier'] as num?)?.toDouble() ?? 1,
      radiusMultiplier: (c['radiusMultiplier'] as num?)?.toDouble() ?? 1,
      extraPierce: (c['extraPierce'] as num?)?.toInt() ?? 0,
      bounce: (c['bounce'] as num?)?.toInt() ?? 0,
      homing: c['homing'] == true,
      projectileAssetId: c['projectileAssetId'] as String? ?? '',
      impactAssetId: c['impactAssetId'] as String? ?? '',
      impactCueId: c['impactCueId'] as String? ?? '',
      projectileWidth: psz.length >= 2 ? (psz[0] as num).toDouble() : 0,
      projectileHeight: psz.length >= 2 ? (psz[1] as num).toDouble() : 0,
      impactSize: isz.isNotEmpty ? (isz[0] as num).toDouble() : 0,
      impactDamageRadius:
          (c['impactDamageRadius'] as num?)?.toDouble() ?? 0,
    );
  }
}

class FiringRequest {
  const FiringRequest({
    required this.weaponId,
    required this.origin,
    required this.direction,
    required this.damage,
    required this.isCritical,
    this.targetId,
    this.speed = 0,
    this.radius = 0,
    this.lifetimeSeconds = 0,
    this.weaponStyleId,
    this.projectileAssetId,
    this.impactAssetId,
    this.impactCueId,
    this.pierceRemaining = 0,
    this.bounceRemaining = 0,
    this.homingTargetId,
    this.impactDamageRadius = 0,
  });

  final String weaponId;
  final Vec2 origin;
  final Vec2 direction;
  final int damage;
  final bool isCritical;
  final EntityId? targetId;
  final double speed;
  final double radius;
  final double lifetimeSeconds;

  // ---- v2.1 主弹道形态（蓝图 §3.4）----
  //
  // 全部为 null/0 时等价于 v2.0 的基础脉冲炮（**字节级等价**）。

  /// 五种形态之一的稳定 ID；旧主炮与副武器为 `null`。
  final String? weaponStyleId;

  /// 弹体与命中特效的 Asset ID —— **由 Domain 锁定**，
  /// 表现层**不得**按武器名去 manifest 猜（会命中错的图）。
  final String? projectileAssetId;
  final String? impactAssetId;

  /// 命中 cue（**不是**开火 cue —— 冻结表 §3 明文）。
  final String? impactCueId;

  /// 命中后还能再命中几个**不同**目标（Prism 1 / Needle 2）。
  final int pierceRemaining;

  /// 首次命中后还能弹跳几次（Arc 1）。
  final int bounceRemaining;

  /// 追踪锁定的目标（Missile）；null 表示直线飞行。
  final EntityId? homingTargetId;

  /// 爆裂伤害半径（logical px）；0 表示无范围伤害（见 FV21-03）。
  final double impactDamageRadius;
}

/// 脉冲炮的运行时状态与规则（§4.1 + §4.2 的升级效果）。
class PulseWeapon {
  PulseWeapon({
    this.baseDamage = 9,
    this.baseCadence = 0.24,
    this.speed = 1250,
    this.radius = 6,
    this.lifetimeSeconds = 1.2,
    this.range = 980,
    this.activeStyle,
  });

  final int baseDamage;
  final double baseCadence;
  final double speed;
  final double radius;
  final double lifetimeSeconds;
  final double range;

  double cooldown = 0;

  /// 升级带来的倍率/增量（由 UpgradeAccumulator 计算后写入）。
  double cadenceMultiplier = 1.0;
  int bonusDamage = 0;
  double criticalChance = 0.0;
  int projectileCount = 1;

  /// 齐射角度（度）。等级 1 为 ±6°，等级 2 为 0°（弹道并行）。
  double spreadAngleDegrees = 0;

  static const double criticalDamageMultiplier = 1.8;

  /// **当前主弹道形态**（v2.1）；`null` = v2.0 基础脉冲炮。
  ///
  /// 五张 `UP-WSTYLE-*` 仅能拥有一张，因此这里是**单值**。
  /// 切换时必须同步更新，不得在多处各存一份。
  WeaponStyleSpec? activeStyle;

  double get effectiveCadence => baseCadence * cadenceMultiplier;

  /// 形态生效后的**伤害倍率**（无形态时为 1，保证 v2.0 等价）。
  double get _styleDamageMultiplier => activeStyle?.damageMultiplier ?? 1;
  double get _styleSpeedMultiplier => activeStyle?.speedMultiplier ?? 1;
  double get _styleRadiusMultiplier => activeStyle?.radiusMultiplier ?? 1;
  int get effectiveDamage => baseDamage + bonusDamage;

  /// 推进一个逻辑步并返回本次的发射请求。
  ///
  /// [rng] 用于暴击判定；**只用整数原语**，因此回放一致。
  List<FiringRequest> step({
    required Vec2 playerPosition,
    required List<TargetView> targets,
    required double dt,
    required RandomSource rng,
    TargetingSystem targeting = const TargetingSystem(),
  }) {
    // 冷却按"累加器"语义推进：先扣掉本步 dt，发射时把周期**累加**回去，
    // 从而保留负溢出。若写成"发射后直接 = cadence"，本步消耗的 dt 就丢了，
    // 0.24 s 的节奏会退化成 0.25 s（1 秒只射 4 发而不是 5 发）。
    cooldown -= dt;
    if (cooldown > 0) {
      return const <FiringRequest>[];
    }
    cooldown += effectiveCadence;

    final target = targeting.select(
      targets: targets,
      origin: playerPosition,
      range: range,
    );

    // 无目标时向正前方（向上）射击。
    final baseDirection = target == null
        ? const Vec2(0, -1)
        : (target.position - playerPosition).normalized;

    final requests = <FiringRequest>[];
    for (var i = 0; i < projectileCount; i++) {
      final direction = projectileCount == 1 || spreadAngleDegrees == 0
          ? baseDirection
          : _rotate(baseDirection, _offsetAngle(i) * math.pi / 180);

      final isCritical = criticalChance > 0 &&
          (rng.nextInt(10000) < (criticalChance * 10000).round());
      final baseDamage = isCritical
          ? (effectiveDamage * criticalDamageMultiplier).round()
          : effectiveDamage;
      // **v2.1**：形态倍率在**此处**应用（Domain 锁定已应用的数值），
      // 表现层不再二次换算，避免"画面与规则各算一遍"漂移。
      final style = activeStyle;
      final damage = style == null
          ? baseDamage
          : (baseDamage * style.damageMultiplier).round();

      requests.add(
        FiringRequest(
          weaponId: 'WPN-PULSE',
          origin: playerPosition,
          direction: direction,
          damage: damage,
          isCritical: isCritical,
          targetId: target?.id,
          speed: speed * _styleSpeedMultiplier,
          radius: radius * _styleRadiusMultiplier,
          lifetimeSeconds: lifetimeSeconds,
          // 形态信息（无形态时全部为 null/0 ⇒ 与 v2.0 等价）。
          weaponStyleId: style?.styleId,
          projectileAssetId: style?.projectileAssetId,
          impactAssetId: style?.impactAssetId,
          impactCueId: style?.impactCueId,
          pierceRemaining: style?.extraPierce ?? 0,
          bounceRemaining: style?.bounce ?? 0,
          homingTargetId:
              (style?.homing ?? false) ? target?.id : null,
          impactDamageRadius: style?.impactDamageRadius ?? 0,
        ),
      );
    }
    return requests;
  }

  /// 多弹道角度偏移。
  ///
  /// 产品基线 §4.2 写的是"角度 ±6°"，即**最外侧两条弹道各自偏 6°**，
  /// 而不是总跨度 6°。因此这里按 (index - center) × (spread / center)
  /// 展开：双联给出 -6/+6，三联给出 -6/0/+6。
  double _offsetAngle(int index) {
    if (projectileCount <= 1 || spreadAngleDegrees == 0) {
      return 0;
    }
    final center = (projectileCount - 1) / 2.0;
    if (center == 0) {
      return 0;
    }
    return (index - center) * (spreadAngleDegrees / center);
  }
}

/// 追踪导弹（§4.3）。
class MissileWeapon {
  MissileWeapon({
    this.baseCadence = 2.4,
    this.baseDamage = 36,
    this.speed = 820,
    this.radius = 16,
    this.lifetimeSeconds = 2.0,
    this.range = 1100,
    this.turnRateDegreesPerSecond = 300,
    this.baseExplosionRadius = 70,
  });

  final double baseCadence;
  final int baseDamage;
  final double speed;
  final double radius;
  final double lifetimeSeconds;
  final double range;
  final double turnRateDegreesPerSecond;
  final double baseExplosionRadius;

  double cooldown = 0;

  /// 齐射等级 0/1/2。
  int salvoLevel = 0;

  /// 扩容等级带来的半径增量（每级 +20，上限 110）。
  int radiusBonus = 0;

  static const double _minDamage = 29;

  int get missileCount => salvoLevel + 1;

  /// 单枚伤害：`max(29, 36 × (1 - 0.10 × 齐射等级))`。
  double get damagePerMissile {
    final raw = baseDamage * (1 - 0.10 * salvoLevel);
    return raw < _minDamage ? _minDamage : raw;
  }

  double get explosionRadius {
    final raw = baseExplosionRadius + radiusBonus;
    return raw > 110 ? 110 : raw;
  }

  /// 齐射角度。
  ///
  /// 1 枚 0°；2 枚 -8/+8；3 枚 -8/0/+8；**多于 3 枚时**在 -16°..+16°
  /// 间等距展开。
  List<double> get salvoAnglesDegrees {
    switch (salvoLevel) {
      case 0:
        return const <double>[0];
      case 1:
        return const <double>[-8, 8];
      case 2:
        return const <double>[-8, 0, 8];
      default:
        final count = missileCount;
        final step = 32.0 / (count - 1);
        return List<double>.generate(count, (i) => -16 + step * i);
    }
  }

  List<FiringRequest> step({
    required Vec2 playerPosition,
    required List<TargetView> targets,
    required double dt,
    TargetingSystem targeting = const TargetingSystem(),
  }) {
    cooldown -= dt;
    if (cooldown > 0) {
      return const <FiringRequest>[];
    }
    cooldown += baseCadence;

    final target = targeting.select(
      targets: targets,
      origin: playerPosition,
      range: range,
    );

    // 无目标时向上直行；有目标时初始方向指向目标。
    final baseDirection = target == null
        ? const Vec2(0, -1)
        : (target.position - playerPosition).normalized;

    final requests = <FiringRequest>[];
    for (final angle in salvoAnglesDegrees) {
      requests.add(
        FiringRequest(
          weaponId: 'WPN-MISSILE',
          origin: playerPosition,
          direction: _rotate(baseDirection, angle * math.pi / 180),
          damage: damagePerMissile.round(),
          isCritical: false,
          targetId: target?.id,
          speed: speed,
          radius: radius,
          lifetimeSeconds: lifetimeSeconds,
        ),
      );
    }
    return requests;
  }

  /// 导弹每步转向：最大转向率 300°/s，朝当前目标收敛。
  Vec2 steer({
    required Vec2 currentDirection,
    required Vec2 missilePosition,
    required TargetView? target,
    required double dt,
  }) {
    if (target == null) {
      return currentDirection;
    }
    final desired = (target.position - missilePosition).normalized;
    if (desired == Vec2.zero) {
      return currentDirection;
    }
    final currentAngle = math.atan2(currentDirection.y, currentDirection.x);
    final desiredAngle = math.atan2(desired.y, desired.x);
    var delta = desiredAngle - currentAngle;
    while (delta > math.pi) {
      delta -= 2 * math.pi;
    }
    while (delta < -math.pi) {
      delta += 2 * math.pi;
    }
    final maxTurn = turnRateDegreesPerSecond * math.pi / 180 * dt;
    final turn = delta.abs() > maxTurn ? maxTurn * delta.sign : delta;
    final newAngle = currentAngle + turn;
    return Vec2(math.cos(newAngle), math.sin(newAngle));
  }
}

/// 持续激光（§4.3）。
class LaserWeapon {
  LaserWeapon({
    this.periodSeconds = 5.0,
    this.activeSeconds = 1.2,
    this.tickSeconds = 0.1,
    this.damagePerTick = 6,
    this.width = 28,
    this.range = 900,
  });

  final double periodSeconds;
  final double activeSeconds;
  final double tickSeconds;
  final int damagePerTick;
  final double width;
  final double range;

  double cooldown = 0;
  double activeRemaining = 0;
  double tickAccumulator = 0;

  /// 本段激活还需结算的次数。
  int ticksRemaining = 0;

  EntityId? lockedTarget;
  int prismHops = 0;

  bool get isActive => activeRemaining > 0;

  /// 一次激光激活内的伤害结算。
  ///
  /// 返回主目标的命中与链式折射的命中列表。
  LaserTickResult? step({
    required Vec2 playerPosition,
    required List<TargetView> targets,
    required double dt,
    TargetingSystem targeting = const TargetingSystem(),
  }) {
    // 冷却与激活期互斥推进。
    if (activeRemaining > 0) {
      activeRemaining -= dt;
      tickAccumulator += dt;
      // 顺序很重要：**先结算本步 tick，再判断激活期结束**。
      // 反过来的话，1.2 s / 0.1 s = 12 次里的最后一次会正好落在
      // 到期那一步被吞掉，实际只有 11 次（总伤害少 6 点）。
      if (ticksRemaining > 0 &&
          tickAccumulator >= tickSeconds - _floatTolerance) {
        tickAccumulator -= tickSeconds;
        ticksRemaining -= 1;
        final result = _resolveTick(
          playerPosition: playerPosition,
          targets: targets,
          targeting: targeting,
        );
        if (activeRemaining <= 0) {
          activeRemaining = 0;
          tickAccumulator = 0;
          lockedTarget = null;
        }
        return result;
      }
      if (activeRemaining <= 0) {
        activeRemaining = 0;
        tickAccumulator = 0;
        lockedTarget = null;
      }
      return null;
    }

    if (cooldown > 0) {
      cooldown -= dt;
      if (cooldown > 0) {
        return null;
      }
    }

    // 激活瞬间锁定目标；无目标则不显示也不结算伤害。
    final target = targeting.select(
      targets: targets,
      origin: playerPosition,
      range: range,
    );
    if (target == null) {
      cooldown = tickSeconds; // 下一步再试，不消耗完整周期
      return null;
    }

    cooldown = periodSeconds;
    activeRemaining = activeSeconds;
    tickAccumulator = 0;
    // 以"本段激活应结算多少次"为真值，而不是靠浮点累加去凑。
    // 1.2 s / 0.1 s 累加 72 步后会得到 0.09999999999999987，
    // 用 `>= 0.1` 判断会少结算最后一次（总伤害少 6 点）。
    ticksRemaining = (activeSeconds / tickSeconds).round();
    lockedTarget = target.id;
    return null;
  }

  LaserTickResult _resolveTick({
    required Vec2 playerPosition,
    required List<TargetView> targets,
    required TargetingSystem targeting,
  }) {
    // 目标死亡或离开射程后，本步按同一优先级重锁。
    var target = targets
        .where((t) => t.id == lockedTarget)
        .where((t) => t.isTargetable)
        .where((t) => playerPosition.distanceTo(t.position) <= range)
        .firstOrNull;

    target ??= targeting.select(
      targets: targets,
      origin: playerPosition,
      range: range,
    );
    if (target == null) {
      lockedTarget = null;
      return const LaserTickResult(
        primary: null,
        refracts: <LaserHit>[],
        direction: null,
      );
    }
    lockedTarget = target.id;

    final hits = <LaserHit>[
      LaserHit(
        targetId: target.id,
        position: target.position,
        damage: damagePerTick,
      ),
    ];

    // 棱镜折射：每次 tick 后从主目标向最近的未命中目标跳。
    var source = target;
    var currentDamage = damagePerTick;
    final visited = <EntityId>{target.id};
    for (var hop = 0; hop < prismHops; hop++) {
      final candidates = targeting.chainCandidates(
        targets: targets,
        from: source.position,
        radius: 360,
        exclude: visited,
      );
      if (candidates.isEmpty) {
        break;
      }
      final next = candidates.first;
      visited.add(next.id);
      currentDamage = (currentDamage * 0.60).round();
      hits.add(
        LaserHit(
          targetId: next.id,
          position: next.position,
          damage: currentDamage,
          isRefraction: true,
        ),
      );
      source = next;
    }

    return LaserTickResult(
      primary: hits.first,
      refracts: hits.skip(1).toList(growable: false),
      direction: (target.position - playerPosition).normalized,
    );
  }

  void reset() {
    cooldown = 0;
    activeRemaining = 0;
    tickAccumulator = 0;
    ticksRemaining = 0;
    lockedTarget = null;
  }
}

/// 固定步长下累加 1/60 的浮点容差：只用于抵消累加残差，
/// 不改变任何产品数值。
const double _floatTolerance = 1e-9;

/// 一次激光命中的结果。
class LaserTickResult {
  const LaserTickResult({
    required this.primary,
    required this.refracts,
    required this.direction,
  });

  final LaserHit? primary;
  final List<LaserHit> refracts;
  final Vec2? direction;

  bool get hasTarget => primary != null;
}

class LaserHit {
  const LaserHit({
    required this.targetId,
    required this.position,
    required this.damage,
    this.isRefraction = false,
  });

  final EntityId targetId;
  final Vec2 position;
  final int damage;
  final bool isRefraction;
}

/// 电弧暴击（§4.3）：一次暴击仅一跳，伤害为触发脉冲**最终结算伤害**的 50%。
class ArcWeapon {
  const ArcWeapon({this.radius = 360, this.damageRatio = 0.5});

  final double radius;
  final double damageRatio;

  /// 从已命中的目标寻找最近的一个"另一个"有效敌人。
  ///
  /// 候选距离 ≤ [radius]，按距离再按 EntityId 排序；无候选则只保留暴击本身。
  ArcHit? resolve({
    required EntityId hitTarget,
    required Vec2 hitPosition,
    required int finalPulseDamage,
    required List<TargetView> targets,
    TargetingSystem targeting = const TargetingSystem(),
  }) {
    final candidates = targeting.chainCandidates(
      targets: targets,
      from: hitPosition,
      radius: radius,
      exclude: <EntityId>{hitTarget},
    );
    if (candidates.isEmpty) {
      return null;
    }
    final next = candidates.first;
    return ArcHit(
      targetId: next.id,
      position: next.position,
      damage: (finalPulseDamage * damageRatio).round(),
    );
  }
}

class ArcHit {
  const ArcHit({
    required this.targetId,
    required this.position,
    required this.damage,
  });

  final EntityId targetId;
  final Vec2 position;
  final int damage;
}

/// 轨道无人机（§4.3）。
class DroneWeapon {
  DroneWeapon({
    this.orbitRadius = 120,
    this.angularSpeedDegreesPerSecond = 120,
    this.cadence = 0.8,
    this.range = 600,
    this.damage = 12,
    this.boltSpeed = 900,
    this.boltRadius = 10,
    this.boltLifetimeSeconds = 0.8,
  });

  final double orbitRadius;
  final double angularSpeedDegreesPerSecond;
  final double cadence;
  final double range;
  final int damage;
  final double boltSpeed;
  final double boltRadius;
  final double boltLifetimeSeconds;

  int count = 0;

  /// 每架无人机的角度（弧度）与开火冷却。
  final List<double> _angles = <double>[];
  final List<double> _cooldowns = <double>[];

  /// 设置无人机数量；新增的与已有机体**均匀分布**。
  void setCount(int newCount) {
    if (newCount == count) {
      return;
    }
    count = newCount;
    _angles.clear();
    _cooldowns.clear();
    for (var i = 0; i < newCount; i++) {
      _angles.add(2 * math.pi * i / newCount);
      _cooldowns.add(cadence);
    }
  }

  /// 某架无人机的位置。
  Vec2 positionOf(int index, Vec2 playerPosition) {
    final angle = _angles[index];
    return Vec2(
      playerPosition.x + orbitRadius * math.cos(angle),
      playerPosition.y + orbitRadius * math.sin(angle),
    );
  }

  List<FiringRequest> step({
    required Vec2 playerPosition,
    required List<TargetView> targets,
    required double dt,
    TargetingSystem targeting = const TargetingSystem(),
  }) {
    if (count == 0) {
      return const <FiringRequest>[];
    }

    final angularStep = angularSpeedDegreesPerSecond * math.pi / 180 * dt;
    final requests = <FiringRequest>[];

    for (var i = 0; i < count; i++) {
      _angles[i] = (_angles[i] + angularStep) % (2 * math.pi);

      _cooldowns[i] -= dt;
      if (_cooldowns[i] > 0) {
        continue;
      }

      final position = positionOf(i, playerPosition);
      final target = targeting.select(
        targets: targets,
        origin: position,
        range: range,
      );
      // 无目标不发射。
      if (target == null) {
        continue;
      }
      _cooldowns[i] += cadence;
      requests.add(
        FiringRequest(
          weaponId: 'WPN-DRONE',
          origin: position,
          direction: (target.position - position).normalized,
          damage: damage,
          isCritical: false,
          targetId: target.id,
          speed: boltSpeed,
          radius: boltRadius,
          lifetimeSeconds: boltLifetimeSeconds,
        ),
      );
    }
    return requests;
  }

  void reset() {
    _angles.clear();
    _cooldowns.clear();
    count = 0;
  }
}

/// 按角度旋转向量。
Vec2 _rotate(Vec2 vector, double radians) {
  final cos = math.cos(radians);
  final sin = math.sin(radians);
  return Vec2(
    vector.x * cos - vector.y * sin,
    vector.x * sin + vector.y * cos,
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
