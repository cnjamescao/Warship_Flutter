// ================================================================
// test/unit/presentation/visual_effects_test.dart
// ================================================================
// 覆盖架构 §6「纯表现对象必须由 DomainEvent 触发且受性能上限控制」
// 与产品基线 §2 的降级顺序、§6 的对象预算。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/domain_event.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/infrastructure/performance_monitor.dart';
import 'package:warship_flutter/game/presentation/visual_effects.dart';

const EntityId kEnemy = EntityId(EntityKind.enemy, 1);

StampedEvent hit({bool critical = false}) => StampedEvent(
  event: WeaponHit(
    weaponId: 'WPN-PULSE',
    sourceId: const EntityId(EntityKind.player, 0),
    targetId: kEnemy,
    critical: critical,
    damage: 9,
  ),
  runId: 't',
  frameIndex: 1,
  eventIndex: 1,
);

StampedEvent damaged({int damage = 9}) => StampedEvent(
  event: EnemyDamaged(
    entityId: kEnemy,
    enemyId: 'EN-SCOUT',
    damage: damage,
    hpAfter: 9,
    hpMax: 18,
  ),
  runId: 't',
  frameIndex: 1,
  eventIndex: 2,
);

Vec2? resolve(EntityId id) => id == kEnemy ? const Vec2(500, 400) : null;

void main() {
  group('事件驱动生成', () {
    test('WeaponHit 在允许的档位下于目标位置生成碎片', () {
      final effects = VisualEffects()
        ..consume(
          <StampedEvent>[hit()],
          level: DegradationLevel.none,
          positionOf: resolve,
        );

      expect(effects.debris, hasLength(1));
      expect(effects.debris.first.position, const Vec2(500, 400));
    });

    test('EnemyDamaged 生成伤害数字', () {
      final effects = VisualEffects()
        ..consume(
          <StampedEvent>[damaged(damage: 12)],
          level: DegradationLevel.none,
          positionOf: resolve,
        );

      expect(effects.numbers, hasLength(1));
      expect(effects.numbers.first.amount, 12);
    });

    test('解析不到目标位置时拒绝生成（不猜坐标）', () {
      final effects = VisualEffects()
        ..consume(
          <StampedEvent>[hit()],
          level: DegradationLevel.none,
          positionOf: (_) => null,
        );

      expect(effects.debris, isEmpty);
      expect(effects.rejectedDebris, 1);
    });
  });

  group('降级门禁（产品基线 §2）', () {
    test('降到命中碎片档及以下时才不再生成碎片', () {
      // 降级顺序：星云 → 非关键粒子 → **命中碎片** → 伤害数字。
      // 因此降到"粒子"档时碎片**仍然保留**（它比粒子更内层）。
      final atParticles = VisualEffects()
        ..consume(
          <StampedEvent>[hit()],
          level: DegradationLevel.particles,
          positionOf: resolve,
        );
      expect(
        atParticles.debris,
        hasLength(1),
        reason: '粒子档时命中碎片仍应绘制',
      );

      for (final level in <DegradationLevel>[
        DegradationLevel.hitDebris,
        DegradationLevel.damageNumbers,
      ]) {
        final effects = VisualEffects()
          ..consume(
            <StampedEvent>[hit()],
            level: level,
            positionOf: resolve,
          );
        expect(effects.debris, isEmpty, reason: '${level.name} 不应生成碎片');
        expect(effects.rejectedDebris, 1);
      }
    });

    test('只有最低档才屏蔽伤害数字', () {
      final allowed = VisualEffects()
        ..consume(
          <StampedEvent>[damaged()],
          level: DegradationLevel.hitDebris,
          positionOf: resolve,
        );
      expect(
        allowed.numbers,
        hasLength(1),
        reason: '命中碎片档时伤害数字是最后还留着的一层',
      );

      final blocked = VisualEffects()
        ..consume(
          <StampedEvent>[damaged()],
          level: DegradationLevel.damageNumbers,
          positionOf: resolve,
        );
      expect(blocked.numbers, isEmpty);
      expect(blocked.rejectedNumbers, 1);
    });
  });

  group('对象预算（产品基线 §6）', () {
    test('伤害数字上限 20', () {
      final effects = VisualEffects();
      for (var i = 0; i < 40; i++) {
        effects.consume(
          <StampedEvent>[damaged()],
          level: DegradationLevel.none,
          positionOf: resolve,
        );
      }

      expect(effects.numbers.length, 20);
      expect(effects.rejectedNumbers, 20);
    });

    test('碎片受粒子上限约束', () {
      final effects = VisualEffects(
        budget: const ObjectBudget(particles: 5),
      );
      for (var i = 0; i < 12; i++) {
        effects.consume(
          <StampedEvent>[hit()],
          level: DegradationLevel.none,
          positionOf: resolve,
        );
      }

      expect(effects.debris.length, 5);
      expect(effects.rejectedDebris, 7);
    });
  });

  group('生命周期', () {
    test('到期后被回收', () {
      final effects = VisualEffects()
        ..consume(
          <StampedEvent>[hit(), damaged()],
          level: DegradationLevel.none,
          positionOf: resolve,
        );
      expect(effects.activeCount, 2);

      for (var i = 0; i < 60; i++) {
        effects.step(1 / 60);
      }
      expect(effects.activeCount, 0);
    });

    test('clear 清空全部特效', () {
      final effects = VisualEffects()
        ..consume(
          <StampedEvent>[hit(), damaged()],
          level: DegradationLevel.none,
          positionOf: resolve,
        )
        ..clear();
      expect(effects.activeCount, 0);
    });
  });
}
