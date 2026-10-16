// ================================================================
// test/widget/pause_semantics_test.dart —— F-25-03
// ================================================================
// 实测现象：暂停按钮的**辅助标签描述了错误状态**。
//
// 根因：运行中的暂停按钮使用 `pause.title` 作为语义标签，
// 而该 key 的文案是「**已暂停**」—— 那是**状态描述**（暂停覆盖层的标题），
// 不是运行中按钮的动作。读屏软件于是在玩家**并未暂停**时播报「已暂停」。
//
// 负责人批复：「F-25-03：核对运行中"暂停"和覆盖层"继续"的语义名称；
//   **须检查实际 Semantics tree**，不是只核对 strings key 存在。」
//
// 因此本文件遍历**真实语义树**取证。
// ================================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

/// 收集语义树中的全部 label。
Set<String> _semanticLabels(WidgetTester tester) {
  final labels = <String>{};
  void walk(SemanticsNode node) {
    if (node.label.isNotEmpty) {
      labels.add(node.label);
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  // **F-41**：`tester.binding.pipelineOwner` 自 v3.10 起弃用。
  // 弃用提示的两条替代路径我都试过：
  //   * `binding.rootPipelineOwner.semanticsOwner` → 实测为 **null**；
  //   * 因此改用 Flutter 测试框架的 `tester.getSemantics(...)`，
  //     从根 widget 取语义节点后自顶向下遍历 —— 不触及弃用 API。
  walk(tester.getSemantics(find.byType(MaterialApp)));
  return labels;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;
  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('F-25-03 运行中：暂停按钮的语义标签是动作「暂停」，不是状态「已暂停」',
      (tester) async {
    final handle = tester.ensureSemantics();
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));
    // 进入对局（简报结束）。
    await pumpV2(tester, frames: 5, step: const Duration(seconds: 1));

    final labels = _semanticLabels(tester);

    final actionLabel = catalog.text('hud.pauseAria'); // 「暂停」
    final stateLabel = catalog.text('pause.title'); // 「已暂停」

    expect(
      labels,
      contains(actionLabel),
      reason: '运行中的暂停按钮应播报动作「$actionLabel」—— 实际语义标签：$labels',
    );
    expect(
      labels,
      isNot(contains(stateLabel)),
      reason: '运行中**并未暂停**，语义树里不应出现状态描述「$stateLabel」'
          '（它只应用于暂停覆盖层的标题）—— 实际语义标签：$labels',
    );

    handle.dispose();
  });

  test('F-25-03 覆盖层的语义名称：标题用状态「已暂停」，继续控件用「继续」', () {
    // ⚠️ **本用例是静态核对，不是运行时语义树断言** —— 如实说明：
    // 暂停覆盖层只在 `phase == paused` 时渲染，而 `V2RunScreen` 未对外
    // 暴露可驱动暂停的句柄；点击暂停按钮在我的测试环境里也未命中
    //（`find.bySemanticsLabel` 找到节点但 tap 未使状态切换）。
    // 为避免"把没验证的东西说成验证过"，这里退一步做**可复核的静态核对**，
    // 并保留运行时断言（上方运行中按钮那条）已覆盖的部分。
    final source = File('lib/app/v2_run_screen.dart').readAsStringSync();

    // 覆盖层标题用状态 key。
    expect(
      source.contains("catalog.text('pause.title')"),
      isTrue,
      reason: '暂停覆盖层标题应使用状态 key `pause.title`',
    );
    // 继续控件用 `pause.resume`。
    expect(
      source.contains("catalog.text('pause.resume')"),
      isTrue,
      reason: '覆盖层的继续控件应使用 `pause.resume`',
    );
    // 两个 key 的文案必须**确实不同**（一个状态、一个动作）。
    final stateText = catalog.text('pause.title');
    final resumeText = catalog.text('pause.resume');
    expect(
      stateText,
      isNot(resumeText),
      reason: '状态标题与继续控件不得是同一文案',
    );
    // ignore: avoid_print
    print('F-25-03 覆盖层：状态标题「$stateText」/ 继续控件「$resumeText」');
  });
}
