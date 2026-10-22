// ================================================================
// test/probe/surface_probe_test.dart —— 临时探针（确认测试基建）
// ================================================================
// **目的**：只回答一个问题 ——
//   `tester.binding.setSurfaceSize(1920×1080)` 之后，
//   被测 widget 通过 `MediaQuery.sizeOf` 读到的**到底是多少**？
//
// 我在视口门禁接线上**三次回退**，每次都是"以为基建能用"就动手 ✗。
// 这次先把这一步证实，再谈接线 ✓。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('probe：setSurfaceSize 是否改变 MediaQuery.sizeOf', (tester) async {
    // ① 默认（不设）
    late Size before;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            before = MediaQuery.sizeOf(c);
            return const SizedBox();
          },
        ),
      ),
    );
    // ignore: avoid_print
    print('[probe] 默认画布 = $before');

    // ② 改用 **tester.view**（这才是 MediaQuery 的真正来源）
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);
    late Size after;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            after = MediaQuery.sizeOf(c);
            return const SizedBox();
          },
        ),
      ),
    );
    // ignore: avoid_print
    print('[probe] 设 1920×1080 后 = $after');

    // ③ 设为 800×600（模拟小窗）—— 同样用 tester.view
    tester.view.physicalSize = const Size(800, 600);
    late Size small;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            small = MediaQuery.sizeOf(c);
            return const SizedBox();
          },
        ),
      ),
    );
    // ignore: avoid_print
    print('[probe] 设 800×600 后 = $small');

    // 结论断言：如果这条通过，说明 setSurfaceSize **确实**生效。
    expect(after, const Size(1920, 1080),
        reason: 'tester.view 应改变 MediaQuery.sizeOf');
    expect(small, const Size(800, 600));
  });
}
