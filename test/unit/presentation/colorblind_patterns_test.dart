// ================================================================
// test/unit/presentation/colorblind_patterns_test.dart —— F-12 / T-UI-02
// ================================================================
// 裁决要求「颜色置灰后仍能区分危险、奖励、稀有度及词缀；
// **任一关键状态不能仅依赖颜色**」，且叠层「**始终显示，不依赖设置**」。
//
// 本文件验证：
//   1. 三套图案资源**真实存在**且可解析（不是只写了一个常量）；
//   2. 映射完备 —— 每个语义类别都有对应的第二维度；
//   3. **没有任何设置门控** —— 叠层是常量，不读设置。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/presentation/colorblind_patterns.dart';

late AssetManifest manifest;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    manifest = AssetManifest.parse(
      jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
          as Map<String, Object?>,
    ).requireValue;
  });

  test('T-UI-02 三套色弱叠层资源都真实存在且可解析', () {
    for (final pattern in ColorblindPattern.values) {
      final record = manifest.lookup(pattern.assetId);
      expect(
        record,
        isNotNull,
        reason: '${pattern.name} 的叠层 ${pattern.assetId} 在 manifest 中不存在',
      );
      expect(
        record!.runtimeFiles,
        isNotEmpty,
        reason: '${pattern.assetId} 应有运行时文件',
      );
    }
  });

  test('T-UI-02 三个语义类别的叠层**互不相交**（不是共用同一张图）', () {
    // 注意：每个 UI 资源有 normal/pressed/disabled/focus **四个状态**，
    // 各有独立文件（3 × 4 = 12 个文件）。所以不能断言"总文件数 == 3" ——
    // 那是我第一版写错的断言。正确的判据是**三组两两不相交**：
    // 只要没有重叠，就说明三套图案确实是三张不同的图。
    final groups = <ColorblindPattern, Set<String>>{
      for (final p in ColorblindPattern.values)
        p: manifest.lookup(p.assetId)!.runtimeFiles.toSet(),
    };

    final values = ColorblindPattern.values;
    for (var i = 0; i < values.length; i++) {
      for (var j = i + 1; j < values.length; j++) {
        final overlap = groups[values[i]]!.intersection(groups[values[j]]!);
        expect(
          overlap,
          isEmpty,
          reason: '${values[i].name} 与 ${values[j].name} 共用了文件：$overlap',
        );
      }
    }

    // 每个类别内部：状态数与文件数一致（没有状态缺文件）。
    for (final p in values) {
      final record = manifest.lookup(p.assetId)!;
      expect(
        groups[p]!.length,
        record.states.length,
        reason: '${p.assetId} 的状态数与文件数应一致',
      );
    }
  });

  test('T-UI-02 叠层**始终显示**，不存在任何设置开关门控', () {
    // 裁决：「不新增色弱模式开关…上述叠层始终显示，不依赖设置」。
    // 这里断言"始终可见"是一个编译期常量 —— 没有开关可关。
    expect(ColorblindPattern.alwaysVisible, isTrue);
  });

  test('T-UI-02 低血/濒危属于危险，必须有第二维度', () {
    // 边界两侧都要覆盖。
    for (final ratio in <double>[0.0, 0.2, 0.3, 0.35]) {
      expect(
        patternForPlayerVital(hpRatio: ratio),
        ColorblindPattern.danger,
        reason: 'HP ${(ratio * 100).round()}% 属于危险，不得只有颜色',
      );
    }
    // 安全区间不需要叠层（避免无意义地把画面塞满图案）。
    expect(patternForPlayerVital(hpRatio: 0.8), isNull);
  });

  test('T-UI-02 会造成伤害的危险区与预警都需要三角斜线', () {
    expect(
      hazardNeedsDangerPattern(isWarning: true, dealsDamage: false),
      isTrue,
      reason: '预警阶段也必须可辨（裁决要求保留几何形状/收缩）',
    );
    expect(
      hazardNeedsDangerPattern(isWarning: false, dealsDamage: true),
      isTrue,
      reason: '已生效的危险区同样必须可辨',
    );
    expect(
      hazardNeedsDangerPattern(isWarning: true, dealsDamage: true),
      isTrue,
    );
  });

  test('T-UI-02 奖励与稀有度的判据存在且为真值传递', () {
    expect(pickupNeedsRewardPattern(isPickup: true), isTrue);
    expect(pickupNeedsRewardPattern(isPickup: false), isFalse);
    expect(draftCardNeedsRarityPattern(hasRarity: true), isTrue);
    expect(draftCardNeedsRarityPattern(hasRarity: false), isFalse);
  });
}
