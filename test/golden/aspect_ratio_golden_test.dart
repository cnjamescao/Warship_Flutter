// ================================================================
// test/golden/aspect_ratio_golden_test.dart —— AC-02 像素级基线
// ================================================================
// 负责人批复（2026-10-16）：
// 「AC-02：补 **4:3 与 21:9 的像素级 Golden/人工基线流程**，继续保留
//   真实设备截图为发布证据，**不能把逻辑'不越界'断言说成视觉验收**。」
//
// 背景：既有 `screens_golden_test.dart` 只覆盖**默认测试面**
// （800×600，恰为 4:3），且 AC-02 此前只有"HUD 不越界"的**逻辑**断言。
// 本文件补**像素级**基线，在两种极端宽高比下渲染**对局 HUD**。
//
// ⚠️ 与既有 golden 同样遵循 F-06/F-16：
//   * CI 排除 `golden` tag，**不作为阻断项**；
//   * 基线在 macOS 本机生成，发布前由 QA 对照基线**人工复核**；
//   * 生成/更新：`flutter test test/golden --update-goldens`
//   * **真实设备截图仍是发布证据**，本文件不能替代。
// ================================================================

@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

/// 与 `ViewportMath` 一致的逻辑世界尺寸（用于注释中的比例核算）。
const double _logicalW = 1920;
const double _logicalH = 1080;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;

  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  /// 在指定物理分辨率下渲染对局 HUD 并比对基线。
  ///
  /// `devicePixelRatio` 固定为 1.0，使"物理像素"即"逻辑像素"，
  /// 便于人工对照基线核对 HUD 与世界的相对位置。
  Future<void> captureAt(
    WidgetTester tester, {
    required Size size,
    required String baseline,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    expect(
      find.byType(V2RunScreen),
      findsOneWidget,
      reason: '应已进入对局（${size.width.toInt()}×${size.height.toInt()}）',
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('baselines/$baseline'),
    );
    await unmountV2App(tester);
  }

  testWidgets('Golden：对局 HUD @ 4:3（1024×768）', (tester) async {
    // 4:3 比 16:9 **更高更窄** ⇒ 世界按宽度贴合、上下留黑边。
    // 这正是 HUD 反向锚定曾出错（Lv/命数栏浮到窗口 1/3 处）的比例。
    await captureAt(
      tester,
      size: const Size(1024, 768),
      baseline: 'playing_hud_4x3.png',
    );
  });

  testWidgets('Golden：对局 HUD @ 21:9（2100×900）', (tester) async {
    // 21:9 比 16:9 **更宽更扁** ⇒ 世界按高度贴合、左右留黑边。
    await captureAt(
      tester,
      size: const Size(2100, 900),
      baseline: 'playing_hud_21x9.png',
    );
  });

  test('比例核算：两种基线确实落在 4:3 与 21:9', () {
    // 守住"这两个基线覆盖的是预期比例"，避免以后被误改。
    final fourThree = 1024 / 768;
    final twentyOneNine = 2100 / 900;
    expect(fourThree, closeTo(4 / 3, 1e-6));
    expect(twentyOneNine, closeTo(21 / 9, 1e-6));
    // 且都是相对 16:9 世界的"极端"方向：
    expect(fourThree, lessThan(_logicalW / _logicalH), reason: '4:3 应比 16:9 窄高');
    expect(
      twentyOneNine,
      greaterThan(_logicalW / _logicalH),
      reason: '21:9 应比 16:9 宽扁',
    );
  });
}
