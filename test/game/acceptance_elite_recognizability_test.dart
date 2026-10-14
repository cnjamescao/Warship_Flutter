// ================================================================
// test/game/acceptance_elite_recognizability_test.dart —— AC-05 结束条件
// ================================================================
// 产品设计 §7.5 精英出现：
//   视觉必须项：「**名称条、词缀图标、洋红外环**」
//   结束条件：「**词缀可在 0.5 秒内辨认**」
//
// 「0.5 秒内可辨认」本身是**感知指标**，无法自动判定。
// 但它有一条**可验证的支撑事实**：光环必须是**静态状态**（出生即可见），
// 而不是需要等某段动画播完才出现 —— 后者会让辨认被推迟。
// 本文件验证这条支撑事实，并把感知部分如实标注。
//
// ⚠️ 同时记录一处**素材缺口（F-21）**：§7.5 要求三样视觉要素，
// 素材包里只有"外环"。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

late AssetManifest manifest;
late Map<String, Object?> enemiesJson;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    manifest = AssetManifest.parse(
      jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
          as Map<String, Object?>,
    ).requireValue;
    enemiesJson =
        jsonDecode(File('assets/config/v2/enemies.json').readAsStringSync())
            as Map<String, Object?>;
  });

  test('§7.5「外环」：三个词缀的光环都存在，且是静态状态（出生即可见）', () {
    final affixes = (enemiesJson['affixes'] as List).cast<Map>();
    expect(affixes, hasLength(3), reason: '§6 规定三个固定词缀');

    for (final affix in affixes) {
      final id = affix['id'] as String;
      final auraId = affix['auraAssetId'] as String?;
      expect(auraId, isNotNull, reason: '$id 未声明 auraAssetId');

      final record = manifest.lookup(auraId!);
      expect(record, isNotNull, reason: '$id 的光环 $auraId 在 manifest 中不存在');

      // **关键**：必须是静态状态。若它只有一个需要触发的动画态，
      // 辨认就会被推迟，"0.5 秒内可辨认"就失去支撑。
      expect(
        record!.states,
        contains('default'),
        reason: '$auraId 应有 default 静态态，否则出生瞬间看不到光环',
      );
    }
  });

  test('§7.5「词缀可在 0.5 秒内辨认」：文本名在字符串表里齐备', () {
    // 素材包用**文本名**表达词缀（`nameKey`）而不是图标，
    // 因此"可辨认"的另一半支撑是：这三个名字都能解析出来。
    final strings =
        jsonDecode(File('assets/config/v2/strings_zh_CN.json').readAsStringSync())
            as Map<String, Object?>;
    final table = (strings['strings'] as Map).cast<String, Object?>();

    for (final affix in (enemiesJson['affixes'] as List).cast<Map>()) {
      final nameKey = affix['nameKey'] as String?;
      expect(nameKey, isNotNull, reason: '${affix['id']} 未声明 nameKey');
      expect(
        table.containsKey(nameKey!),
        isTrue,
        reason: '词缀名 $nameKey 在 strings_zh_CN.json 中缺失，玩家将看到原始 key',
      );
    }
  });

  test('⚠️ 素材缺口 F-21：§7.5 要求的"名称条 / 词缀图标"在素材包中不存在', () {
    // §7.5 精英出现的视觉必须项是**三样**：「名称条、词缀图标、洋红外环」。
    // 素材包里只有外环（GFX-ELITE-AURA-*）与文本名（affix.*）。
    //
    // 本用例**把这个缺口固定下来**：一旦素材侧补齐，
    // 下面的断言会失败并提示删除本用例。
    final eliteNameplates = manifest.records
        .where((r) => r.assetId.value.contains('ELITE') &&
            r.assetId.value.contains('NAMEPLATE'))
        .length;
    final affixIcons = manifest.records
        .where((r) => r.assetId.value.contains('AFFIX') &&
            r.category == AssetCategory.graphic)
        .length;

    expect(
      eliteNameplates,
      0,
      reason: '精英名称条素材已出现（当前为 0）—— 请更新本用例并关闭 F-21',
    );
    expect(
      affixIcons,
      0,
      reason: '词缀图标素材已出现（当前为 0）—— 请更新本用例并关闭 F-21',
    );
    // 对照：Boss 是有名称条的，说明这条不是"命名习惯不同"。
    expect(
      manifest.lookup('UI-BOSS-NAMEPLATE'),
      isNotNull,
      reason: 'Boss 有名称条 → 精英缺名称条不是命名约定问题',
    );
  });
}
