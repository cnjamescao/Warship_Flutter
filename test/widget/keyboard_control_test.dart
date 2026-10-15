// ================================================================
// test/widget/keyboard_control_test.dart —— F-26-01（P0）
// ================================================================
// 玩家实测：从首页点「开始战斗」、跳过简报后，持续按 A / ← 战舰不动。
//
// 根因：对局页只依赖 `Focus(autofocus: true)`，但在
// Home → Loading → Briefing → Playing 的**正常重建链路**后该节点拿不到
// 焦点。而测试辅助 `focusGameField` 会手动 `requestFocus()`，
// **把这个问题掩盖了** —— 测试全绿，玩家却控制不了。
//
// 因此本文件的**存在意义**就是：**不调用任何测试专用聚焦函数**，
// 完全走生产路径。它红了就说明玩家会控制不了。
//
// 裁决要求：「增加从首页点击开始、经历完整简报、**不额外注入焦点**的
// widget/integration 测试：发送按下并保持 A、D、左/右方向键后，
// 读取运行时玩家 X 坐标，必须按相应方向变化；松键后必须停止。」
// ================================================================

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

/// 走**生产路径**进入对局：首页 → 开始战斗 → 完整简报 → Playing。
///
/// **刻意不调用 `focusGameField`** —— 这正是本用例要守住的东西。
Future<void> enterPlayingViaProductionPath(WidgetTester tester) async {
  await mountV2App(tester, catalog);
  await tapText(tester, '开始战斗');
  // 简报倒计时走完。
  await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
  expect(find.byType(V2RunScreen), findsOneWidget, reason: '应已进入对局');
}

late ContentCatalog catalog;

/// 读取运行时的玩家 X 坐标。
double playerX(WidgetTester tester) =>
    tester.widget<V2RunScreen>(find.byType(V2RunScreen)).runtime.player.position.x;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('F-26-01 开局即可控制：按住 A 左移、松开停止（不注入焦点）', (tester) async {
    await enterPlayingViaProductionPath(tester);

    final startX = playerX(tester);

    // 按住 A（**不做任何聚焦操作**）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await pumpV2(tester, frames: 30);

    final afterA = playerX(tester);
    expect(
      afterA,
      lessThan(startX),
      reason: '按住 A 必须左移 —— 玩家不该先点画布才能控制。'
          '起点 x=$startX，按 A 后 x=$afterA',
    );

    // 松开后必须停止（无惯性）。
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await pumpV2(tester, frames: 10);
    final afterRelease = playerX(tester);
    await pumpV2(tester, frames: 30);
    expect(
      playerX(tester),
      closeTo(afterRelease, 0.001),
      reason: '松开 A 后必须停止移动',
    );

    await unmountV2App(tester);
  });

  testWidgets('F-26-01 方向键与 A/D 等价：按 D 与 → 都右移（不注入焦点）', (tester) async {
    await enterPlayingViaProductionPath(tester);

    final startX = playerX(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
    await pumpV2(tester, frames: 20);
    final afterD = playerX(tester);
    expect(afterD, greaterThan(startX), reason: '按住 D 必须右移');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
    await pumpV2(tester, frames: 5);

    final beforeArrow = playerX(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await pumpV2(tester, frames: 20);
    expect(
      playerX(tester),
      greaterThan(beforeArrow),
      reason: '按住 → 必须右移（与 D 等价）',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);

    await unmountV2App(tester);
  });

  testWidgets('F-26-01 从暂停返回后仍可控制（覆盖层关闭要交还焦点）', (tester) async {
    await enterPlayingViaProductionPath(tester);

    // Esc 打开暂停（这一条同样依赖生产路径的焦点交接）。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpV2(tester, frames: 30);
    expect(find.text('已暂停'), findsOneWidget, reason: 'Esc 应能打开暂停遮罩');

    // 点「继续」回到对局。
    await tapText(tester, '继续');
    await pumpV2(tester, frames: 30);
    expect(find.text('已暂停'), findsNothing);

    final beforeMove = playerX(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await pumpV2(tester, frames: 25);
    expect(
      playerX(tester),
      lessThan(beforeMove),
      reason: '从暂停返回后，键盘必须立即可用（不得丢失可恢复的控制）',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);

    await unmountV2App(tester);
  });
}
