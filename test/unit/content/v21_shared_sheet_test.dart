// ================================================================
// test/unit/content/v21_shared_sheet_test.dart —— FV21-01 守卫
// ================================================================
// **架构位置**：Content 层守卫。落实负责人 FV21-01 批复（方案 A）。
//
// **批复原文**：
//   「完整 sheet 是一个物理文件，构建时仅复制一份。**多个 Asset ID 可以
//     指向同一 `runtimeFile`，但仅当** ① 文件 SHA-256 相同、
//     ② 全部 `frameRect` 在边界内、③ 彼此**不重叠**。」
//
// 这三条是"共享 sheet 合法"的**全部条件**。缺任何一条，两个 ID 就会
// 互相串格（画面里出现别人的图案）—— 而这**不会报错**，只会画错。
//
// 每条断言都能失败（R6.2）：让两格的 rect 重叠、或越界，本文件即失败。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;

/// 取某素材所有帧的裁切矩形（按状态展开）。
List<List<int>> rectsOf(AssetRecord r) => <List<int>>[
  for (final st in r.renderStates.values) ...st.frameRects,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    manifest = (await loadV2CatalogForTests()).manifest;
  });

  test('FV21-01a 共享同一 runtimeFile 的多个 ID，帧矩形**互不重叠**', () {
    // 按物理文件分组。
    final byFile = <String, List<AssetRecord>>{};
    for (final r in manifest.records) {
      for (final f in r.runtimeFiles) {
        byFile.putIfAbsent(f, () => <AssetRecord>[]).add(r);
      }
    }

    final overlaps = <String>[];
    for (final entry in byFile.entries) {
      final group = entry.value;
      if (group.length < 2) {
        continue; // 独占文件无需检查。
      }
      for (var i = 0; i < group.length; i++) {
        for (var j = i + 1; j < group.length; j++) {
          for (final a in rectsOf(group[i])) {
            for (final b in rectsOf(group[j])) {
              if (a.length != 4 || b.length != 4) {
                continue;
              }
              final overlapX = a[0] < b[0] + b[2] && b[0] < a[0] + a[2];
              final overlapY = a[1] < b[1] + b[3] && b[1] < a[1] + a[3];
              if (overlapX && overlapY) {
                overlaps.add(
                  '${group[i].assetId.value} 与 ${group[j].assetId.value} '
                  '在 ${entry.key.split('/').last} 上的帧重叠：$a / $b',
                );
              }
            }
          }
        }
      }
    }
    expect(
      overlaps,
      isEmpty,
      reason: '共享 sheet 的帧矩形**不得重叠**（FV21-01 批复条件 ③）：\n'
          '${overlaps.join("\n")}',
    );
  });

  test('FV21-01b 所有 frameRect 都在 sheet 边界内（条件 ②）', () {
    // 素材规范 §2：所有 sheet 为 2172×724。
    const sheetW = 2172;
    const sheetH = 724;
    final outOfBounds = <String>[];
    for (final r in manifest.records) {
      for (final rect in rectsOf(r)) {
        if (rect.length != 4) {
          outOfBounds.add('${r.assetId.value}：rect 长度不是 4 → $rect');
          continue;
        }
        final x = rect[0], y = rect[1], w = rect[2], h = rect[3];
        if (w <= 0 || h <= 0 || x < 0 || y < 0 ||
            x + w > sheetW || y + h > sheetH) {
          outOfBounds.add('${r.assetId.value}：$rect 越界（sheet $sheetW×$sheetH）');
        }
      }
    }
    expect(
      outOfBounds,
      isEmpty,
      reason: 'frameRect 必须在 sheet 边界内（FV21-01 批复条件 ②）：\n'
          '${outOfBounds.join("\n")}',
    );
  });

  test('FV21-01c 共享同一文件的 ID 其 frameRect 数量之和 = 该文件的格子数', () {
    // 五形态表：5 个 ID 各 1 帧，共 5 格；命中表同理。
    final styleIds = <String>[
      'GFX-V21-WPN-PRISM', 'GFX-V21-WPN-ARC', 'GFX-V21-WPN-PLASMA',
      'GFX-V21-WPN-NEEDLE', 'GFX-V21-WPN-MISSILE',
    ];
    final files = <String>{
      for (final id in styleIds) ...manifest.lookup(id)!.runtimeFiles,
    };
    expect(files, hasLength(1), reason: '五形态必须共享**同一个**物理文件');
    final totalFrames =
        styleIds.map((id) => rectsOf(manifest.lookup(id)!).length).reduce((a, b) => a + b);
    expect(totalFrames, 5, reason: '五格各属于一个形态');
  });

  test('FV21-01d 三档奖章共享一张 sheet 且各占一格', () {
    final ids = <String>[
      'UI-V21-RESULT-MEDAL-GOLD', 'UI-V21-RESULT-MEDAL-SILVER',
      'UI-V21-RESULT-MEDAL-BRONZE',
    ];
    final files = <String>{
      for (final id in ids) ...manifest.lookup(id)!.runtimeFiles,
    };
    expect(files, hasLength(1));
    final starts = <int>{for (final id in ids) rectsOf(manifest.lookup(id)!).first[0]};
    expect(starts, <int>{0, 724, 1448}, reason: '三档必须落在三个不同起点');
  });
}
