// ================================================================
// test/architecture/comment_density_test.dart —— 注释密度下限
// ================================================================
// **架构位置**：架构守卫。与 `comment_standard_test.dart`（**文件头**合规）
//   互补：那个守"有没有头"，这个守"头之外还说了没有"。
//
// **为什么需要**：用户明确要求「所有的代码要有非常详细完整的注释，
//   目标是以后的工程师能通过注释明白设计思路和架构」。
//   只查文件头时，一个 700 行的实现文件可以头写得漂亮、体全是代码 ✗ ——
//   那正是"能过检查但读不懂"的状态。
//
// **阈值取"下限"而非"目标"**：本项目实测平均约 30%，
//   最低的文件约 16%。这里设 **12%** 作为**不许再掉**的地板，
//   而不是要求每个文件都到 30%（短文件、纯数据文件天然偏低）。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 注释行占比的**地板**（低于它说明这个文件已经"只剩代码"）。
const double kMinCommentRatio = 0.12;

/// 少于这么多行的文件不参与统计（getter/常量的薄封装天然偏低）。
const int kMinLinesForCheck = 40;

void main() {
  test('注释密度不得低于 ${(kMinCommentRatio * 100).toStringAsFixed(0)}%', () {
    final offenders = <String>[];
    var checked = 0;
    var ratioSum = 0.0;

    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      if (lines.length < kMinLinesForCheck) {
        continue;
      }
      checked++;
      final comments =
          lines.where((l) => l.trimLeft().startsWith('//')).length;
      final ratio = comments / lines.length;
      ratioSum += ratio;
      if (ratio < kMinCommentRatio) {
        offenders.add(
          '${f.path}：${(ratio * 100).toStringAsFixed(1)}%'
          '（${lines.length} 行 / $comments 行注释）',
        );
      }
    }

    expect(checked, greaterThan(30), reason: '应检查到足够多的文件');
    expect(
      offenders,
      isEmpty,
      reason: '以下文件注释密度低于地板 —— 后续工程师无法从注释理解设计：\n'
          '${offenders.join("\n")}',
    );
    // 顺带记录平均值（只打印，不做硬断言 —— 平均值受文件构成影响大）。
    // ignore: avoid_print
    print('注释密度：检查 $checked 个文件，平均 '
        '${(ratioSum / checked * 100).toStringAsFixed(1)}%');
  });
}
