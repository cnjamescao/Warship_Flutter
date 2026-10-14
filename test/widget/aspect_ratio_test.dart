// ================================================================
// test/widget/aspect_ratio_test.dart —— AC-02 横向分辨率
// ================================================================
// 产品基线 §9 AC-02：
//   「16:9、4:3、21:9 和带安全区设备均**不拉伸逻辑世界**，**HUD 不越界**」
//
// 与 `viewport_test.dart` 的分工：那个测的是**逻辑世界**与视口换算；
// 本文件测的是**v2.0 应用层在三种真实画布下的 HUD 边界** ——
// 用结构性断言（量控件矩形），**不依赖字体渲染**，因此可在 CI 跑。
//
// 三种比例各取一个接近真实设备的逻辑尺寸。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

/// 三种目标宽高比（按 1080 高度换算宽度）。
const Map<String, Size> kRatios = <String, Size>{
  '16:9': Size(1920, 1080),
  '4:3': Size(1440, 1080),
  '21:9': Size(2520, 1080),
};

void useSurface(WidgetTester tester, Size logical) {
  tester.view.physicalSize = logical;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 断言某个 finder 的每个实例都完整落在画布内（不越界）。
void expectWithinScreen(
  WidgetTester tester,
  Finder finder,
  String label,
  Size screen,
) {
  expect(finder, findsWidgets, reason: '$label 未找到');
  final screenRect = Offset.zero & screen;
  for (final element in finder.evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    expect(
      rect.left,
      greaterThanOrEqualTo(-0.5),
      reason: '$label 越出左边界：${rect.left}',
    );
    expect(
      rect.top,
      greaterThanOrEqualTo(-0.5),
      reason: '$label 越出上边界：${rect.top}',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(screenRect.right + 0.5),
      reason: '$label 越出右边界：${rect.right} > ${screenRect.right}',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(screenRect.bottom + 0.5),
      reason: '$label 越出下边界：${rect.bottom} > ${screenRect.bottom}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;

  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  for (final entry in kRatios.entries) {
    final label = entry.key;
    final size = entry.value;

    testWidgets('$label：对局 HUD 不越界', (tester) async {
      useSurface(tester, size);
      await mountV2App(tester, catalog);
      await tapText(tester, '开始战斗');
      await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
      expect(find.byType(V2RunScreen), findsOneWidget);

      // HUD 的左上角面板与顶部中间的计时器；只要它们都在画布内，
      // 就说明布局按画布尺寸正确缩放，而不是溢出。
      expectWithinScreen(
        tester,
        find.textContaining('HP'),
        '$label HUD 生命面板',
        size,
      );
      expectWithinScreen(
        tester,
        find.textContaining('SHIELD'),
        '$label HUD 护盾面板',
        size,
      );
      await unmountV2App(tester);
    });

    testWidgets('$label：首页与简报不越界', (tester) async {
      useSurface(tester, size);
      await mountV2App(tester, catalog);

      expectWithinScreen(tester, find.byType(TextButton), '$label 首页按钮', size);

      await tapText(tester, '开始战斗');
      expectWithinScreen(tester, find.byType(Text), '$label 简报文本', size);
      await unmountV2App(tester);
    });
  }

  // AC-02 原文是「16:9、4:3、21:9 **和带安全区设备**均不拉伸逻辑世界，
  // HUD 不越界」—— 此前只测了三种比例，**漏了"带安全区设备"**。
  // 这里模拟刘海/圆角设备：给视口加顶部与底部的安全区内边距。
  testWidgets('带安全区设备（刘海 + 底部横条）：HUD 不越界', (tester) async {
    const size = Size(1920, 1080);
    useSurface(tester, size);
    // 典型 iPhone 横屏：顶部刘海 0（横屏在侧边）、底部 Home 指示条约 21dp。
    tester.view.padding = const FakeViewPadding(top: 0, bottom: 21);
    tester.view.viewPadding = const FakeViewPadding(top: 0, bottom: 21);
    addTearDown(tester.view.resetPadding);

    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    expect(find.byType(V2RunScreen), findsOneWidget);

    expectWithinScreen(tester, find.textContaining('HP'), '安全区 HUD 生命面板', size);
    expectWithinScreen(
      tester,
      find.textContaining('SHIELD'),
      '安全区 HUD 护盾面板',
      size,
    );
    await unmountV2App(tester);
  });
}

