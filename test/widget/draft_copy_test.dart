// ================================================================
// test/widget/draft_copy_test.dart —— F-25-01 关闭准则第 3 条
// ================================================================
// 负责人批复原文：
// 「F-25-01 第 3 条：构造至少一张**真实草案卡**，断言**可见中文标题和
//   描述**，且**玩家页面文本中没有 `UP-` 或 `up.`**；若现有测试已有等价
//   断言，提交准确的文件、用例和运行结果即可，不重复造轮子。」
//
// **研发先做了实证核对**：现有测试里
//   * `test/widget/draft_icon_test.dart` 只断言**图标**渲染；
//   * `test/unit/content/content_catalog_test.dart` 只在 **catalog 层**
//     断言 key **存在**（`hasText`），不涉及渲染出的界面；
//   * `test/widget/v2_app_flow_test.dart` 断言了首页/简报文案，**未覆盖草案卡**。
// 即：**没有任何运行时 Widget 断言**覆盖本条 → 确认缺失，据此新增。
//
// 本文件的断言对应 F-25-01 的实测现象：
//   卡片标题曾显示 `UP-PULSE-RATE` 等内部 ID，
//   描述曾显示 `up.pulseRate.desc` 等未解析 Key。
// ================================================================

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

  testWidgets('F-25-01(3) 草案卡显示中文标题与描述，页面不含 UP- / up.', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

    // 推进到第 1 次草案**打开状态**（不自动选卡）。
    var opened = false;
    for (var i = 0; i < 25 * 60; i++) {
      await pumpV2(tester, frames: 1);
      if (find.text(catalog.text('draft.title')).evaluate().isNotEmpty) {
        opened = true;
        break;
      }
    }
    expect(opened, isTrue, reason: '应在 25 秒内打开第 1 次草案');

    final screen = tester.widget<V2RunScreen>(find.byType(V2RunScreen));
    final offer = screen.runtime.currentOffer;
    expect(offer, isNotNull, reason: '草案应有候选卡');
    expect(offer!.candidates, isNotEmpty, reason: '候选卡不应为空');

    // ① 每张候选卡都必须渲染**解析后的中文标题与描述**。
    for (final cardId in offer.candidates) {
      final card = catalog.upgradeById(cardId);
      expect(card, isNotNull, reason: '配置里应有 $cardId');

      final title = catalog.text(card!['nameKey'] as String);
      final desc = catalog.text(card['descKey'] as String);
      expect(
        find.text(title),
        findsWidgets,
        reason: '$cardId 的中文标题「$title」应在草案卡上可见',
      );
      expect(
        find.text(desc),
        findsWidgets,
        reason: '$cardId 的中文描述「$desc」应在草案卡上可见',
      );
    }

    // ② 玩家页面文本中**不得**出现内部 ID / 未解析 Key。
    //
    // 用真实 Widget 树取「页面上所有文字」，而不是静态扫描 —— 这正是
    // F-25-01 关闭准则第 3 条要求的运行时断言。
    final renderedTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .toList();
    expect(renderedTexts, isNotEmpty, reason: '页面上应有文字');

    final leaked = renderedTexts
        .where((t) => t.contains('UP-') || t.contains('up.'))
        .toList();
    expect(
      leaked,
      isEmpty,
      reason: '草案界面把内部 ID / 未解析 Key 展示给了玩家：\n'
          '${leaked.join('\n')}',
    );
  });
}
