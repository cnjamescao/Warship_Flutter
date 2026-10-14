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

  test('§7.5「名称条」：UI-ELITE-NAMEPLATE 已入正式 manifest 并按 isElite 路由', () {
    // 2.0.5-release 已补齐。原先这里是「缺口冻结」断言（断言不存在）；
    // 素材交付后按约定改为**正向接入断言**。
    final r = manifest.lookup('UI-ELITE-NAMEPLATE');
    expect(r, isNotNull, reason: '精英名称条应存在');

    final binding = r!.eventBindings.firstWhere(
      (b) => b.event == 'EnemySpawned',
      orElse: () => throw StateError('名称条未绑定在 EnemySpawned 上'),
    );
    expect(
      binding.when['isElite'],
      isTrue,
      reason: '名称条只应出现在精英上（绑定条件 isElite=true）',
    );
  });

  test('§7.5「词缀图标」：三个词缀各有独立图标，且按 isElite + affixId 精确路由', () {
    const expected = <String, String>{
      'AFFIX-ACCEL': 'UI-ELITE-AFFIX-ACCEL',
      'AFFIX-SHIELD': 'UI-ELITE-AFFIX-SHIELD',
      'AFFIX-BARRAGE': 'UI-ELITE-AFFIX-BARRAGE',
    };

    for (final entry in expected.entries) {
      final r = manifest.lookup(entry.value);
      expect(r, isNotNull, reason: '${entry.key} 的图标 ${entry.value} 应存在');

      final binding = r!.eventBindings.firstWhere(
        (b) => b.event == 'EnemySpawned',
        orElse: () => throw StateError('${entry.value} 未绑定在 EnemySpawned 上'),
      );
      expect(binding.when['isElite'], isTrue, reason: '词缀图标只应出现在精英上');
      expect(
        binding.when['affixId'],
        entry.key,
        reason: '${entry.value} 必须按 affixId 精确路由，'
            '否则三个词缀在视觉上无法区分 —— 而颜色正是色弱场景下不可靠的那一维',
      );
    }
  });

  test('三种词缀的图标互不相同（不是同一张图重复登记）', () {
    final ids = <String>{
      'UI-ELITE-AFFIX-ACCEL',
      'UI-ELITE-AFFIX-SHIELD',
      'UI-ELITE-AFFIX-BARRAGE',
    };
    final files = <String>{};
    for (final id in ids) {
      final r = manifest.lookup(id);
      expect(r, isNotNull, reason: '$id 应存在');
      // 每个状态的运行时文件应各不相同。
      for (final f in r!.runtimeFiles) {
        files.add(f);
      }
    }
    expect(
      files.length,
      ids.length,
      reason: '三个词缀图标应指向三张不同的图（当前 ${files.length} 张）',
    );
  });
}
