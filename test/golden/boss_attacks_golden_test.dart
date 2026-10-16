// ================================================================
// test/golden/boss_attacks_golden_test.dart —— F-38 四条 Boss Golden
// ================================================================
// 负责人批复：「补**四条 Golden**」。F-07 强制预警集合中的 Boss 四招：
//   `boss_fan` / `boss_charge` / `boss_ring` / `boss_laser`
//
// **F-39 修复前**：应用流中 `V2Bootstrap` 从未传入 `bossSystem`，
// Boss 永不生成，因此这四条基线**无法经真实应用流产出**。
// 修复后（`bossSeenAt = 150.0`）本文件走**真实应用流**捕捉预警帧。
//
// ⚠️ 流程与既有 golden 一致（F-06/F-16）：CI 排除 `golden` tag、
// 不作为阻断项；基线在 macOS 本机生成，发布前由 QA **人工复核**；
// **真实设备 Release 截图/录屏仍是发布阻断证据**。
// ================================================================

@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';
import 'package:warship_flutter/game/presentation/asset_cache.dart';

import '../support/v2_harness.dart';

const Map<String, String> kBossAttacks = <String, String>{
  'boss_fan': 'boss_fan.png',
  'boss_charge': 'boss_charge.png',
  'boss_ring': 'boss_ring.png',
  'boss_laser': 'boss_laser.png',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;
  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  /// **F-40 关键**：用 `tester.runAsync` 把素材**真实加载**进缓存，
  /// 再注入应用 —— 否则表现层走**矢量占位**，Golden 截到的是
  /// "无素材回退图"，不能作为视觉验收证据。
  ///
  /// （`testWidgets` 处于假异步区，`rootBundle` 的真实 I/O 永不完成，
  /// 所以必须用 `runAsync` 才能真正把贴图读进内存。）
  Future<VisualAssetCache> preloadRealAssets(WidgetTester tester) async {
    final cache = VisualAssetCache(manifest: catalog.manifest);
    await tester.runAsync(() async {
      await cache.loadGroup(AssetLoadGroup.firstRun);
      await cache.loadGroup(AssetLoadGroup.lazy);
    });
    return cache;
  }

  for (final entry in kBossAttacks.entries) {
    testWidgets('Golden：Boss 招式 ${entry.key} 预警帧', (tester) async {
      final cache = await preloadRealAssets(tester);
      await mountV2App(tester, catalog, assetCache: cache);
      await tapText(tester, '开始战斗');
      await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

      final screen = tester.widget<V2RunScreen>(find.byType(V2RunScreen));
      final rt = screen.runtime;
      var captured = false;

      // 覆盖 150（Boss 入场）之后的一段：招式按 loop 轮转。
      for (var i = 0; i < 400 * 60 && !captured; i++) {
        // 选卡 + 保持存活（不干预风险门 —— 由 timeoutFallback 自动解决）。
        if (rt.currentOffer != null) {
          rt.selectDraftCard(0);
        }
        rt.player.health.current = rt.player.health.max;
        // ⚠️ 必须**逐帧小幅削减 Boss 血量**才能进入 P2/P3 ——
        // `boss_ring` 在 P2 的招式循环、`boss_laser` 在 P3。
        // 实测：不削减时 Boss 一直停在 P1，只能捕捉到 `fan` / `charge`。
        // 保留 20% 血量下限，避免归零后进入结算、错过后续招式。
        final boss = rt.boss;
        if (boss != null && !boss.isDefeated) {
          final floor = (boss.health.max * 0.20).floor();
          if (boss.health.current > floor) {
            boss.health.current = (boss.health.current - 1).clamp(
              floor,
              boss.health.max,
            );
          }
        }
        await pumpV2(tester, frames: 1);

        if (rt.snapshot().telegraphs.any((t) => t.attackId == entry.key)) {
          captured = true;
        }
      }

      expect(
        captured,
        isTrue,
        reason: '应在 Boss 入场后捕捉到 ${entry.key} 的预警帧',
      );
      // **F-40 断言 ①**：该招式的**预警素材已真实加载**。
      final assetId = rt.director.rowCount > 0
          ? (rt.snapshot().telegraphs
                    .firstWhere((t) => t.attackId == entry.key)
                    .assetId ??
                '')
          : '';
      expect(
        assetId,
        isNotEmpty,
        reason: '${entry.key} 的预警应携带素材 ID',
      );
      expect(
        cache.imageFor(assetId, 'default'),
        isNotNull,
        reason: 'F-40：${entry.key} 的预警素材 $assetId **未真实加载** —— '
            'Golden 会是"无素材回退图"，不能作为视觉证据',
      );

      // **F-40 断言 ②**：该素材**确实被绘制**（读渲染器自身的绘制记录）。
      //
      // 说明：`game` getter 定义在 `V2RunScreen` 的**私有 State 类**上，
      // 测试无法静态引用，因此这里用 `dynamic` 分派取到它 ——
      // 这只是绕过私有类型的可见性，getter 本身是公开的、只读的。
      final state = tester.state(find.byType(V2RunScreen));
      final game = (state as dynamic).game;
      final drawn =
          (game.battlefield.drawnAssetMaxRadius as Map<String, double>).keys
              .where((k) => k.startsWith(assetId))
              .toList();
      expect(
        drawn,
        isNotEmpty,
        reason: 'F-40：$assetId 捕获帧内**未被实际绘制**（drawnAssetMaxRadius '
            '中无记录）',
      );

      // ignore: avoid_print
      print('Boss 招式基线捕捉到：${entry.key} asset=$assetId drawn=$drawn');

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('baselines/${entry.value}'),
      );
      await unmountV2App(tester);
    });
  }
}
