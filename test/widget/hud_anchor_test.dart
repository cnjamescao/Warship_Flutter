// ================================================================
// test/widget/hud_anchor_test.dart —— F-32（P0）
// ================================================================
// 玩家反馈：「显示 Lv 和剩余命数的状态栏横在窗口的 1/3 处」
//（全屏时看不出问题，非全屏时才明显）。
//
// 根因：HUD 的定位此前有一部分是**相对世界坐标**算的：
//
//     bottom: 窗口高 - y × scale        // ← y 是"距世界顶"的逻辑坐标
//     right:  窗口宽 - x × scale
//
// 这等于把元素锚在"距窗口**顶** y×scale"的位置。窗口越高越窄，
// 该值越大，元素就越往窗口中间浮（1000×1000 的窗口下浮到距底
// **456px**，接近窗口中央）。全屏 1920×1080 时恰好等于 36px，
// 所以只有非全屏才看得出来。
//
// 正确：底部/右侧元素应像顶部一样，用**距窗口边的固定边距**
// `(逻辑尺寸 - 逻辑坐标) × scale`。
//
// 现有 HUD 有 5 处锚定（左上/中上/右上/中下/右下），本文件用
// **静态检查**守住"不得再用相对世界坐标的反向锚定"——
// 这类问题单看某个窗口是发现不了的。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('F-32 HUD 的反向锚定（bottom/right）不得用 "窗口尺寸 − 逻辑坐标×scale"', () {
    final source = File('lib/app/v2_run_screen.dart').readAsStringSync();
    final offenders = <String>[];

    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//')) {
        continue; // 注释里会引用被禁止的写法（我第一版就因此误报）
      }
      // 反面模式：用窗口尺寸减去逻辑坐标×scale 做反向锚定。
      if (RegExp(
        r'(bottom|right)\s*:\s*viewport\.viewportSize\.(height|width)\s*-',
      ).hasMatch(line)) {
        offenders.add('第 ${i + 1} 行：${line.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'HUD 的反向锚定必须用「距窗口边的固定边距」= '
          '(逻辑尺寸 − 逻辑坐标) × scale，而不是「窗口尺寸 − 逻辑坐标 × scale」。\n'
          '后者会把元素锚在距窗口另一侧的位置，窗口越高/越宽就越往中间浮'
          '（F-32：Lv/命数状态栏横在窗口 1/3 处）。\n'
          '违规处：\n${offenders.join('\n')}',
    );
  });
}
