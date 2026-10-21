// ================================================================
// test/web/web_viewport_gate_test.dart —— WEB-T-02
// ================================================================
// **架构位置**：Web 平台验收测试（视口门槛）。
//
// **依据**（WEB-T-02）：
//   「**1023×640、1024×639 不进入 Playing 且不推进逻辑**；
//     1024×640、4:3、16:9、21:9 保持 `1920×1080` 逻辑世界、
//     HUD 与安全区完整。」
//
// **为什么门槛测试要精确到 1 px**：边界值是最容易被"顺手改一下"的地方 ✗。
//   若有人把 `>=` 写成 `>`，`1024×640` 就会被拒 —— 而这条用例会立刻失败 ✓。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/viewport_gate.dart';

void main() {
  test('WEB-T-02a 门槛常量与规范一致（1024 × 640）', () {
    expect(kMinViewportWidth, 1024);
    expect(kMinViewportHeight, 640);
    // 逻辑世界固定 1920×1080。
    expect(kLogicalViewportWidth, 1920);
    expect(kLogicalViewportHeight, 1080);
  });

  test('WEB-T-02b **1023×640** 与 **1024×639** 必须被拒（差 1 px 也不行）', () {
    expect(isViewportSupported(const Size(1023, 640)), isFalse,
        reason: '宽度少 1 px 必须拒绝');
    expect(isViewportSupported(const Size(1024, 639)), isFalse,
        reason: '高度少 1 px 必须拒绝');
    // 且**不得推进逻辑**（同义函数）。
    expect(canAdvanceLogic(const Size(1023, 640)), isFalse);
    expect(canAdvanceLogic(const Size(1024, 639)), isFalse);
  });

  test('WEB-T-02c **1024×640** 恰好通过（边界是 >=，不是 >）', () {
    expect(isViewportSupported(const Size(1024, 640)), isTrue);
  });

  test('WEB-T-02d 三种宽高比都通过（4:3 / 16:9 / 21:9）', () {
    for (final size in <Size>[
      const Size(1280, 960),  // 4:3
      const Size(1920, 1080), // 16:9
      const Size(2100, 900),  // 21:9
    ]) {
      expect(isViewportSupported(size), isTrue, reason: '$size 应通过');
    }
  });
}
