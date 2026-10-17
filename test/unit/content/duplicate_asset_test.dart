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

  test('T-ASSET-03 不同 Asset ID 的运行时图形内容不得互相同一', () {
    // 判重键 -> 持有它的 assetId 集合
    //
    // **v2.1 细化**：判重键由"仅文件内容"改为"**文件内容 + frameRect**"。
    //
    // 理由：v2.1 的素材是"**整张 sheet + 每个子图的 frameRect**"模型
    // （素材规范 §2/§4.2），**多组 Asset ID 共用同一张 sheet** 是其固有形态
    // （5 个武器形态、5 条命中、3 个通知、3 档奖章）。
    // 它们**渲染出来并不相同**（各自裁切不同格子），因此**不构成 F-29 缺陷** ——
    // F-29 的症状是"四种敌机**长得一样**"，即**渲染结果相同**。
    //
    // 判重键加上 frameRect 后：
    //   * 同文件 + **同** frameRect  → 仍判为重复 ✓ **F-29 的保护完整保留**；
    //   * 同文件 + **不同** frameRect → 不再误报 ✓ 支持 v2.1 sheet 模型。
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
        // frameRect 参与判重键（v2.1）：同一张 sheet 的不同格子是**不同画面**。
        final rects = <String>[
          for (final state in record.renderStates.values)
            for (final r in state.frameRects) r.join(','),
        ].join('|');
        final key =
            '${bytes.length}:${Object.hashAll(bytes)}#$rects';
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
    // 素材侧逐批修复中：107 → 101（敌机）→ 97（预警/危险区/激光/突破箭头）
    // → 93（精英名称条与三种词缀光环）→ 92（Bomber 圆形预警 WARN 独立）。
    // 按审计要求**只更新临时基线，不关闭 F-30 / F-27**。
    // 其余跨语义重复（投射物、武器效果、升级图标、HUD 等）仍待素材侧处理，
    // 产品负责人已明确 F-27 保持 P0 未关闭，因此这里继续冻结剩余规模。
    const knownDuplicateGroups = 42;
    const knownDuplicateIds = 32;

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

  test('F-27（敌机部分）5 类基础敌机的运行时状态互不重复（v2.0.6 已交付）', () {
    // 产品负责人 2026-10-16 确认：「5 类基础敌机均替换为独立原创图形与
    // 状态素材…23 个运行时状态无重复」。
    // 这里做**正向**确认：敌机之间不得共用任何运行时文件。
    const enemies = <String>[
      'GFX-EN-SCOUT',
      'GFX-EN-WING',
      'GFX-EN-SNIPER',
      'GFX-EN-BOMBER',
      'GFX-EN-SHIELD',
    ];

    final owner = <String, String>{}; // 文件路径 -> 持有它的敌机
    final clashes = <String>[];
    for (final id in enemies) {
      final record = manifest.lookup(id);
      expect(record, isNotNull, reason: '$id 未登记');
      for (final path in record!.runtimeFiles) {
        final previous = owner[path];
        if (previous != null && previous != id) {
          clashes.add('$path 同时属于 $previous 与 $id');
        }
        owner[path] = id;
      }
    }

    expect(
      clashes,
      isEmpty,
      reason: '敌机之间仍共用素材（F-27 的敌机部分未真正完成）：\n'
          '${clashes.join("\n")}',
    );
    // 顺带确认敌机的状态文件确实各自独立（不只是登记不同、内容相同由
    // T-ASSET-03 的重复检测负责）。
    expect(owner.length, greaterThanOrEqualTo(20),
        reason: '5 类敌机的运行时状态文件数量偏少（现 ${owner.length}）');
  });
}
