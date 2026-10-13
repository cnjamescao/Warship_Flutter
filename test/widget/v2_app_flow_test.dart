// ================================================================
// test/widget/v2_app_flow_test.dart —— v2.0 应用层结构性 UI 证据
// ================================================================
// 补上第 35 轮发现的空白：v2.0 应用层此前零测试覆盖。
// 文案取自 assets/config/v2/strings_zh_CN.json 的真实值。
// 只做**结构性**断言（文本、可见性），不依赖字体渲染 —— 与 Golden 互补。
//
// 关键：内容目录在 `setUpAll`（真异步区）预载，
// 不在 `testWidgets` 体内 await 真实 I/O（那会永久挂起）。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;

  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('首页显示标题、开始战斗、设置', (tester) async {
    await mountV2App(tester, catalog);

    // 注意：标题是**硬编码**的两个 Text，而不是读
    // strings_zh_CN.json 的 `strings/home.app.title`。
    // 产品设计 §8 要求「所有展示文本使用本地化 key，
    // 不在玩法逻辑中硬编码」—— 这是一处真实的不一致，
    // 已记入 docs/验收证据对照表.md。本用例断言**现状**，
    // 待本地化修复后应改为断言 `Warship：霓虹最后防线`。
    expect(find.text('WARSHIP'), findsOneWidget);
    expect(find.text('霓虹最后防线'), findsOneWidget);
    expect(find.text('开始战斗'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('内容目录经生产路径加载成功（193 条 / 2.0.4-release）', (tester) async {
    await mountV2App(tester, catalog);

    expect(catalog.manifest.length, 193);
    expect(catalog.manifest.contentVersion, '2.0.4-release');
  });

  // 未覆盖：首页的"最高分/最快通关"显示逻辑 —— 我对它的文案假设
  // 两次都不对（空存档时它可能用别的措辞或布局），本轮已无余量核实，
  // 因此**移除**该用例而不是放宽到能过。

  testWidgets('点设置进入设置页，可返回首页', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '设置');

    // 设置页的四个开关来自产品基线 §8 的固定键。
    expect(find.textContaining('背景音乐'), findsWidgets);
    expect(find.textContaining('音效'), findsWidgets);
  });

  // 未覆盖（如实登记，不是遗漏）：
  // * 「点开始战斗 → 作战简报」进不去：Home → Loading 会做**真实资源预载
  //   I/O**，在 `testWidgets` 的假异步区里无法驱动（与 loadCatalog
  //   同类问题）。要覆盖它需要把预载也做成可注入，或改在
  //   `tester.runAsync` 里驱动 —— 那是下一步的工作。
  // * 对局中 HUD / 升级草案 / 风险门 / 暂停 / 结算：同上，
  //   都需要先解决 Loading 这一关。
}
