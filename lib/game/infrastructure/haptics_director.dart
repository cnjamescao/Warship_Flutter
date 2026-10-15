// ================================================================
// lib/game/infrastructure/haptics_director.dart
// ================================================================
// F-10 裁决把触感限制在**恰好三个场景**：
//   1. `hpDamage > 0`（即**真的掉 HP**）→ medium impact
//   2. 确认风险门                                  → light impact
//   3. Boss 击败                                   → success / heavy
//
// **明确不得触发**：护盾独立受击、普通击杀、射击、每发子弹。
//
// 把这些写成一张**显式白名单**是有意的：默认拒绝（不匹配任何一条即
// 不发声）比默认允许安全得多 —— 以后新增事件时不会"顺手"震一下。
// ================================================================

import '../core/domain_event.dart';
import '../core/event_bus.dart';
import 'haptics_port.dart';

/// 把领域事件翻译成触感调用。
class HapticsDirector {
  HapticsDirector({required this.service});

  final HapticsService service;

  /// 已处理的触感次数（测试与调试用）。
  int impactCount = 0;
  int successCount = 0;

  /// 批量处理（与 `AudioDirector.handleAll` 同一路径）。
  void handleAll(Iterable<StampedEvent> events) {
    for (final stamped in events) {
      onEvent(stamped.event);
    }
  }

  /// 处理一条事件。**默认拒绝**：只有白名单里的三种情形才发声。
  void onEvent(DomainEvent event) {
    switch (event) {
      // 1. 受 HP 伤害（medium）。
      //    注意判据是 `hpDamage > 0` —— **护盾独立受击时 hpDamage 为 0**，
      //    因此只掉护盾不会触发。这正是裁决点名要排除的情形。
      case PlayerDamaged(:final hpDamage) when hpDamage > 0:
        impactCount++;
        service.impact(HapticStrength.medium);

      // 2. 确认风险门（light）。
      //    超时保底不是"确认"，玩家没有操作，因此不触发。
      case RiskSelected(:final wasTimeout) when !wasTimeout:
        impactCount++;
        service.impact(HapticStrength.light);

      // 3. Boss 击败（success / heavy）。
      case BossDefeated():
        successCount++;
        service.success();

      // 其余一律不触发：护盾受击、普通敌人击毁、射击、命中……
      default:
        break;
    }
  }
}
