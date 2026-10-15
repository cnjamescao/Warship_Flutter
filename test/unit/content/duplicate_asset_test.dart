// ================================================================
// test/unit/content/duplicate_asset_test.dart —— T-ASSET-03（F-29）
// ================================================================
// 存在理由：F-29 的症状是"四种敌机长得一样"，而**没有任何一条既有
// 测试能发现它** —— 素材文件、manifest 记录、事件绑定全都是齐的，
// 只是**四张不同的图实际是同一个文件**。
//
// 这类"名字不同、内容相同"的缺陷，只有**比对文件内容**才能发现。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    manifest = (await loadV2CatalogForTests()).manifest;
  });

  test('T-ASSET-03 不同 Asset ID 的运行时图形文件不得互相同一', () {
    // path -> 持有它的 assetId 集合
    final byContent = <String, Set<String>>{};

    for (final record in manifest.records) {
      if (!record.isVisual) {
        continue;
      }
      for (final path in record.runtimeFiles) {
        final file = File(path);
        if (!file.existsSync()) {
          continue;
        }
        // ⚠️ 必须读**全文**并只 open 一次。
        // 我第一版写成 `openSync().readSync(4096)` 之后又 `openSync()` 一次，
        // 指纹实际是坏的 —— 它把毫不相干的资源（例如首页 Logo 与敌机）
        // 归成同一组。**差一点又报出一个假发现。**
        final bytes = file.readAsBytesSync();
        final key =
            '${bytes.length}:${Object.hashAll(bytes)}';
        byContent.putIfAbsent(key, () => <String>{}).add(record.assetId.value);
      }
    }

    final shared = byContent.entries
        .where((e) => e.value.length > 1)
        .map((e) => e.value.toList()..sort())
        .toList();

    // ⚠️ **已知缺口冻结（F-29）**。
    //
    // 当前素材包里 Scout / Wing / Sniper / Bomber 在每个状态下**共用同一张
    // 图**（哈希一致，运行时副本与素材包源文件都如此）。这是**素材侧缺陷**，
    // 研发不改素材，因此这里把现状固定下来：
    //   * 缺口不会被遗忘（它是一条会跑的测试）；
    //   * **素材侧一旦补齐，本用例会失败并提示更新** ——
    //     那时把它改回 `expect(shared, isEmpty)` 即可。
    //
    // 允许出现的重复组（每组内的 Asset ID 视为"同一张图"）。
    // F-30：素材包**大范围**存在同名不同图的问题 ——
    // 127 个图形/UI Asset ID 中有 107 个（84%）与别的 ID 共用同一个文件，
    // 只有 20 个是独立美术。因此这里冻结的是**规模**：
    // 素材侧补齐后重复组数会大幅下降，本用例即会失败并提示更新。
    const knownDuplicateGroups = 42;
    const knownDuplicateIds = 107;

    final duplicateIds = shared.expand((g) => g).toSet();

    // ignore: avoid_print
    print('F-30 图形重复：${shared.length} 组，涉及 ${duplicateIds.length} 个 Asset ID');

    expect(
      duplicateIds.length,
      lessThanOrEqualTo(knownDuplicateIds),
      reason: '参与重复的 Asset ID 增加了（登记值 $knownDuplicateIds，'
          '实际 ${duplicateIds.length}）—— 有新的"同名不同图"被引入。',
    );
    expect(
      shared.length,
      lessThanOrEqualTo(knownDuplicateGroups),
      reason: '重复组数增加了（登记值 $knownDuplicateGroups，'
          '实际 ${shared.length}）。',
    );

    // 反向确认：缺口**确实还在**。素材侧补齐后本用例会失败，
    // 届时把它改成 `expect(shared, isEmpty)` 并关闭 F-30。
    expect(
      duplicateIds.length,
      knownDuplicateIds,
      reason: 'F-30 登记的重复规模已变化（现为 ${duplicateIds.length}）—— '
          '素材侧补齐了？请把本用例改为 expect(shared, isEmpty) 并关闭 F-30。',
    );
  });
}
