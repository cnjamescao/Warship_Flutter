// ================================================================
// lib/game/presentation/visual_router.dart
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md
//   「`AssetLoader` 必须在首次播放/渲染前将 `eventBindings` 解析为
//     不可变表，且只按 `event + when` 条件匹配，**禁止仅凭
//     `triggerEvents`、文件名或显示文本选资源**。」
//   Spec/03_素材/Warship_v2.0素材清单与制作规范.md §1.1：
//   「`eventBindings` 是**唯一允许消费的精确路由**……
//     `PresentationSystem` 根据本规范第 5.1 节和 `eventBindings` 将
//     DomainEvent 转为 `renderState`/`cueId`；
//     两者均不得猜测文件名或用显示文本查资源。」
//
// 本类就是那个 "PresentationSystem" 的视觉半边：
//   每帧消费 `DomainEvent` → `resolveVisuals(event, params)` →
//   记下 `实体 → (assetId, renderState)` 的覆盖。
//
// 设计取舍：**覆盖优先、快照回退**。
//   绑定表能解析出资源时用绑定表的结果；解析不出时回退到
//   `RenderSnapshot` 里域层给出的 `assetId`/`visualState`。
//   这样既让绑定表真正成为路由（协议要求），
//   又不会因为某条绑定缺失而让实体变成空白。
// ================================================================

import '../core/domain_event.dart';
import '../core/event_bus.dart';
import '../infrastructure/asset_loader.dart';
import '../infrastructure/audio_director.dart' show conditionalParamsOf;

/// 一次解析出的视觉路由结果。
class RoutedVisual {
  const RoutedVisual({
    required this.assetId,
    required this.renderState,
    required this.eventType,
    required this.frameIndex,
    this.transientMs,
  });

  final String assetId;
  final String? renderState;

  /// 产生它的领域事件类型（诊断用）。
  final String eventType;

  /// 出现该事件的帧号 —— 用于"临时状态到期后回退"。
  final int frameIndex;

  /// 该资源是否声明了 `transientMs`；到期后应回退到快照状态。
  final int? transientMs;

  bool isExpiredAt(int frame, double secondsPerFrame) {
    if (transientMs == null) {
      return false;
    }
    final elapsed = (frame - frameIndex) * secondsPerFrame * 1000;
    return elapsed > transientMs!;
  }
}

/// 玩家实体的固定路由键（领域事件不带"这是玩家"以外的标识时用它）。
const String kPlayerRouteKey = '__player__';

class VisualRouter {
  VisualRouter({required this.table});

  final AssetBindingTable table;

  /// 实体键 → 最近一次由绑定表解析出的视觉。
  final Map<String, RoutedVisual> _routes = <String, RoutedVisual>{};

  /// 被绑定表覆盖过的路由次数（诊断/测试用）。
  int routedCount = 0;

  /// 绑定表解析不出、因而回退快照的次数。
  int fallbackCount = 0;

  int get activeRouteCount => _routes.length;

  /// 消费一帧事件，刷新路由表。
  void consume(List<StampedEvent> events) {
    for (final stamped in events) {
      final params = conditionalParamsOf(stamped.event);
      final visuals = table.resolveVisuals(stamped.event.eventType, params);
      if (visuals.isEmpty) {
        continue;
      }
      final chosen = visuals.first;
      final key = _routeKeyFor(stamped.event);
      if (key == null) {
        continue;
      }
      _routes[key] = RoutedVisual(
        assetId: chosen.assetId.value,
        renderState: chosen.renderState,
        eventType: stamped.event.eventType,
        frameIndex: stamped.frameIndex,
        transientMs: chosen.transientMs,
      );
      routedCount++;
    }
  }

  /// 取某个实体的路由结果；没有则返回 null（调用方回退快照）。
  ///
  /// 临时状态过期后返回 null，让调用方回退到快照里的稳定状态 ——
  /// 这正是协议 T-ASSET-02 要求的「120 ms hit 自动恢复至最后
  /// Vital/Defense 状态」。
  RoutedVisual? routeFor(String entityId, {int? currentFrame}) {
    final route = _routes[entityId];
    if (route == null) {
      return null;
    }
    if (currentFrame != null &&
        route.isExpiredAt(currentFrame, 1 / 60)) {
      _routes.remove(entityId);
      return null;
    }
    return route;
  }

  RoutedVisual? get playerRoute => routeFor(kPlayerRouteKey);

  void clear() => _routes.clear();

  /// 把领域事件映射到"路由键"。
  ///
  /// **只覆盖 Dart 里确实存在的事件类。** manifest 里还声明了
  /// `EnemyVitalStateChanged` / `EnemyDefenseStateChanged` / `DashStarted`
  /// / `DashEnded` 等事件名，但 Domain **从未定义或发射**它们 ——
  /// 那正是死路由扫描发现的一类问题，这里不假装能路由。
  String? _routeKeyFor(DomainEvent event) {
    switch (event) {
      // 所有敌人事件都携带 `entityId`，因此**统一用它**做键。
      // 早先我让 EnemySpawned/Destroyed 用 enemyId 字符串，
      // 而 EnemyDamaged 用 entityId —— 结果同一敌人在两条路由下
      // 有两个键，先写的路由永远查不到。这是测试抓出来的真实缺陷。
      case EnemySpawned(:final entityId):
      case EnemyDestroyed(:final entityId):
      case EnemyDamaged(:final entityId):
      case EnemyBreached(:final entityId):
      case EnemyAttackTelegraphed(:final entityId):
      case EnemyAttackFired(:final entityId):
        return entityId.toString();
      // 玩家类事件不携带玩家 ID，用固定键。
      case PlayerDamaged():
      case PlayerVitalStateChanged():
        return kPlayerRouteKey;
      default:
        return null;
    }
  }
}
