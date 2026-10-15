// ================================================================
// test/unit/presentation/asset_preload_integration_test.dart —— F-26-02（P0）
// ================================================================
// 玩家实测：战场只见两个青色圆点 + 紫色三角形，辨认不出战舰。
//
// 事实：正式素材 `GFX-PLAYER-BASE` 已交付（512×512 完整蓝白战舰），
// 构建产物里也**确实存在**该 PNG。因此这不是素材缺失，
// 而是**加载/渲染接入故障**。
//
// 本文件做**真实预载**（`tester.runAsync` 里执行真异步 I/O），
// 断言首屏关键资源在首帧即可取 —— 这正是裁决要求的
// 「新增带真实预载的集成/端侧验证：首帧读取缓存，断言玩家图片可取」。
//
// ⚠️ 与 `test/support/v2_harness.dart` 里关掉预载的做法不同：
// 那里关预载是因为普通 `testWidgets` 的假异步区里 `rootBundle` 永不完成；
// 这里用 `runAsync` 进入**真实异步环境**，因此可以真正加载。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/presentation/asset_cache.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    manifest = (await loadV2CatalogForTests()).manifest;
  });

  testWidgets('F-26-02 真实预载 firstRun 后，玩家机体图片在首帧即可取', (tester) async {
    final cache = VisualAssetCache(manifest: manifest);

    await tester.runAsync(() async {
      await cache.loadGroup(AssetLoadGroup.firstRun);
    });

    // 把失败逐条打出来 —— 静态断言只说"是 null"，说不出为什么。
    if (cache.failures.isNotEmpty) {
      // ignore: avoid_print
      print('载入失败 ${cache.failures.length} 条：');
      for (final f in cache.failures.take(10)) {
        // ignore: avoid_print
        print('  $f');
      }
    }
    // ignore: avoid_print
    print('成功载入 ${cache.loadedCount} 张');

    expect(
      cache.imageFor('GFX-PLAYER-BASE', 'default'),
      isNotNull,
      reason: '首屏关键资源 GFX-PLAYER-BASE 必须能取到图 —— '
          '取不到玩家就会退化成"两个圆点"（F-26-02 的现场表现）',
    );
  });

  testWidgets('F-26-02 首屏敌人与投射物素材也可取', (tester) async {
    final cache = VisualAssetCache(manifest: manifest);
    await tester.runAsync(() async {
      await cache.loadGroup(AssetLoadGroup.firstRun);
    });

    // 取玩家之外的首屏关键实体：至少一个敌机、一个我方投射物。
    final firstRunVisuals = manifest
        .inLoadGroup(AssetLoadGroup.firstRun)
        .where((r) => r.isVisual)
        .map((r) => r.assetId.value)
        .toList();
    expect(firstRunVisuals, isNotEmpty, reason: 'firstRun 分组应有图形资源');

    final unresolved = <String>[];
    for (final id in firstRunVisuals) {
      final record = manifest.lookup(id)!;
      final state = record.states.isNotEmpty ? record.states.first : null;
      if (cache.imageFor(id, state) == null) {
        unresolved.add(id);
      }
    }

    expect(
      unresolved,
      isEmpty,
      reason: 'firstRun 分组里这些资源取不到图，玩家会看到占位图形：'
          '$unresolved',
    );
  });
}
