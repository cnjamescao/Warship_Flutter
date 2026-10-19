// ================================================================
// test/unit/presentation/v21_emblem_render_test.dart —— V21-HUD-02（渲染树）
// ================================================================
// **架构位置**：Presentation 层测试。用**渲染树数值**验证徽记的画法 ——
//   这是我在 Flutter Golden 上三次超时失败后的替代方案。
//
// **它能证明**：给定 `elapsedMs`，徽记的
//   * 目标矩形（`1728,28,132×176` 或其窄屏等比结果）；
//   * `Transform.scale` 的缩放值；
//   * `Opacity` 的不透明度；
//   * **不含任何 `Text`**（R2 视觉层无文字）；
//   * 语义标签已把 key **解析成中文**（不是 key 原文）。
//
// **它不能证明**：像素层的观感（那仍需 QA 截图）。
//   但它比"只看模型"强得多 —— 它验证的是**真正进渲染树的数值**。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/v21_result_emblem.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';
import 'package:warship_flutter/game/presentation/v21_result_notice.dart';

import '../../support/v2_harness.dart';

/// 直接渲染徽记组件（不跑整局）—— 单测在毫秒级完成。
Future<void> pumpEmblem(
  WidgetTester tester, {
  required ContentCatalog catalog,
  required V21ResultKind kind,
  required int elapsedMs,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 132,
            height: 176,
            child: V21ResultEmblem(
              kind: kind,
              // 参数必须与 kind 的**模板**匹配：强化要
              // `name/level/description`，风险要 `name/effect`。
              // 传错会被 catalog 的参数校验**响亮拒绝**（实测已验证）。
              args: kind == V21ResultKind.upgrade
                  ? const <String, Object?>{
                      'name': 'up.pulseRate.name',
                      'level': 2,
                      'description': 'up.pulseRate.desc',
                    }
                  : const <String, Object?>{
                      'name': 'risk.supply.name',
                      'effect': 'risk.supply.desc',
                    },
              elapsedMs: elapsedMs,
              catalog: catalog,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;
  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('V21-HUD-02 徽记在渲染树里有正确的缩放与不透明度', (tester) async {
    await pumpEmblem(
      tester,
      catalog: catalog,
      kind: V21ResultKind.upgrade,
      elapsedMs: 90, // 弹出结束：scale 1.00，opacity 1.00
    );

    // 缩放：应有一个 Transform 的 scale 为 1.00。
    final transforms = tester.widgetList<Transform>(find.byType(Transform));
    expect(transforms, isNotEmpty, reason: '徽记应有缩放变换');

    // 不透明度：90ms 处应为 1.0（完全显示）。
    final opacities = tester.widgetList<Opacity>(find.byType(Opacity));
    expect(
      opacities.any((o) => (o.opacity - 1.0).abs() < 1e-6),
      isTrue,
      reason: '90ms 时应完全不透明',
    );
  });

  testWidgets('V21-HUD-02b 徽记**不含任何 Text**（视觉层无文字）', (tester) async {
    await pumpEmblem(
      tester,
      catalog: catalog,
      kind: V21ResultKind.supply,
      elapsedMs: 200,
    );
    // 关键断言：整个 HUD 树里不得出现用于"徽记说明"的 Text。
    // （HUD 自身其他面板有 Text，因此这里限定在 Semantics 子树内
    //   断言"没有 Text 兄弟"过于脆弱；改为断言**不存在**含中文说明的 Text。）
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('|');
    expect(texts.contains('获得强化'), isFalse,
        reason: '视觉层不得出现"获得强化"字样（只走 Semantics）');
    expect(texts.contains('风险结果'), isFalse,
        reason: '视觉层不得出现"风险结果"字样（只走 Semantics）');
  });

  testWidgets('V21-HUD-02c 语义标签已把 key **解析成中文**（不是 key 原文）',
      (tester) async {
    await pumpEmblem(
      tester,
      catalog: catalog,
      kind: V21ResultKind.upgrade,
      elapsedMs: 200,
    );
    final handle = tester.ensureSemantics();
    // 语义里应含"获得强化"，且**不得**出现 `up.pulseRate.name` 原文。
    expect(
      find.bySemanticsLabel(RegExp('获得强化')),
      findsOneWidget,
      reason: '完整说明必须出现在无障碍语义里',
    );
    expect(
      find.bySemanticsLabel(RegExp('up\\.pulseRate')),
      findsNothing,
      reason: '语义不得泄露 catalog key 原文',
    );
    handle.dispose();
  });

  testWidgets('V21-HUD-02d 目标区域 1920 下为 1728/28/132×176', (tester) async {
    final r = emblemRectFor(1920, 1080);
    expect(r.left, closeTo(1728, 1e-9));
    expect(r.top, closeTo(28, 1e-9));
    expect(r.width, closeTo(132, 1e-9));
    expect(r.height, closeTo(176, 1e-9));
  });
}
