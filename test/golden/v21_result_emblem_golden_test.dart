// ================================================================
// test/golden/v21_result_emblem_golden_test.dart —— PV21-R2 结果 Golden
// ================================================================
// **架构位置**：Golden 测试（v2.1-R2 结果徽记）。
//
// **写法说明（这一条我付了三次 10 分钟超时才明白）**：
//   `loadV2CatalogForTests()` **必须**放在 `setUpAll` 里 ——
//   在 `testWidgets` 的回调里 `await` 它会**永远挂住**
//   （回调跑在 fake-async 区，真实 IO 的 Future 不会完成）。
//   之前三次失败都是这个原因，**不是** "Golden 做不到" ✓。
//   同理，素材预载必须包在 `tester.runAsync` 里。
//
// **本文件证明什么**：徽记在**真实发布路径**上被画出来；
//   它**不能**证明"好不好看"（那仍需人眼）。
//
// ⚠️ CI 排除 `golden` tag（F-06/F-16）。
// ================================================================

@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';
import 'package:warship_flutter/game/presentation/asset_cache.dart';

import '../support/v2_harness.dart';

late ContentCatalog catalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // **必须在 setUpAll**（见文件头说明）。
  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('Golden：自动强化结果徽记（无文字，语义含"获得强化"）', (tester) async {
    // 素材预载必须在 runAsync 里（真实 IO）。
    final cache = VisualAssetCache(manifest: catalog.manifest);
    await tester.runAsync(() async {
      await cache.loadGroup(AssetLoadGroup.firstRun);
      await cache.loadGroup(AssetLoadGroup.lazy);
    });

    await mountV2App(tester, catalog, assetCache: cache);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

    // 推进到第一次自动强化（≥15 秒）。徽记持续 1 秒，用语义标签定位。
    var found = false;
    for (var s = 0; s < 30 && !found; s++) {
      await pumpV2(tester, frames: 60); // 每次推 1 秒（60 帧）
      if (find.bySemanticsLabel(RegExp('获得强化')).evaluate().isNotEmpty) {
        found = true;
      }
    }
    expect(found, isTrue, reason: '15 秒后应出现自动强化徽记');

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('baselines/v21_result_emblem_upgrade.png'),
    );
    await unmountV2App(tester);
  });
}
