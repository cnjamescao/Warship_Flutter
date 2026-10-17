// ================================================================
// test/unit/presentation/v21_sheet_cell_structure_test.dart —— V21-FX-00
// ================================================================
// **架构位置**：Presentation 层测试。用**结构断言**证明
//   `V21SheetCell` 真的只露出一格（而不是整张 sheet）。
//
// **为什么不用 Golden**：我连续两轮尝试用 `matchesGoldenFile` 截裁切结果
//   都失败（10 分钟超时、无 PNG 产出）。根因很可能是
//   `Image.asset` 在 `testWidgets` 里解码不了测试包之外的资源 ——
//   而既有 golden 走的是 Flame 的资源通道，不是 `Image.asset`。
//   **与其反复试，不如用可量化、必然能跑的结构断言。**
//
// **本文件证明什么**：裁切窗口（`ClipRect` 的 widthFactor/heightFactor）
//   与对齐（`Align.alignment`）的**数值**是否等于"只露这一格"应有的值。
//   这比截图更精确 —— 截图只能看"像不像"，这里能算"是不是"。
//
// 每条断言都能失败（R6.2）：把 frameRect 换掉、或退回整图直出，即失败。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/v21_sheet_cell.dart';

/// 渲染组件并取回 `ClipRect` 与 `Align`（不依赖真实图片解码）。
Future<({double widthFactor, double heightFactor, Alignment align})> probe(
  WidgetTester tester, {
  required List<int>? frameRect,
  double sheetWidth = 2172,
  double sheetHeight = 724,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: V21SheetCell(
            imagePath: 'assets/images/v2/UNUSED.png',
            frameRect: frameRect,
            size: 192,
            sheetWidth: sheetWidth,
            sheetHeight: sheetHeight,
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  // 确认 ClipRect 存在（裁切真的被应用）。
  expect(find.byType(ClipRect), findsOneWidget);
  final alignFinder = find.descendant(
    of: find.byType(ClipRect),
    matching: find.byType(Align),
  );
  final align = tester.widget<Align>(alignFinder).alignment as Alignment;
  // ClipRect 的裁切由 Align 的 widthFactor/heightFactor 决定。
  final sized = tester.widget<Align>(alignFinder);
  return (
    widthFactor: sized.widthFactor ?? 1.0,
    heightFactor: sized.heightFactor ?? 1.0,
    align: align,
  );
}

void main() {
  testWidgets('V21-FX-00a 首格（724×724 / sheet 2172×724）只露 1/3 宽', (tester) async {
    final p = await probe(tester, frameRect: <int>[0, 0, 724, 724]);
    // 宽只露 724/2172 ≈ 0.333，高露满（724/724 = 1）。
    expect(p.widthFactor, closeTo(724 / 2172, 1e-9));
    expect(p.heightFactor, closeTo(1.0, 1e-9));
    // 首格靠左。
    expect(p.align.x, closeTo(-1.0, 1e-9));
  });

  testWidgets('V21-FX-00b 中格（x=724）对齐居中', (tester) async {
    final p = await probe(tester, frameRect: <int>[724, 0, 724, 724]);
    expect(p.widthFactor, closeTo(724 / 2172, 1e-9));
    expect(p.align.x, closeTo(0.0, 1e-9), reason: '中格应居中');
  });

  testWidgets('V21-FX-00c 末格（x=1448）靠右', (tester) async {
    final p = await probe(tester, frameRect: <int>[1448, 0, 724, 724]);
    expect(p.align.x, closeTo(1.0, 1e-9), reason: '末格应靠右');
  });

  testWidgets('V21-FX-00d 四帧序列（543×724）宽只露 1/4', (tester) async {
    final p = await probe(tester, frameRect: <int>[543, 0, 543, 724]);
    expect(p.widthFactor, closeTo(543 / 2172, 1e-9));
    // 第 2 帧：x=543，剩余 2172-543=1629，比例 543/1629 → 对齐负值。
    expect(p.align.x, lessThan(0));
  });

  testWidgets('V21-FX-00e frameRect 为 null 时**不裁切**（v2.0 素材）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: V21SheetCell(
              imagePath: 'assets/images/v2/UNUSED.png',
              frameRect: null,
              size: 96,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // **不得**出现 ClipRect —— 整图直出即整帧。
    expect(find.byType(ClipRect), findsNothing);
  });

  testWidgets('V21-FX-00f 宽高非正时不裁切、不崩溃', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: V21SheetCell(
              imagePath: 'assets/images/v2/UNUSED.png',
              frameRect: <int>[0, 0, 0, 0],
              size: 96,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ClipRect), findsNothing);
  });
}
