// ================================================================
// test/unit/presentation/visual_router_test.dart
// ================================================================
// 验证表现层的资源解析**真的走 eventBindings**（协议明文要求）：
//   「AssetLoader 必须…只按 event + when 条件匹配，
//     禁止仅凭 triggerEvents、文件名或显示文本选资源。」
//
// 上一轮我凭印象写这个用例的事件构造，产生 19 个编译错误。
// 本轮先把 domain_event.dart 的构造签名读准再写 —— 签名见下。
//
// ⚠️ 当前状态：本类已实现，但**尚未接进 BattlefieldComponent**。
//   本用例证明的是"路由器行为正确"，不是"游戏已按绑定表显示"。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/core/domain_event.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/infrastructure/asset_loader.dart';
import 'package:warship_flutter/game/presentation/visual_router.dart';

const Vec2 kPos = Vec2(960, 400);

StampedEvent stamped(DomainEvent event, {int eventIndex = 1, int frame = 10}) =>
    StampedEvent(
      event: event,
      runId: 'test',
      frameIndex: frame,
      eventIndex: eventIndex,
    );

void main() {
  late AssetBindingTable table;

  setUpAll(() {
    final json =
        jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
            as Map<String, Object?>;
    final manifest = AssetManifest.parse(json).requireValue;
    table = const AssetLoader().build(manifest);
  });

  test('敌人受伤事件产生实体级路由', () {
    final router = VisualRouter(table: table);
    const enemy = EntityId(EntityKind.enemy, 7);

    router.consume(<StampedEvent>[
      stamped(
        const EnemyDamaged(
          entityId: enemy,
          enemyId: 'EN-SCOUT',
          damage: 5,
          hpAfter: 10,
          hpMax: 32,
        ),
      ),
    ]);

    final route = router.routeFor(enemy.toString());
    expect(route, isNotNull, reason: '受击应产生覆盖');
    expect(route!.assetId, isNotEmpty);
    expect(route.eventType, 'EnemyDamaged');
    expect(router.routedCount, greaterThan(0));
  });

  test('玩家事件用固定键路由（事件不携带玩家 ID）', () {
    final router = VisualRouter(table: table);

    router.consume(<StampedEvent>[
      stamped(
        const PlayerDamaged(
          sourceType: 'projectile',
          shieldDamage: 12,
          hpDamage: 0,
          hpAfter: 100,
          shieldAfter: 20,
          direction: 'north',
        ),
      ),
    ]);

    expect(router.playerRoute, isNotNull);
    expect(router.routeFor(kPlayerRouteKey), isNotNull);
  });

  test('绑定表解析不出的事件不产生路由（调用方回退快照）', () {
    final router = VisualRouter(table: table);

    router.consume(<StampedEvent>[
      stamped(
        const RunStarted(
          seed: 0x4E454F4E0001,
          prngAlgorithm: 'pcg32-xsh-rr',
          contentVersion: '2.0.4-release',
        ),
      ),
    ]);

    expect(router.routedCount, 0);
    expect(router.activeRouteCount, 0);
  });

  test('临时状态过期后路由失效（协议 T-ASSET-02 的自动恢复）', () {
    final router = VisualRouter(table: table);
    const enemy = EntityId(EntityKind.enemy, 3);

    router.consume(<StampedEvent>[
      stamped(
        const EnemyDamaged(
          entityId: enemy,
          enemyId: 'EN-SCOUT',
          damage: 5,
          hpAfter: 10,
          hpMax: 32,
        ),
      ),
    ]);

    final route = router.routeFor(enemy.toString());
    expect(route, isNotNull);

    if (route!.transientMs != null) {
      expect(
        router.routeFor(enemy.toString(), currentFrame: 100000),
        isNull,
        reason: '瞬态状态过期后应回退快照状态',
      );
    } else {
      expect(
        router.routeFor(enemy.toString(), currentFrame: 100000),
        isNotNull,
        reason: '非瞬态状态不应过期',
      );
    }
  });

  test('clear 清空全部路由', () {
    final router = VisualRouter(table: table)
      ..consume(<StampedEvent>[
        stamped(
          const PlayerVitalStateChanged(
            hp: 20,
            hpMax: 100,
            shield: 0,
            shieldMax: 30,
            cause: 'damage',
          ),
        ),
      ]);
    expect(router.activeRouteCount, greaterThan(0));
    router.clear();
    expect(router.activeRouteCount, 0);
  });

  test('后到的事件覆盖先到的（同一实体只保留最新状态）', () {
    final router = VisualRouter(table: table);
    const enemy = EntityId(EntityKind.enemy, 9);

    router.consume(<StampedEvent>[
      stamped(
        const EnemySpawned(
          entityId: enemy,
          enemyId: 'EN-SCOUT',
          position: kPos,
          isElite: false,
        ),
      ),
    ]);
    final first = router.routeFor(enemy.toString());

    router.consume(<StampedEvent>[
      stamped(
        const EnemyDestroyed(
          entityId: enemy,
          enemyId: 'EN-SCOUT',
          position: kPos,
          isElite: false,
        ),
        eventIndex: 2,
        frame: 20,
      ),
    ]);
    final second = router.routeFor(enemy.toString());

    expect(second, isNotNull);
    expect(second!.eventType, 'EnemyDestroyed');
    expect(second.eventType, isNot(first?.eventType));
  });

  test('受击预警也走路由（伤害前必须有可读表现）', () {
    final router = VisualRouter(table: table);
    const enemy = EntityId(EntityKind.enemy, 11);

    router.consume(<StampedEvent>[
      stamped(
        const EnemyAttackTelegraphed(
          entityId: enemy,
          enemyId: 'EN-SNIPER',
          attackId: 'sniper_line',
          position: kPos,
          telegraphSeconds: 0.9,
        ),
      ),
    ]);

    final route = router.routeFor(enemy.toString());
    expect(route, isNotNull, reason: '预警必须能解析出表现');
    expect(route!.eventType, 'EnemyAttackTelegraphed');
  });
}
