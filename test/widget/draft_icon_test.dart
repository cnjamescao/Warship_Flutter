// ================================================================
// test/widget/draft_icon_test.dart —— F-26-03（P1）
// ================================================================
// 玩家实测：升级卡除稀有度边框/叠层外没有能力图标。
//
// 事实：16 张逐卡图标已以 `UI-UP-*` 交付，配置也已逐个绑定到
// `iconAssetId`（例如 `UP-PULSE-RATE` → `UI-UP-PULSE-RATE`）。
// 但 `_DraftCard` **完全没有渲染它** —— 属于研发未接入既有素材。
//
// 裁决要求：断言 UI 请求的运行时文件与三张卡的 `iconAssetId` **一一对应**；
// 禁止写死路径、禁止用系列通用图标替代。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

late ContentCatalog catalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('F-26-03 每张草案卡都渲染它自己的 iconAssetId 对应文件', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

    // 推进到第 1 次草案打开 —— **但不自动选卡**，
    // 因为要在草案**打开状态**下检查图标。
    // （`advanceAutoPicking` 会自动把卡选掉，草案随即关闭，看不到图标。）
    var opened = false;
    for (var i = 0; i < 25 * 60; i++) {
      await pumpV2(tester, frames: 1);
      if (find.text(catalog.text('draft.title')).evaluate().isNotEmpty) {
        opened = true;
        break;
      }
    }
    expect(opened, isTrue, reason: '应在 25 秒内打开第 1 次草案');
    expect(
      find.text(catalog.text('draft.title')),
      findsOneWidget,
      reason: '应已打开升级草案',
    );

    final screen = tester.widget<V2RunScreen>(find.byType(V2RunScreen));
    final offer = screen.runtime.currentOffer;
    expect(offer, isNotNull, reason: '草案应有候选卡');

    // 期望：每张卡的 iconAssetId 解析出的**第一个**运行时文件。
    final expected = <String>[];
    for (final cardId in offer!.candidates) {
      final card = catalog.upgradeById(cardId);
      expect(card, isNotNull, reason: '$cardId 应在配置中');
      final iconId = card!['iconAssetId'] as String?;
      expect(iconId, isNotNull, reason: '$cardId 未绑定 iconAssetId');
      final record = catalog.manifest.lookup(iconId!);
      expect(record, isNotNull, reason: '$iconId 未登记');
      expect(record!.runtimeFiles, isNotEmpty);
      expected.add(record.runtimeFiles.first);
    }

    // 收集卡片里实际请求的图片资源。
    final requested = <String>{};
    for (final image in tester.widgetList<Image>(find.byType(Image))) {
      final provider = image.image;
      if (provider is AssetImage) {
        requested.add(provider.assetName);
      }
    }

    for (final path in expected) {
      expect(
        requested,
        contains(path),
        reason: '草案卡必须渲染它的能力图标：$path\n'
            '实际请求的图片：$requested',
      );
    }

    // 三张卡的能力图标必须**互不相同**（不是用同一张通用图糊弄）。
    expect(
      expected.toSet().length,
      expected.length,
      reason: '三张卡的能力图标应各不相同：$expected',
    );

    await unmountV2App(tester);
  });
}
