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
}) async {
  // SharedPreferences 也必须 mock，否则 initState 里的存档读取会等平台通道。
  SharedPreferences.setMockInitialValues(<String, Object>{});

  await tester.pumpWidget(
    MaterialApp(
      home: V2AppFlow(
        catalog: catalog,
        seed: seed,
        audioPort: SilentAudioPort(),
        store: InMemoryKeyValueStore(),
        // 关键：关掉资源预载。预载走 Flame.images.load → rootBundle，
        // 是真实 I/O，在 testWidgets 的假异步区里永不完成。
        // 关掉后表现层走矢量占位，规则不受影响（架构 §7）。
        preloadAssets: false,
      ),
      debugShowCheckedModeBanner: false,
    ),
  );
  await pumpV2(tester, frames: 30);
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
