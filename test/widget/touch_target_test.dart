// ================================================================
// test/widget/touch_target_test.dart —— §8「触摸目标最小 44×44 dp」
// ================================================================
// 产品设计 §8 第 281 行：「触摸目标最小 44×44 dp」。
//
// **做法：实测而不是目测。** 不假设"按钮看起来够大"，
// 而是把交互控件渲染出来量它的实际尺寸。
//
// 测试画布固定为 1920×1080 逻辑像素（与游戏逻辑世界一致），
// 这样量出来的就是设计意图下的尺寸。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

/// 最小触摸目标（dp）。
const double kMinTouchTarget = 44.0;

/// 把测试画布设为 1920×1080 逻辑像素。
void useFullHdSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 断言某个控件的渲染尺寸不小于 44×44。
void expectBigEnough(WidgetTester tester, Finder finder, String label) {
  expect(finder, findsWidgets, reason: '$label 未找到');
  for (final element in finder.evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) {
      continue;
    }
    final size = box.size;
    expect(
      size.width,
      greaterThanOrEqualTo(kMinTouchTarget),
      reason: '$label 宽度 ${size.width.toStringAsFixed(1)} < $kMinTouchTarget dp',
    );
    expect(
      size.height,
      greaterThanOrEqualTo(kMinTouchTarget),
      reason: '$label 高度 ${size.height.toStringAsFixed(1)} < $kMinTouchTarget dp',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;

  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('首页按钮满足 44×44 dp', (tester) async {
    useFullHdSurface(tester);
    await mountV2App(tester, catalog);

    expectBigEnough(tester, find.widgetWithText(FilledButton, '开始战斗'), '开始战斗');
    expectBigEnough(tester, find.widgetWithText(TextButton, '设置'), '设置');
    await unmountV2App(tester);
  });

  testWidgets('设置页的返回按钮与开关满足 44×44 dp', (tester) async {
    useFullHdSurface(tester);
    await mountV2App(tester, catalog);
    await tapText(tester, '设置');

    expectBigEnough(tester, find.widgetWithText(FilledButton, '返回'), '返回');
    // SwitchListTile 整体作为触摸目标。
    expectBigEnough(tester, find.byType(SwitchListTile).first, '开关行');
    await unmountV2App(tester);
  });

  testWidgets('结算页的两个按钮满足 44×44 dp', (tester) async {
    useFullHdSurface(tester);
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    await advanceAutoPicking(tester, 60);
    expect(find.text('防线失守'), findsOneWidget);

    expectBigEnough(tester, find.widgetWithText(FilledButton, '再来一局'), '再来一局');
    expectBigEnough(tester, find.widgetWithText(OutlinedButton, '返回首页'), '返回首页');
    await unmountV2App(tester);
  });

}
