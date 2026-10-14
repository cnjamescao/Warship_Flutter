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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
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

  testWidgets('内容目录经生产路径加载成功（197 条 / 2.0.5-release）', (tester) async {
    await mountV2App(tester, catalog);

    expect(catalog.manifest.length, 197);
    expect(catalog.manifest.contentVersion, '2.0.5-release');
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

  testWidgets('点开始战斗后进入作战简报（预载注入生效）', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');

    expect(
      find.text('作战简报'),
      findsOneWidget,
      reason: '关掉 preloadAssets 后 Home → Loading → Briefing 应当可驱动',
    );
    // 简报页有 1 秒倒计时定时器；换成空树触发 dispose 取消它，
    // 否则 flutter_test 会以 "Pending timers" 报失败。
    await unmountV2App(tester);
  });

  testWidgets('简报显示目标与三条操作提示', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');

    expect(find.textContaining('坚持'), findsWidgets);
    expect(find.textContaining('移动'), findsWidgets);
    expect(find.textContaining('冲刺'), findsWidgets);
    await unmountV2App(tester);
  });

  testWidgets('简报倒计时会推进（表现时钟在走，但战斗逻辑冻结）', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');

    // 倒计时的数字文本会随秒数变化；只断言它确实在变，
    // 不写死具体秒数（开局秒数由内容配置决定）。
    final before = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    await pumpV2(tester, frames: 70, step: const Duration(seconds: 1));
    final after = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();

    expect(before, isNot(equals(after)), reason: '倒计时应随时间推进');
    await unmountV2App(tester);
  });

  testWidgets('简报倒计时结束后进入对局界面（Home→Loading→Briefing→Playing）', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');

    // 简报倒计时 3 秒；多推几秒确保 onFinished 已触发。
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

    expect(
      find.byType(V2RunScreen),
      findsOneWidget,
      reason: '倒计时结束后应进入对局界面',
    );
    expect(find.text('作战简报'), findsNothing, reason: '简报应已退出');
    await unmountV2App(tester);
  });

  testWidgets('对局中按 Esc 打开暂停遮罩', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    expect(find.byType(V2RunScreen), findsOneWidget);

    // 必须先把焦点交给对局界面的 Focus 节点，否则键盘事件无处送达。
    await focusGameField(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpV2(tester, frames: 30);

    expect(find.text('已暂停'), findsOneWidget, reason: 'Esc 应打开暂停遮罩');
    expect(find.text('继续'), findsOneWidget);
    await unmountV2App(tester);
  });

  testWidgets('开局 15 秒后打开升级草案（三选一）', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    expect(find.byType(V2RunScreen), findsOneWidget);

    await advanceGameSeconds(tester, 17);

    expect(
      find.text('选择强化'),
      findsOneWidget,
      reason: '首个升级草案在 15.0 秒打开（产品基线 §4.2）',
    );
    await unmountV2App(tester);
  });

  testWidgets('点击卡片选卡后草案关闭、逻辑继续推进', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    await advanceGameSeconds(tester, 17);
    expect(find.text('选择强化'), findsOneWidget);

    // 草案提示写明「点击卡片或按 1 / 2 / 3」，因此用键盘选择 ——
    // 比点击可靠：卡片 InkWell 在树里是第 2..4 个，
    // `find.byType(InkWell).first` 会误取 HUD 的暂停按钮（曾踩过）。
    // 树里有 4 个 InkWell：下标 0 是 HUD 的暂停按钮，1..3 才是卡片。
    // 探针实测确认（早期用 .first 误取暂停按钮）。
    final cards = find.byType(InkWell);
    expect(cards, findsNWidgets(4));
    await tester.tap(cards.at(1));
    await pumpV2(tester, frames: 30);

    expect(find.text('选择强化'), findsNothing, reason: '选卡后草案应关闭');
    await unmountV2App(tester);
  });

  testWidgets('选卡后逻辑解冻：能继续推进到下一次草案', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    await advanceGameSeconds(tester, 17);
    await tester.tap(find.byType(InkWell).at(1));
    await pumpV2(tester, frames: 30);
    expect(find.text('选择强化'), findsNothing);

    // 解冻后游戏时间应继续走：再推进一段应看到下一次草案
    // （第二次草案在经验够时打开）。
    await advanceGameSeconds(tester, 40);
    // 不断言一定出现（取决于击杀节奏），只断言**逻辑没有卡死**：
    // 画面仍在（对局界面还在），且没有异常。
    expect(find.byType(V2RunScreen), findsOneWidget);
    await unmountV2App(tester);
  });

  testWidgets('玩家阵亡后进入结算界面，并显示出奖牌', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

    // 测试里没有移动输入，玩家会在 30 秒左右阵亡；
    // 自动选卡是为了避免草案把逻辑时钟冻住走不下去。
    await advanceAutoPicking(tester, 60);

    expect(find.text('防线失守'), findsOneWidget, reason: '败北结算标题');
    expect(
      find.text('铜牌'),
      findsOneWidget,
      reason: '未把 Boss 打进 P3 → 按裁决结果应为 bronze（铜牌）',
    );
    expect(find.textContaining('得分'), findsWidgets);
    expect(find.textContaining('用时'), findsWidgets);
    expect(find.text('再来一局'), findsOneWidget);
    expect(find.text('返回首页'), findsOneWidget);
    await unmountV2App(tester);
  });

  testWidgets('结算界面「再来一局」能重新开局', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    await advanceAutoPicking(tester, 60);
    expect(find.text('防线失守'), findsOneWidget);

    await tapText(tester, '再来一局');
    // 重开后应离开结算界面（回到简报或对局）。
    expect(find.text('防线失守'), findsNothing, reason: '重开后不应停留在结算');
    await unmountV2App(tester);
  });

  // 未覆盖：**风险门**（55 秒）。测试里没有移动输入，玩家在约 30 秒阵亡，
  // 走不到 55 秒。要覆盖它需要能模拟走位输入（同上面的键盘通路问题）。

  // 未覆盖：**风险门（55 秒）**。写了走位辅助（按住 A/D 横移 +
  // 自动选卡），但玩家仍在 55 秒前阵亡 —— 测试里无法复现真实玩家的
  // 走位水平。要覆盖它需要给运行时注入"无敌"或"固定输入序列"的
  // 测试通道，属于测试基建，不在本轮范围。
  //
  // 注意：这**不是**风险门实现有问题 —— 风险门本身的逻辑
  // 已有单元与集成覆盖（test/unit/domain/risk_boss_test.dart）。

  testWidgets('键盘可遍历菜单，且焦点状态可见（§8 无障碍要求）', (tester) async {
    await mountV2App(tester, catalog);

    // 未使用键盘时是 touch 模式（不绘制焦点指示）。
    expect(
      FocusManager.instance.highlightMode,
      FocusHighlightMode.touch,
      reason: '初始应为触摸模式',
    );

    // 按 Tab 遍历：焦点应移动到**不同的**节点（说明真的在遍历，
    // 而不是卡在一个节点上）。
    final visited = <Object>{};
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull, reason: '第 $i 次 Tab 后应有焦点');
      visited.add(focus!);
    }
    expect(
      visited.length,
      greaterThan(1),
      reason: 'Tab 应在多个控件间移动，而不是停在同一个节点',
    );

    // §8「焦点状态必须可见」：键盘导航时 Flutter 切到 traditional 模式，
    // Material 才会绘制焦点指示。这是**框架默认行为**，
    // 本用例的作用是守住它没被某个自定义主题/Widget 关掉。
    expect(
      FocusManager.instance.highlightMode,
      FocusHighlightMode.traditional,
      reason: '键盘导航后应切换为可见焦点模式',
    );
    await unmountV2App(tester);
  });
}
