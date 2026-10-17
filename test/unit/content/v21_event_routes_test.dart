// ================================================================
// test/unit/content/v21_event_routes_test.dart —— V21-ROUTE
// ================================================================
// **架构位置**：Content 层测试。验证蓝图 §2.2「新增资源路由不可省略」的
// **7 类事件路由**确实接上了 —— 这是 v2.1 默认要求 R2.1 的"**接线断言**"：
// **不只断言"配置里写了"，而是断言"事件能查到对应资源"**。
//
// 为什么必须单独测：v2.0 反复出现"**声明了没接上**"（触感开关、动效设置、
// `bossSystem` 漏传导致 Boss 永不出现等）。资源的 `eventBindings` 写错
// **不会报错** —— 只会安静地不画、不响。
//
// 每条断言都能失败（R6.2）：删掉任一条路由，或用错 when 条件，本用例即失败。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;

/// 查询「某事件在给定 when 条件下」命中的**全部** Asset ID。
Set<String> routesFor(String event, [Map<String, String> when = const {}]) {
  final hit = <String>{};
  for (final record in manifest.records) {
    for (final b in record.eventBindings) {
      if (b.event != event) {
        continue;
      }
      // manifest 只允许**等值** when 条件（蓝图 §2.2）。
      final matches = when.entries.every((e) => '${b.when[e.key]}' == e.value);
      final extra = b.when.keys.where((k) => !when.containsKey(k));
      if (matches && extra.every((k) => '${b.when[k]}' == '')) {
        hit.add(record.assetId.value);
      }
    }
  }
  return hit;
}

void main() {
  // rootBundle 需要绑定（与生产加载路径一致）。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 走与生产**完全相同**的加载路径（不另造夹具）。
    final catalog = await loadV2CatalogForTests();
    manifest = catalog.manifest;
  });

  test('V21-ROUTE-01 AutoUpgradeGranted → 强化提示图 + 强化 cue', () {
    final ids = routesFor('AutoUpgradeGranted');
    expect(ids, contains('UI-V21-UPGRADE-NOTICE'));
    expect(ids, contains('SFX-V21-UPGRADE-GAIN'));
  });

  test('V21-ROUTE-02 WeaponHit 按 weaponStyleId 精确路由五条命中', () {
    // 每一种形态都必须**恰好**命中自己的命中图与命中 cue。
    const expectMap = <String, String>{
      'prism': 'GFX-V21-WPN-PRISM-IMPACT',
      'arc': 'GFX-V21-WPN-ARC-IMPACT',
      'plasma': 'GFX-V21-WPN-PLASMA-IMPACT',
      'needle': 'GFX-V21-WPN-NEEDLE-IMPACT',
      'missile': 'GFX-V21-WPN-MISSILE-IMPACT',
    };
    for (final e in expectMap.entries) {
      final ids = routesFor('WeaponHit', <String, String>{
        'weaponStyleId': e.key,
      });
      expect(
        ids,
        contains(e.value),
        reason: 'weaponStyleId=${e.key} 未路由到 ${e.value}',
      );
      expect(
        ids,
        contains('SFX-V21-WPN-${e.key.toUpperCase()}-IMPACT'),
        reason: 'weaponStyleId=${e.key} 未路由到对应命中 cue',
      );
      // **交叉污染检查**：不得命中别的形态的命中图。
      for (final other in expectMap.values.where((v) => v != e.value)) {
        expect(
          ids,
          isNot(contains(other)),
          reason: 'weaponStyleId=${e.key} 误命中 $other',
        );
      }
    }
  });

  test('V21-ROUTE-03 PlayerDamaged 按 damageLayer 稳定枚举路由', () {
    // 蓝图 §2.2：manifest 只允许等值 when，因此必须是 shield / hp 两个**稳定枚举**
    // （不得做数值表达式比较）。
    final shield = routesFor('PlayerDamaged', <String, String>{
      'damageLayer': 'shield',
    });
    expect(shield, contains('GFX-V21-PLAYER-SHIELD-HIT'));
    expect(shield, contains('SFX-V21-SHIELD-HIT'));
    expect(shield, isNot(contains('GFX-V21-PLAYER-HP-HIT')));

    final hp = routesFor('PlayerDamaged', <String, String>{
      'damageLayer': 'hp',
    });
    expect(hp, contains('GFX-V21-PLAYER-HP-HIT'));
    expect(hp, contains('SFX-V21-HP-HIT'));
    expect(hp, isNot(contains('GFX-V21-PLAYER-SHIELD-HIT')));
  });

  test('V21-ROUTE-04 PlayerVitalStateChanged 低血/濒危为不同资源', () {
    expect(
      routesFor('PlayerVitalStateChanged', <String, String>{
        'hpVisualState': 'low',
      }),
      contains('GFX-V21-PLAYER-LOW'),
    );
    expect(
      routesFor('PlayerVitalStateChanged', <String, String>{
        'hpVisualState': 'critical',
      }),
      contains('GFX-V21-PLAYER-CRITICAL'),
    );
  });

  test('V21-ROUTE-05 EnemyDestroyed → 击毁序列', () {
    expect(routesFor('EnemyDestroyed'), contains('GFX-V21-ENEMY-DESTROY'));
  });

  test('V21-ROUTE-06 SectorClearStarted → 清场提示图 + 清场 cue', () {
    final ids = routesFor('SectorClearStarted');
    expect(ids, contains('UI-V21-SECTOR-CLEAR-NOTICE'));
    expect(ids, contains('SFX-V21-SECTOR-CLEAR'));
  });

  test('V21-ROUTE-07 RunEnded 按 resultTier 三档独立奖章与 cue', () {
    for (final tier in <String>['gold', 'silver', 'bronze']) {
      final ids = routesFor('RunEnded', <String, String>{'resultTier': tier});
      expect(
        ids,
        contains('UI-V21-RESULT-MEDAL-${tier.toUpperCase()}'),
        reason: '$tier 档未路由到对应奖章',
      );
      expect(
        ids,
        contains('SFX-V21-MEDAL-${tier.toUpperCase()}'),
        reason: '$tier 档未路由到对应 cue',
      );
      // 三档必须**互不串档**。
      for (final other in <String>['gold', 'silver', 'bronze']
          .where((t) => t != tier)) {
        expect(
          ids,
          isNot(contains('UI-V21-RESULT-MEDAL-${other.toUpperCase()}')),
          reason: '$tier 档误命中 $other 档奖章',
        );
      }
    }
  });
}
