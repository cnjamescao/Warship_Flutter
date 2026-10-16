// ================================================================
// lib/game/presentation/visual_effects.dart —— 由事件驱动的纯表现特效
//
// **架构位置**：Presentation（表现） —— **只读快照、只画画面**，不持有规则状态。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：表现不得影响规则 · 只用 manifest 绑定素材（禁用 Canvas 几何替代）。
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §6
//   「背景、粒子、残影等纯表现对象可不创建 Domain 实体，
//     但必须由 `DomainEvent` 触发且**受性能上限控制**。」
//
// 产品基线 §6 的对象预算：粒子 180、伤害数字 20。
// 产品基线 §2 的降级顺序：星云 → 非关键粒子 → 命中碎片 → 伤害数字。
//
// 因此本模块有两条独立的上限：
//   1. **预算**（对象数量）—— 满了就拒绝新增；
//   2. **降级**（视觉档位）—— 档位不够就整层不产生也不绘制。
// 两者都不影响规则：这些对象不参与碰撞、不参与伤害。
// ================================================================

import 'dart:math' as math;

import '../core/domain_event.dart';
import '../core/event_bus.dart';
import '../domain/values.dart';
import '../infrastructure/performance_monitor.dart';

/// 一片命中碎片。
class HitDebris {
  HitDebris({
    required this.position,
    required this.velocity,
    required this.lifetime,
    required this.color,
  }) : remaining = lifetime;

  Vec2 position;
  Vec2 velocity;
  final double lifetime;
  double remaining;
  final int color;

  bool get isExpired => remaining <= 0;

  void step(double dt) {
    remaining -= dt;
    position = position + velocity * dt;
    // 简单阻尼，避免碎片飞出画面。
    velocity = velocity * 0.94;
  }
}

/// 一个伤害数字。
class DamageNumber {
  DamageNumber({
    required this.position,
    required this.amount,
    required this.isCritical,
    this.lifetime = 0.7,
  }) : remaining = lifetime;

  Vec2 position;
  final int amount;
  final bool isCritical;
  final double lifetime;
  double remaining;

  bool get isExpired => remaining <= 0;

  void step(double dt) {
    remaining -= dt;
    // 缓慢上浮。
    position = Vec2(position.x, position.y - 40 * dt);
  }
}

/// 拾取物/补给的一次性表现（F-12 裁决第 2 步）。
///
/// 裁决：「在 `GFX-PICKUP-ELITE-CORE` 以及战前补给的
/// `GFX-PICKUP-SUPPLY-HEAL/SHIELD/DASH` **中央，以原尺寸 42% 叠加**
/// `UI-COLORBLIND-PATTERN-REWARD`；**只做视觉层，不新增碰撞、掉落或
/// 数值规则**」。
///
/// 因此它是**纯表现**：没有碰撞体、不进 `snapshot` 的实体列表、
/// 不影响任何数值。位置取自事件发生时的玩家坐标。
class PickupFlash {
  PickupFlash({
    required this.position,
    required this.pickupAssetId,
    this.lifetime = 0.6,
  }) : remaining = lifetime;

  Vec2 position;

  /// 拾取物图形（`GFX-PICKUP-*`）。
  final String pickupAssetId;

  final double lifetime;
  double remaining;

  bool get isExpired => remaining <= 0;

  /// 叠层相对原尺寸的比例（裁决：**原尺寸 42%**）。
  static const double rewardOverlayScale = 0.42;

  void step(double dt) {
    remaining -= dt;
    // 轻微上浮，与伤害数字一致的"一次性提示"语汇。
    position = Vec2(position.x, position.y - 24 * dt);
  }
}

/// 特效池：由 DomainEvent 驱动，受预算与降级双重限制。
class VisualEffects {
  VisualEffects({
    this.budget = const ObjectBudget(),
    int seed = 0x4E454F4E0001,
  }) : _rng = math.Random(seed);

  final ObjectBudget budget;
  final math.Random _rng;

  final List<HitDebris> debris = <HitDebris>[];
  final List<DamageNumber> numbers = <DamageNumber>[];
  final List<PickupFlash> pickups = <PickupFlash>[];

  /// 因预算或降级被拒绝的次数（诊断用）。
  int rejectedDebris = 0;
  int rejectedNumbers = 0;

  /// 消费一批事件，生成对应特效。
  ///
  /// 只认 `WeaponHit`（命中碎片）与 `EnemyDamaged`（伤害数字）——
  /// 这两个事件携带生成所需的全部字段，不需要猜。
  /// [positionOf] 由表现层提供：把 `WeaponHit`/`EnemyDamaged` 的目标 ID
  /// 解析成当前坐标。领域事件只带 ID 不带坐标，因此坐标来源必须显式传入，
  /// 而不是在这里猜。
  void consume(
    List<StampedEvent> events, {
    required DegradationLevel level,
    Vec2? Function(EntityId id)? positionOf,
  }) {
    for (final stamped in events) {
      switch (stamped.event) {
        case WeaponHit(:final damage, :final critical, :final targetId):
          if (!level.allows(DegradationLevel.hitDebris)) {
            rejectedDebris++;
            break;
          }
          if (debris.length >= budget.particles) {
            // 预算已满：拒绝低优先级特效，**不影响**预警与碰撞。
            rejectedDebris++;
            break;
          }
          final position = positionOf?.call(targetId);
          if (position == null) {
            rejectedDebris++;
            break;
          }
          _pendingHitPositions.add(
            _PendingHit(
              damage: damage,
              critical: critical,
              position: position,
            ),
          );
        // F-12 裁决第 2 步：拾取物/补给的表现路径。
        //
        // 这三个事件都是**玩家-centric** 的（补给在玩家身上生效），
        // 因此位置取玩家坐标。**只生成表现**，不产生任何实体或数值。
        // 降级**不得**削减它 —— 裁决要求色弱叠层"始终显示"。
        case PickupHeal():
        case PickupShield():
        case DashReady():
          final playerPos = positionOf?.call(
            const EntityId(EntityKind.player, 0),
          );
          if (playerPos == null) {
            break;
          }
          pickups.add(
            PickupFlash(
              position: playerPos,
              pickupAssetId: pickupAssetFor(stamped.event),
            ),
          );
        default:
          break;
      }

      switch (stamped.event) {
        case EnemyDamaged(:final entityId, :final damage):
          if (!level.allows(DegradationLevel.damageNumbers)) {
            rejectedNumbers++;
            break;
          }
          if (numbers.length >= budget.damageNumbers) {
            rejectedNumbers++;
            break;
          }
          final position = positionOf?.call(entityId);
          if (position == null) {
            rejectedNumbers++;
            break;
          }
          numbers.add(
            DamageNumber(position: position, amount: damage, isCritical: false),
          );
        default:
          break;
      }
    }

    _flushPending();
  }

  final List<_PendingHit> _pendingHitPositions = <_PendingHit>[];

  void _flushPending() {
    for (final pending in _pendingHitPositions) {
      debris.add(
        HitDebris(
          position: pending.position,
          velocity: Vec2(
            (_rng.nextDouble() - 0.5) * 240,
            (_rng.nextDouble() - 0.5) * 240,
          ),
          lifetime: 0.35,
          color: pending.critical ? 0xFFFFC24B : 0xFF7CF9FF,
        ),
      );
    }
    _pendingHitPositions.clear();
  }

  /// 推进所有特效。
  void step(double dt) {
    for (final piece in debris) {
      piece.step(dt);
    }
    debris.removeWhere((d) => d.isExpired);
    for (final number in numbers) {
      number.step(dt);
    }
    numbers.removeWhere((n) => n.isExpired);
  }

  void clear() {
    debris.clear();
    numbers.clear();
    _pendingHitPositions.clear();
  }

  int get activeCount => debris.length + numbers.length;
}

class _PendingHit {
  const _PendingHit({
    required this.damage,
    required this.critical,
    required this.position,
  });

  final int damage;
  final bool critical;
  final Vec2 position;
}

/// 拾取事件 → 拾取物图形 Asset ID（按 manifest 的绑定，不猜）。
///
/// 与 `assets/config/v2/manifest.json` 的绑定一致：
/// `PickupHeal` → `GFX-PICKUP-SUPPLY-HEAL`、
/// `PickupShield` → `GFX-PICKUP-SUPPLY-SHIELD`、
/// `DashReady` → `GFX-PICKUP-SUPPLY-DASH`。
String pickupAssetFor(DomainEvent event) => switch (event) {
  PickupHeal() => 'GFX-PICKUP-SUPPLY-HEAL',
  PickupShield() => 'GFX-PICKUP-SUPPLY-SHIELD',
  DashReady() => 'GFX-PICKUP-SUPPLY-DASH',
  _ => 'GFX-PICKUP-SUPPLY-HEAL',
};
