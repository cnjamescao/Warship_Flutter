// ================================================================
// test/unit/infrastructure/haptics_test.dart —— F-10 触感
// ================================================================
// 裁决：「仅在 `hpDamage>0` 时触发 medium impact、确认风险门时
// light impact、Boss 击败时 success/heavy pattern；**护盾独立受击、
// 普通击杀、射击、每发子弹均不得触发**。平台不支持时必须静默 no-op。」
//
// 正反向都测：**该触发的**与**绝不该触发的**。
// ================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/domain_event.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/infrastructure/haptics_director.dart';
import 'package:warship_flutter/game/infrastructure/haptics_port.dart';

void main() {
  group('平台默认（F-10）', () {
    test('原生移动端默认开', () {
      expect(
        platformSupportsHaptics(
          isWebOverride: false,
          platformOverride: TargetPlatform.iOS,
        ),
        isTrue,
      );
      expect(
        platformSupportsHaptics(
          isWebOverride: false,
          platformOverride: TargetPlatform.android,
        ),
        isTrue,
      );
    });

    test('Web 与 macOS 默认关', () {
      expect(
        platformSupportsHaptics(
          isWebOverride: true,
          platformOverride: TargetPlatform.iOS,
        ),
        isFalse,
        reason: 'Web 即便底层平台是 iOS 也不支持触感',
      );
      for (final p in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          platformSupportsHaptics(isWebOverride: false, platformOverride: p),
          isFalse,
          reason: '$p 不支持触感',
        );
      }
    });
  });

  group('服务：双重门（用户开关 且 平台支持）', () {
    test('平台不支持时静默 no-op（不抛异常、不调用端口）', () async {
      final port = RecordingHapticsPort(isSupported: false);
      final service = HapticsService(port);
      await service.impact(HapticStrength.medium);
      await service.success();
      expect(port.impacts, isEmpty);
      expect(port.successCount, 0);
      expect(service.willFire, isFalse);
    });

    test('用户关闭时静默 no-op（即便平台支持）', () async {
      final port = RecordingHapticsPort();
      final service = HapticsService(port, enabled: false);
      await service.impact(HapticStrength.medium);
      expect(port.impacts, isEmpty);
    });

    test('两重门都满足才发声', () async {
      final port = RecordingHapticsPort();
      final service = HapticsService(port, enabled: true);
      await service.impact(HapticStrength.heavy);
      await service.success();
      expect(port.impacts, <HapticStrength>[HapticStrength.heavy]);
      expect(port.successCount, 1);
    });

    test('端口抛异常绝不影响对局（静默吞掉）', () async {
      final port = RecordingHapticsPort()..throwOnCall = true;
      final service = HapticsService(port);
      // 不应抛出。
      await service.impact(HapticStrength.medium);
      await service.success();
    });
  });

  group('导播：该触发的三个场景（正向）', () {
    test('受 HP 伤害 → medium', () {
      final port = RecordingHapticsPort();
      final d = HapticsDirector(service: HapticsService(port));
      d.onEvent(
        const PlayerDamaged(
          sourceType: 'enemyProjectile',
          shieldDamage: 0,
          hpDamage: 12,
          hpAfter: 88,
          shieldAfter: 0,
        ),
      );
      expect(port.impacts, <HapticStrength>[HapticStrength.medium]);
    });

    test('确认风险门 → light（超时保底不算确认）', () {
      final port = RecordingHapticsPort();
      final d = HapticsDirector(service: HapticsService(port));
      d.onEvent(
        const RiskSelected(
          gateId: 'RG-55',
          optionId: 'RG-SUPPLY',
          wasTimeout: false,
        ),
      );
      expect(port.impacts, <HapticStrength>[HapticStrength.light]);
    });

    test('Boss 击败 → success', () {
      final port = RecordingHapticsPort();
      final d = HapticsDirector(service: HapticsService(port));
      d.onEvent(const BossDefeated());
      expect(port.successCount, 1);
      expect(port.impacts, isEmpty);
    });
  });

  group('导播：绝不该触发的场景（反向）', () {
    test('护盾独立受击（hpDamage == 0）不触发', () {
      final port = RecordingHapticsPort();
      final d = HapticsDirector(service: HapticsService(port));
      d.onEvent(
        const PlayerDamaged(
          sourceType: 'enemyProjectile',
          shieldDamage: 12,
          hpDamage: 0, // 只掉护盾
          hpAfter: 100,
          shieldAfter: 18,
        ),
      );
      expect(port.impacts, isEmpty, reason: '裁决点名排除"护盾独立受击"');
    });

    test('普通敌人击毁不触发', () {
      final port = RecordingHapticsPort();
      final d = HapticsDirector(service: HapticsService(port));
      d.onEvent(
        const EnemyDestroyed(
          entityId: EntityId(EntityKind.enemy, 7),
          enemyId: 'EN-SCOUT',
          position: Vec2(100, 200),
          isElite: false,
        ),
      );
      expect(port.impacts, isEmpty, reason: '裁决点名排除"普通击杀"');
    });

    test('射击 / 命中 / 每发子弹不触发', () {
      final port = RecordingHapticsPort();
      final d = HapticsDirector(service: HapticsService(port));
      for (var i = 0; i < 50; i++) {
        d.onEvent(
          WeaponHit(
            weaponId: 'UP-PULSE',
            sourceId: const EntityId(EntityKind.player, 0),
            targetId: EntityId(EntityKind.enemy, i),
            critical: false,
            damage: 5,
            targetEnemyId: 'EN-SCOUT',
          ),
        );
      }
      expect(port.impacts, isEmpty, reason: '裁决点名排除"射击、每发子弹"');
    });

    test('超时保底的风险门不算"确认"，不触发', () {
      final port = RecordingHapticsPort();
      final d = HapticsDirector(service: HapticsService(port));
      d.onEvent(
        const RiskSelected(
          gateId: 'RG-55',
          optionId: 'RG-SUPPLY',
          wasTimeout: true,
        ),
      );
      expect(port.impacts, isEmpty, reason: '玩家没有操作，不应给确认反馈');
    });
  });
}
