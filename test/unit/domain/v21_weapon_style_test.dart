// ================================================================
// test/unit/domain/v21_weapon_style_test.dart —— V21-STYLE-01/02
// ================================================================
// **架构位置**：Domain 层测试。验证 v2.1 的五种主弹道形态
// （蓝图 §3.4、冻结表 §3）。
//
// **最关键的一条**：**无形态时必须与 v2.0 字节级等价** ——
// 这保证既有武器、既有回放、既有验收基准不被 v2.1 污染。
//
// 每条断言都能失败（R6.2）：改错任一倍率、或让无形态路径也套用倍率，
// 本文件即失败。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';
import 'package:warship_flutter/game/domain/values.dart';

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

const _target = TargetView(
  id: EntityId(EntityKind.enemy, 1),
  position: Vec2(960, 400),
  radius: 20,
);

List<FiringRequest> fire({WeaponStyleSpec? style}) {
  final w = PulseWeapon(activeStyle: style);
  // criticalChance 默认 0 ⇒ 不会暴击，断言只反映形态倍率。
  return w.step(
    playerPosition: const Vec2(960, 900),
    targets: <TargetView>[_target],
    dt: w.effectiveCadence + 1e-6,
    rng: Pcg32(7),
  );
}

void main() {
  late Map<String, WeaponStyleSpec> styles;
  setUpAll(() {
    styles = loadStyles();
  });

  test('V21-STYLE-01 五种形态全部解析，倍率与冻结表 §3 逐项一致', () {
    expect(styles.keys.toSet(), <String>{
      'prism', 'arc', 'plasma', 'needle', 'missile',
    });
    // 冻结表 §3 的精确值。
    const expected = <String, List<num>>{
      // damage, speed, radius, extraPierce, bounce
      'prism': [1.00, 0.95, 1.00, 1, 0],
      'arc': [0.82, 1.00, 0.90, 0, 1],
      'plasma': [1.22, 0.78, 1.35, 0, 0],
      'needle': [0.72, 1.48, 0.62, 2, 0],
      'missile': [1.08, 0.86, 1.05, 0, 0],
    };
    for (final e in expected.entries) {
      final s = styles[e.key]!;
      expect(s.damageMultiplier, e.value[0], reason: '${e.key} damage');
      expect(s.speedMultiplier, e.value[1], reason: '${e.key} speed');
      expect(s.radiusMultiplier, e.value[2], reason: '${e.key} radius');
      expect(s.extraPierce, e.value[3], reason: '${e.key} pierce');
      expect(s.bounce, e.value[4], reason: '${e.key} bounce');
    }
    // Missile 是唯一追踪形态。
    expect(styles['missile']!.homing, isTrue);
    for (final k in <String>['prism', 'arc', 'plasma', 'needle']) {
      expect(styles[k]!.homing, isFalse, reason: '$k 不应追踪');
    }
  });

  test('V21-STYLE-02 **无形态**时与 v2.0 字节级等价', () {
    final r = fire();
    expect(r, hasLength(1));
    final req = r.single;
    // 无形态 ⇒ 不带任何形态信息。
    expect(req.weaponStyleId, isNull);
    expect(req.projectileAssetId, isNull);
    expect(req.impactAssetId, isNull);
    expect(req.impactCueId, isNull);
    expect(req.pierceRemaining, 0);
    expect(req.bounceRemaining, 0);
    expect(req.homingTargetId, isNull);
    expect(req.impactDamageRadius, 0);
    // 数值必须等于构造参数原值（未被任何倍率污染）。
    expect(req.speed, 1250);
    expect(req.radius, 6);
    expect(req.damage, 9);
  });

  test('V21-STYLE-02b 有形态时倍率与特性正确生效', () {
    for (final id in <String>['prism', 'arc', 'plasma', 'needle', 'missile']) {
      final s = styles[id]!;
      final req = fire(style: s).single;
      expect(req.weaponStyleId, id);
      expect(req.projectileAssetId, s.projectileAssetId);
      expect(req.impactAssetId, s.impactAssetId);
      expect(req.impactCueId, s.impactCueId);
      expect(req.pierceRemaining, s.extraPierce, reason: '$id pierce');
      expect(req.bounceRemaining, s.bounce, reason: '$id bounce');
      expect(req.homingTargetId, s.homing ? _target.id : null,
          reason: '$id homing');
      // 倍率：round(9 × dmg) / 1250 × speed / 6 × radius。
      expect(req.damage, (9 * s.damageMultiplier).round(),
          reason: '$id damage');
      expect(req.speed, closeTo(1250 * s.speedMultiplier, 1e-9),
          reason: '$id speed');
      expect(req.radius, closeTo(6 * s.radiusMultiplier, 1e-9),
          reason: '$id radius');
    }
  });

  test('V21-STYLE-02c 爆裂半径由**显式配置**给出（FV21-03 已裁决）', () {
    // 蓝图 §3.4：「伤害半径由**显式** impactDamageRadius 配置，
    // **绝不从 96px 图片尺寸推断**」。
    //
    // FV21-03 批复（2026-10-17）：Prism/Arc/Needle/Missile = 0，Plasma = 84。
    const expected = <String, double>{
      'prism': 0,
      'arc': 0,
      'needle': 0,
      'missile': 0,
      'plasma': 84,
    };
    for (final e in expected.entries) {
      final s = styles[e.key]!;
      expect(s.impactDamageRadius, e.value, reason: '${e.key} 的爆裂半径');
      // **关键**：半径不得等于命中图尺寸（那就是"从图片推断"了 ✗）。
      expect(
        s.impactDamageRadius,
        isNot(s.impactSize),
        reason: '${e.key} 不得把命中图尺寸（${s.impactSize}）当作伤害半径',
      );
    }
  });
}
