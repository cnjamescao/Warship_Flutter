// ================================================================
// test/golden/screens_golden_test.dart —— 界面像素基线
// ================================================================
// 依据：Spec/02_技术/v2.0/04_测试计划与验收用例.md 第 9 行
//   「Widget/Golden | Flutter golden | HUD、草案、风险门、结算、低动效 |
//     **必须（稳定平台）**」
//
// **平台约定**：「稳定平台」= macOS。基线在 macOS 本机生成，
// 由 CI 的 `build-macos` job（macos-latest）比对。
// `analyze-test` job 跑在 ubuntu，字体渲染不同，**不应**在那里比对 ——
// 因此 CI 里把 golden 放在 macOS job。
//
// 生成/更新基线：
//   flutter test test/golden --update-goldens
// ================================================================

@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;

  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('Golden：首页', (tester) async {
    await mountV2App(tester, catalog);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('baselines/home.png'),
    );
    await unmountV2App(tester);
  });

  testWidgets('Golden：作战简报', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    expect(find.text('作战简报'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('baselines/briefing.png'),
    );
    await unmountV2App(tester);
  });

  testWidgets('Golden：对局 HUD', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    expect(find.byType(V2RunScreen), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('baselines/playing_hud.png'),
    );
    await unmountV2App(tester);
  });

  testWidgets('Golden：升级草案', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    await advanceGameSeconds(tester, 17);
    expect(find.text('选择强化'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('baselines/draft.png'),
    );
    await unmountV2App(tester);
  });

  testWidgets('Golden：结算界面（含奖牌）', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    await advanceAutoPicking(tester, 60);
    expect(find.text('防线失守'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('baselines/result.png'),
    );
    await unmountV2App(tester);
  });
}
