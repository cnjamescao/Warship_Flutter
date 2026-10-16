// ================================================================
// test/support/v2_harness.dart —— v2.0 应用层的 widget 挂载
// ================================================================
// 背景：第 35 轮发现仓库里没有任何测试引用 v2.0 应用层；
// 36–39 轮尝试挂载均挂起 10 分钟。第 40 轮用 `print` 打点钉死位置：
//
//   **挂起点是 `await V2Bootstrap().loadCatalog()` 本身，
//     不在部件树里。**
//
// 根因（Flutter 测试的经典陷阱）：
//   `testWidgets` 的函数体运行在**假异步区**（fake async zone）。
//   `loadCatalog()` 走 `rootBundle.loadString`，那是**真实 I/O** ——
//   其 Future 在假异步区里**永远不会完成**，于是 await 一直挂着。
//   而同样的调用写在普通 `test()` 或 `setUpAll` 里（真异步）则 1 秒通过。
//
// 因此正确做法是：**在 `setUpAll` 里预载内容目录**（真异步区），
//   再在 `testWidgets` 里用已加载好的目录挂载。绝不在
//   `testWidgets` 体内 await 任何真实 I/O。
//
// 另一个坑：v2 应用有持续运行的加载动画与游戏循环，帧永远排不完，
//   **不能用 `pumpAndSettle()`**（会等到超时）。一律用有界的 `pumpV2`。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warship_flutter/app/v2_app_flow.dart';
import 'package:warship_flutter/app/v2_bootstrap.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';
import 'package:warship_flutter/game/presentation/asset_cache.dart';
import 'package:warship_flutter/game/infrastructure/audio_port.dart';
import 'package:warship_flutter/game/infrastructure/progress_store.dart';

/// **必须**在 `setUpAll` 里调用（真异步区），不要在 `testWidgets` 体内调用。
///
/// 走的是与生产**完全相同**的 `rootBundle` 路径，不另造夹具。
Future<ContentCatalog> loadV2CatalogForTests() =>
    const V2Bootstrap().loadCatalog();

/// 有界推进帧。v2 应用永远处于"有待处理帧"的状态，不能等静止。
Future<void> pumpV2(
  WidgetTester tester, {
  int frames = 1,
  Duration step = const Duration(microseconds: 16667),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 用**已预载**的目录挂载 v2.0 应用，停在首页。
///
/// 音频与存档一律注入替身：默认实现会走平台通道，在假异步区同样不可用。
Future<void> mountV2App(
  WidgetTester tester,
  ContentCatalog catalog, {
  int seed = 0x4E454F4E0001,
  KeyValueStore? store,
  VisualAssetCache? assetCache,
}) async {
  // SharedPreferences 也必须 mock，否则 initState 里的存档读取会等平台通道。
  SharedPreferences.setMockInitialValues(<String, Object>{});

  await tester.pumpWidget(
    MaterialApp(
      home: V2AppFlow(
        catalog: catalog,
        seed: seed,
        audioPort: SilentAudioPort(),
        store: store ?? InMemoryKeyValueStore(),
        // 关键：关掉资源预载。预载走 Flame.images.load → rootBundle，
        // 是真实 I/O，在 testWidgets 的假异步区里永不完成。
        // 关掉后表现层走矢量占位，规则不受影响（架构 §7）。
        preloadAssets: false,
        // **F-40**：若调用方用 `tester.runAsync` 真实预载过素材，
        // 注入后 `imageFor` 即返回**正式贴图**，画面走发布路径 ——
        // 这是产出有效视觉验收 Golden 的前置。
        assetCache: assetCache,
      ),
      debugShowCheckedModeBanner: false,
    ),
  );
  await pumpV2(tester, frames: 30);
}

/// 按**游戏内时间**推进。
///
/// 逻辑步长是 1/60 秒，因此 N 帧 = N/60 游戏秒。
/// 注意：升级草案 / 风险门 / 暂停会**冻结全部逻辑时钟**，
/// 冻结期间推进不会让游戏时间前进 —— 必须先把这些相位处理掉。
Future<void> advanceGameSeconds(WidgetTester tester, double seconds) =>
    pumpV2(tester, frames: (seconds * 60).round());

/// 推进游戏时间，**遇到升级草案就自动选第一张**。
///
/// 必要性：草案 / 风险门 / 暂停会**冻结全部逻辑时钟**，不处理就永远
/// 走不到后面的时间点（例如 55 秒的风险门）。返回自动选卡次数。
///
/// 卡片在树里是 `InkWell` 的下标 1..3（下标 0 是 HUD 的暂停按钮）。
Future<int> advanceAutoPicking(WidgetTester tester, double seconds) async {
  var picks = 0;
  for (var i = 0; i < seconds.round(); i++) {
    await pumpV2(tester, frames: 60);
    // 有界重试：最多处理 8 次，避免任何情况下死循环。
    for (var attempt = 0; attempt < 8; attempt++) {
      if (find.text('选择强化').evaluate().isEmpty) {
        break;
      }
      final cards = find.byType(InkWell);
      if (cards.evaluate().length <= 1) {
        break;
      }
      await tester.tap(cards.at(1));
      await pumpV2(tester, frames: 5);
      picks++;
    }
  }
  return picks;
}


/// 卸载 v2 应用。
///
/// **凡进入过简报/对局的用例都应调用** —— 那些界面用 `Timer`
/// 驱动倒计时，测试结束时若仍有未取消的定时器，
/// `flutter_test` 会以 "Pending timers" 报失败。
/// 换成空树会触发 `dispose`，从而取消这些定时器。
Future<void> unmountV2App(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// 点击某个文案的控件（文案取自 strings_zh_CN.json 的真实值）。
Future<void> tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) {
    return;
  }
  await tester.tap(finder.first);
  await pumpV2(tester, frames: 20);
}
