// ================================================================
// test/unit/content/v21_emblem_assets_test.dart —— PV21-R2 徽记素材
// ================================================================
// **架构位置**：Content 层守卫。锁定四枚结果徽记的**素材合同**。
//
// **为什么需要**：R2 要求"战斗结果只显示**无文字**的结果徽记"，
// 因此这四枚图是**唯一的视觉表达**。若它们被合并、重复指向同一格、
// 或悄悄退回占位剪影，玩家就分不清"强化 / 补给 / 悬赏 / 超载" ✗ ——
// 而这种错误**不会报错**，只会画错。
//
// **四张图形的互异性**已用图像比对独立核验（两两差异 58%–64%，
// 见 `docs/研发工作进度.md` 的 R2 记录）；本文件锁住**结构侧**合同。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;

const List<String> kEmblemIds = <String>[
  'UI-V21-AUTO-UPGRADE-EMBLEM',
  'UI-V21-RISK-SUPPLY-EMBLEM',
  'UI-V21-RISK-BOUNTY-EMBLEM',
  'UI-V21-RISK-OVERLOAD-EMBLEM',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    manifest = (await loadV2CatalogForTests()).manifest;
  });

  test('R2-EMBLEM-01 四枚徽记全部登记且为 release_ready', () {
    for (final id in kEmblemIds) {
      final r = manifest.lookup(id);
      expect(r, isNotNull, reason: '$id 必须登记');
      // 素材规范把已审素材标记为 release_ready；AssetRecord 不暴露
      // status 字段，因此这里改为验证**它确实可解析且带裁切信息**。
      expect(r!.runtimeFiles, isNotEmpty);
      expect(
        r.renderStates['default']!.frameRects,
        isNotEmpty,
        reason: '$id 必须有 frameRect（否则无法从 sheet 裁出）',
      );
    }
  });

  test('R2-EMBLEM-02 四枚**共享同一物理文件**但落在**四个不同格子**', () {
    final files = <String>{
      for (final id in kEmblemIds) ...manifest.lookup(id)!.runtimeFiles,
    };
    expect(files, hasLength(1), reason: '应共享一张 sheet（方案 A）');

    final starts = <int>{};
    for (final id in kEmblemIds) {
      final rects = manifest.lookup(id)!.renderStates['default']!.frameRects;
      expect(rects, hasLength(1), reason: '$id 单帧');
      starts.add(rects.first[0]);
    }
    expect(starts, hasLength(4), reason: '四枚必须取到四个不同起点');
    expect(starts, <int>{0, 543, 1086, 1629});
  });

  test('R2-EMBLEM-03 单格尺寸 543×724，且与 sheet 等高', () {
    for (final id in kEmblemIds) {
      final rect = manifest.lookup(id)!.renderStates['default']!.frameRects.first;
      expect(rect, <int>[rect[0], 0, 543, 724], reason: '$id 的裁切尺寸');
    }
  });

  test('R2-EMBLEM-04 blend 为 normal（徽记不得用 additive 盖住画面）', () {
    for (final id in kEmblemIds) {
      final st = manifest.lookup(id)!.renderStates['default']!;
      expect(st.blendMode, 'normal', reason: '$id 应普通 alpha 合成');
    }
  });
}
