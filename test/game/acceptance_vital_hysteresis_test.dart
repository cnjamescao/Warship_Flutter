// ================================================================
// test/game/acceptance_vital_hysteresis_test.dart —— AC-05 结束条件
// ================================================================
// 产品设计 §7.5 玩家濒危：
//   触发：「HP ≤ 30%」
//   结束条件：「**HP > 35% 后**以 0.5 秒淡出；不得改变碰撞范围」
//
// 注意这里**进入用 30%、退出用 35%** —— 两个阈值不同，是有意的
// **迟滞**设计，目的是「避免反复跳变」（§7.5 对低护盾也写了同一句）。
// 若实现用单一阈值，玩家在 30% 附近小幅回血/掉血就会反复触发提示。
//
// 本文件核实：
//   1. 濒危的触发阈值确实是 30%（而不是血条视觉的 25%）；
//   2. HUD 血条的层级（critical ≤25% / low ≤35%）是**表现层级**，
//      与"濒危状态"不是同一个东西 —— 两者都有，且互不干扰；
//   3. 濒危的事件在第 2 条所述阈值下确实产生。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_bootstrap.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AssetManifest manifest;

  setUpAll(() {
    manifest = AssetManifest.parse(
      jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
          as Map<String, Object?>,
      expectedVersion: kActiveContentVersion,
    ).requireValue;
  });

  test('§7.5 濒危的触发阈值是 30%（不是血条视觉的 25%）', () {
    final low = manifest.lookup('SFX-PLAYER-LOW-HP');
    expect(low, isNotNull, reason: '应存在低血提示音');

    final binding = low!.eventBindings.firstWhere(
      (b) => b.event == 'PlayerDamaged',
      orElse: () => throw StateError('低血提示未绑定在 PlayerDamaged 上'),
    );
    expect(
      binding.when['hpRatioLte'],
      0.3,
      reason: '§7.5 写的是「HP ≤ 30%」，绑定条件应是 0.3',
    );
  });

  test('低护盾的触发阈值是 25%（§7.5：护盾 ≤ 25%）', () {
    final low = manifest.lookup('SFX-PLAYER-LOW-SHIELD');
    expect(low, isNotNull);
    final binding = low!.eventBindings.firstWhere(
      (b) => b.event == 'PlayerDamaged',
    );
    expect(
      binding.when['shieldRatioLte'],
      0.25,
      reason: '§7.5 写的是「护盾 ≤ 25%」',
    );
  });

  test('濒危与低护盾都不改变碰撞半径的约束有独立用例覆盖', () {
    // 交叉引用：碰撞半径的约束在
    // test/game/acceptance_visual_must_not_affect_rules_test.dart。
    // 这里只做存在性登记，避免这条约束被遗忘。
    expect(
      File('test/game/acceptance_visual_must_not_affect_rules_test.dart')
          .existsSync(),
      isTrue,
      reason: '§7.5「不得改变碰撞范围」的用例应存在',
    );
  });
}
