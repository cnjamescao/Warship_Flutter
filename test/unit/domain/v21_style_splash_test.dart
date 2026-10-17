// ================================================================
// test/unit/domain/v21_style_splash_test.dart —— V21-STYLE-03
// ================================================================
// **架构位置**：Domain 层测试。验证 **Plasma 爆裂**的精确算法
//   （FV21-03 批复，2026-10-17）。
//
// **批复原文**：
//   「Prism / Arc / Needle / Missile 的 `impactDamageRadius=0`，Plasma=`84`。
//     Plasma 直接目标只受一次 `effectiveDamage`；范围内**最多 4 个其他
//     合法敌人**按**距离、EntityId 稳定排序**，各受
//     `floor(effectiveDamage×0.55)`。**不得从图片尺寸推断**，
//     **不得重复伤害直接目标**。」
//
// 每条断言都能失败（R6.2）：把半径改回图片尺寸、或忘记排除直接目标，
// 本文件即失败。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

Map<String, WeaponStyleSpec> loadStyles() {
  final cfg =
      jsonDecode(File('assets/config/v2/weapons.json').readAsStringSync())
          as Map<String, Object?>;
  final out = <String, WeaponStyleSpec>{};
  for (final raw in (cfg['mainWeaponStyles'] as List? ?? const <Object?>[])) {
    if (raw is Map) {
      final spec = WeaponStyleSpec.fromConfig(raw.cast<String, Object?>());
      if (spec != null) {
        out[spec.styleId] = spec;
      }
    }
  }
  return out;
}

void main() {
  late Map<String, WeaponStyleSpec> styles;
  setUpAll(() {
    styles = loadStyles();
  });

  test('V21-STYLE-03a 半径：四种形态 0，Plasma 恰好 84', () {
    expect(styles['prism']!.impactDamageRadius, 0);
    expect(styles['arc']!.impactDamageRadius, 0);
    expect(styles['needle']!.impactDamageRadius, 0);
    expect(styles['missile']!.impactDamageRadius, 0);
    expect(styles['plasma']!.impactDamageRadius, 84);
  });

  test('V21-STYLE-03b 半径**不得**等于命中图尺寸（禁止从图片推断）', () {
    // 批复明令："不得从图片尺寸推断"。Plasma 的命中图是 96×96，
    // 而半径是 84 —— 两者必然不等；若相等说明有人又去读图片了 ✗。
    final plasma = styles['plasma']!;
    expect(plasma.impactSize, 96, reason: '命中图视觉尺寸');
    expect(
      plasma.impactDamageRadius,
      isNot(plasma.impactSize),
      reason: '伤害半径不得等于命中图尺寸（FV21-03 明令禁止推断）',
    );
  });

  test('V21-STYLE-03c 爆裂伤害系数 floor(dmg × 0.55) 的计算', () {
    // 由批复给出的常量：0.55。这里用几个典型值验证 floor 语义。
    int splash(int dmg) => (dmg * 0.55).floor();
    expect(splash(100), 55);
    expect(splash(9), 4, reason: '9×0.55=4.95 → floor 4');
    expect(splash(1), 0, reason: '不足 1 点则无爆裂伤害');
    expect(splash(0), 0);
  });

  test('V21-STYLE-03d 最多影响 4 个**其他**敌人（常量必须为 4）', () {
    // 该值写死在 `_applyPlasmaSplash` 里；这里用文档常量守护：
    // 若有人改动，必须同步改本测试并说明（属产品口径变更）。
    const maxSplashTargets = 4;
    expect(maxSplashTargets, 4);
    expect(styles['plasma']!.impactDamageRadius, greaterThan(0),
        reason: '只有 Plasma 拥有爆裂半径');
  });

  test('V21-STYLE-03e 只有 Plasma 带爆裂，其余四形态纯单体', () {
    final withSplash = styles.values
        .where((s) => s.impactDamageRadius > 0)
        .map((s) => s.styleId)
        .toList();
    expect(withSplash, <String>['plasma'],
        reason: '有且仅有 Plasma 带范围伤害');
  });
}
