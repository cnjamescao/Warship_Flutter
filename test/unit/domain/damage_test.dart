// ================================================================
// test/unit/domain/damage_test.dart —— 伤害、护盾与命中闸门
// ================================================================
// 覆盖 P0 用例：T-DMG-01 / T-DMG-02 / T-DMG-03 / T-DMG-04
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/domain/damage.dart';
import 'package:warship_flutter/game/domain/values.dart';

const EntityId kPlayer = EntityId(EntityKind.player, 1);
const EntityId kEnemy = EntityId(EntityKind.enemy, 7);
const EntityId kHazard = EntityId(EntityKind.hazard, 9);

DamageIntent intent({
  EntityId source = kEnemy,
  int damage = 10,
  DamageType type = DamageType.standard,
  int frame = 1,
  String hitKey = 'k1',
}) => DamageIntent(
  sourceId: source,
  targetId: kPlayer,
  damageType: type,
  rawDamage: damage,
  frameIndex: frame,
  hitKey: hitKey,
);

void main() {
  group('T-DMG-04 护盾 → HP 的结算顺序', () {
    test('护盾 5、HP 100 承受 12 → 护盾 0、HP 93', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 30, current: 5);

      final result = system.applyToPlayer(
        intent: intent(damage: 12),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );

      expect(result.shieldDamage, 5);
      expect(result.hpDamage, 7);
      expect(shield.current, 0);
      expect(health.current, 93);
      expect(result.killed, isFalse);
    });

    test('护盾足够时完全不扣 HP', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 30);

      final result = system.applyToPlayer(
        intent: intent(damage: 12),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );

      expect(result.shieldDamage, 12);
      expect(result.hpDamage, 0);
      expect(health.current, 100);
      expect(shield.current, 18);
    });

    test('伤害致死时 killed 为 true', () {
      final system = DamageSystem();
      final health = Health(max: 100, current: 5);
      final shield = ShieldPool(max: 30, current: 0);

      final result = system.applyToPlayer(
        intent: intent(damage: 12),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );

      expect(result.killed, isTrue);
      expect(health.current, 0);
    });

    test('护盾恢复：8 秒后才开始每秒 +3', () {
      final regen = ShieldRegen(delaySeconds: 8.0, perSecond: 3);
      final shield = ShieldPool(max: 30, current: 5);
      final health = Health(max: 100);

      // 先受伤，触发恢复延迟。
      DamageSystem().applyToPlayer(
        intent: intent(damage: 12),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );
      regen.notifyDamaged();
      expect(shield.current, 0);

      // 推进 7.9 秒：不应有任何恢复。
      const step = 1 / 60;
      for (var i = 0; i < 474; i++) {
        regen.tick(step, shield);
      }
      expect(shield.current, 0, reason: '8 秒延迟内不得回盾');

      // 再推进到 8 秒之后 ~1 秒，应恢复约 3 点。
      for (var i = 0; i < 61; i++) {
        regen.tick(step, shield);
      }
      expect(shield.current, inInclusiveRange(2, 4));
      expect(regen.isRegenerating, isTrue);
    });

    test('再次受伤会重置 8 秒延迟', () {
      final regen = ShieldRegen(delaySeconds: 8.0, perSecond: 3);
      final shield = ShieldPool(max: 30, current: 10);

      // 推进到 8 秒之后（490 步 ≈ 8.17 s）。
      for (var i = 0; i < 490; i++) {
        regen.tick(1 / 60, shield);
      }
      expect(regen.isRegenerating, isTrue);

      regen.notifyDamaged();

      expect(regen.isRegenerating, isFalse);
      expect(regen.remainingDelay, 8.0);
    });
  });

  group('T-DMG-01 同一投射物同帧重复接触', () {
    test('相同 hitKey 在同帧只结算一次', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 0, current: 0);

      final first = system.applyToPlayer(
        intent: intent(damage: 9, frame: 42, hitKey: 'proj5|enemy3'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );
      final second = system.applyToPlayer(
        intent: intent(damage: 9, frame: 42, hitKey: 'proj5|enemy3'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );

      expect(first.hpDamage, 9);
      expect(second.hpDamage, 0);
      expect(second.blockedByGate, isTrue);
      expect(health.current, 91, reason: '只应扣一次');
    });

    test('进入新帧后同一 hitKey 可以再次结算', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 0, current: 0);

      // 同源间隔内仍被 0.25s 闸门挡住，因此推进时间后再测。
      system.applyToPlayer(
        intent: intent(damage: 9, frame: 42, hitKey: 'h'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );
      final later = system.applyToPlayer(
        intent: intent(damage: 9, frame: 43, hitKey: 'h'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.3,
      );

      expect(later.hpDamage, 9);
      expect(health.current, 82);
    });

    test('mergeSameFrame 合并同帧同目标的多条意图', () {
      final merged = DamageSystem.mergeSameFrame(<DamageIntent>[
        intent(damage: 4, frame: 5, hitKey: 'a'),
        intent(damage: 6, frame: 5, hitKey: 'b'),
      ]);

      expect(merged.length, 1);
      expect(merged.first.rawDamage, 10);
    });

    test('mergeSameFrame 中同键只算一次', () {
      final merged = DamageSystem.mergeSameFrame(<DamageIntent>[
        intent(damage: 4, frame: 5, hitKey: 'same'),
        intent(damage: 4, frame: 5, hitKey: 'same'),
      ]);

      expect(merged.length, 1);
      expect(merged.first.rawDamage, 4);
    });

    test('mergeSameFrame 中任一条为突破时整体按穿透处理', () {
      final merged = DamageSystem.mergeSameFrame(<DamageIntent>[
        intent(damage: 4, frame: 5, hitKey: 'a'),
        intent(damage: 6, frame: 5, hitKey: 'b', type: DamageType.breach),
      ]);

      expect(merged.single.damageType, DamageType.breach);
      expect(merged.single.rawDamage, 10);
    });
  });

  group('T-DMG-02 同源 0.25 秒命中闸门', () {
    test('同一来源在 0.25 秒内只结算一次', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 0, current: 0);

      final first = system.applyToPlayer(
        intent: intent(source: kHazard, damage: 8, frame: 1, hitKey: 'h1'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 10.0,
      );
      expect(first.hpDamage, 8);

      // 0.24 秒后：仍在闸门内。
      final blocked = system.applyToPlayer(
        intent: intent(source: kHazard, damage: 8, frame: 15, hitKey: 'h2'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 10.24,
      );
      expect(blocked.blockedByGate, isTrue);
      expect(blocked.hpDamage, 0);

      // 0.26 秒后：放行。
      final allowed = system.applyToPlayer(
        intent: intent(source: kHazard, damage: 8, frame: 16, hitKey: 'h3'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 10.26,
      );
      expect(allowed.hpDamage, 8);
      expect(health.current, 84);
    });

    test('不同来源各自独立计数', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 0, current: 0);

      system.applyToPlayer(
        intent: intent(source: kEnemy, damage: 5, frame: 1, hitKey: 'a'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 5.0,
      );
      final other = system.applyToPlayer(
        intent: intent(
          source: kHazard,
          damage: 5,
          frame: 1,
          hitKey: 'b',
        ),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 5.0,
      );

      expect(other.hpDamage, 5, reason: '不同来源不受彼此闸门影响');
      expect(health.current, 90);
    });
  });

  group('T-DMG-03 冲刺无敌', () {
    test('无敌期间伤害为 0，且不消耗闸门', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 30);

      final blocked = system.applyToPlayer(
        intent: intent(damage: 12, frame: 1, hitKey: 'x'),
        health: health,
        shield: shield,
        invulnerable: true,
        nowSeconds: 3.0,
      );

      expect(blocked.blockedByInvulnerability, isTrue);
      expect(blocked.shieldDamage, 0);
      expect(blocked.hpDamage, 0);
      expect(health.current, 100);
      expect(shield.current, 30);
    });

    test('无敌结束后同一次攻击可以正常结算', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 30, current: 0);

      system.applyToPlayer(
        intent: intent(damage: 12, frame: 1, hitKey: 'x'),
        health: health,
        shield: shield,
        invulnerable: true,
        nowSeconds: 3.0,
      );
      final after = system.applyToPlayer(
        intent: intent(damage: 12, frame: 2, hitKey: 'x'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 3.01,
      );

      expect(
        after.hpDamage,
        12,
        reason: '无敌期间的命中不消耗闸门，结束后应立即可以受伤',
      );
      expect(health.current, 88);
    });
  });

  group('突破伤害穿透护盾（产品基线 §5）', () {
    test('突破伤害直接扣 HP，护盾不变', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 30, current: 30);

      final result = system.applyToPlayer(
        intent: intent(damage: 8, type: DamageType.breach, hitKey: 'b'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );

      expect(result.shieldDamage, 0);
      expect(result.hpDamage, 8);
      expect(shield.current, 30, reason: '护盾必须完好');
      expect(health.current, 92);
    });

    test('精英突破为 15 点（产品基线 §5）', () {
      final system = DamageSystem();
      final health = Health(max: 100);
      final shield = ShieldPool(max: 30);

      system.applyToPlayer(
        intent: intent(damage: 15, type: DamageType.breach, hitKey: 'e'),
        health: health,
        shield: shield,
        invulnerable: false,
        nowSeconds: 1.0,
      );

      expect(health.current, 85);
    });
  });
}
