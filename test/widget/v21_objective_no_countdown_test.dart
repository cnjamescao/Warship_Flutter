// ================================================================
// test/widget/v21_objective_no_countdown_test.dart —— V21-HUD-01
// ================================================================
// **架构位置**：表现层静态守卫。断言 **UI 层不再自行计算剩余秒数**。
//
// **依据**（产品冻结表 §4 原文）：
//   「顶部中间从 v2.1 起**不得显示** `190-combatSeconds` 或裸数字。
//     UI **只能**从 `objectiveKey`/`objectiveArgs` 显示文案，
//     **不能自行根据时间猜测**。」
//
// **为什么用静态扫描而不是截图**：截图只能证明"这一帧没有数字"，
//   证明不了"以后不会有人又加回来"。静态扫描能**长期**挡住回归。
//
// 每条断言都能失败（R6.2）：在 UI 层重新引入 `190 -` 之类的计算，
//   本文件即失败。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// UI 层文件（**规则层**允许计算时间，只有表现层不许自己算）。
const List<String> kUiFiles = <String>[
  'lib/app/v2_run_screen.dart',
  'lib/app/v2_app_flow.dart',
];

void main() {
  test('V21-HUD-01 UI 层不得自行计算剩余秒数（190 - combatSeconds）', () {
    final offenders = <String>[];
    for (final path in kUiFiles) {
      final file = File(path);
      if (!file.existsSync()) {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // 跳过注释：注释里出现这个表达式是**说明**，不是实现。
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('//') || trimmed.startsWith('///')) {
          continue;
        }
        // 命中任意一种"自己算剩余秒数"的写法。
        final looksLikeCountdown =
            RegExp(r'190\s*-').hasMatch(line) ||
                RegExp(r'150\s*-\s*hud\.combatSeconds').hasMatch(line);
        if (looksLikeCountdown) {
          offenders.add('$path:${i + 1}  ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'UI 层出现了自行计算的剩余秒数 —— 冻结表 §4 明文禁止：\n'
          '${offenders.join("\n")}\n'
          '目标文案必须来自 `hud.objectiveKey` + `hud.objectiveArgs`。',
    );
  });

  test('V21-HUD-01b UI 层确实使用了 objectiveKey / objectiveArgs', () {
    // 反向接线断言：不只要"没有裸数字"，还要"真的用了规则层给的字段"。
    final src = File('lib/app/v2_run_screen.dart').readAsStringSync();
    expect(src, contains('objectiveKey'),
        reason: '目标文案必须从 objectiveKey 取');
    expect(src, contains('objectiveArgs'),
        reason: '模板参数必须从 objectiveArgs 取');
    expect(src, contains('isSectorClearConfirming'),
        reason: '清场确认窗是独立字段');
  });

  test('V21-HUD-01c 目标文案一律经 catalog.text 解析（不直接显示 key）', () {
    final src = File('lib/app/v2_run_screen.dart').readAsStringSync();
    // objectiveKey 必须作为 catalog.text 的第一个参数使用。
    expect(
      src,
      contains('catalog.text(key'),
      reason: '必须经 catalog.text 解析，否则会把 key 原文显示给玩家',
    );
  });
}
