// ================================================================
// test/support/perf_baseline.dart —— 性能基线输入 / 报告输出分离（F-42）
// ================================================================
// **负责人裁定（2026-10-16，F-42 / P1）：采用方案 A —— 分离基线输入与报告输出。**
//
// 1. `test/fixtures/performance/*.json` 必须是**只读、受版本控制的基线输入**；
//    正常测试与 CI **禁止改写**。
// 2. 本次采样报告写入 `build/`（**不提交**）。
// 3. 只有显式的 `UPDATE_PERF_BASELINE=1` 专用维护流程允许重建基线，
//    并记录环境、原因与前后差异。
// 5. **不**把开发机 p50/p95/p99 当作跨机器硬门槛。
//
// **修复前的缺陷**：测试先 `writeAsStringSync` 写 fixture，再读回同一个
// 文件断言 —— 读到的是自己刚写的值，**断言恒为真、测不出回归**，
// 且每次跑测试都把 fixture 改写成当机数值。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'sha256.dart';

/// 是否处于**显式的基线重建维护流程**。
///
/// 仅当 `UPDATE_PERF_BASELINE=1` 时为真；正常测试与 CI 一律为假。
bool get isUpdatingPerfBaseline =>
    Platform.environment['UPDATE_PERF_BASELINE'] == '1';

/// 报告输出路径：`test/fixtures/performance/x.json` → `build/performance/x.json`。
///
/// 报告**不提交**（`build/` 已在 `.gitignore` 中）。
String perfReportPath(String baselinePath) {
  final name = baselinePath.split('/').last;
  return 'build/performance/$name';
}

/// 写出本次采样报告；**仅**在显式维护流程下才同时重建基线。
///
/// 返回实际写出的报告路径。
String writePerfReport({
  required String baselinePath,
  required String json,
}) {
  final reportPath = perfReportPath(baselinePath);
  final reportFile = File(reportPath);
  reportFile.parent.createSync(recursive: true);
  reportFile.writeAsStringSync(json);

  if (isUpdatingPerfBaseline) {
    // 维护流程：重建基线。按裁定第 3 条记录环境与原因。
    final baselineFile = File(baselinePath);
    baselineFile.parent.createSync(recursive: true);
    final existed = baselineFile.existsSync();
    final before = existed
        ? _sha256Of(baselineFile.readAsBytesSync())
        : '(不存在)';
    baselineFile.writeAsStringSync(json);
    final after = _sha256Of(baselineFile.readAsBytesSync());
    stdout.writeln(
      '[perf-baseline] **已重建基线** $baselinePath\n'
      '  环境: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
      '  原因: UPDATE_PERF_BASELINE=1 显式维护流程\n'
      '  前后差异: $before → $after',
    );
  }
  return reportPath;
}

/// 读取本次报告（供"报告可解析"类断言使用）。
Map<String, Object?> readPerfReport(String reportPath) =>
    jsonDecode(File(reportPath).readAsStringSync()) as Map<String, Object?>;

/// 读取**只读基线**（受版本控制的输入）；不存在时返回 null。
Map<String, Object?>? readPerfBaseline(String baselinePath) {
  final file = File(baselinePath);
  if (!file.existsSync()) {
    return null;
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

String _sha256Of(List<int> bytes) {
  // 复用测试侧的 SHA-256 实现（Dart 标准库无此能力，且不引额外依赖）。
  // 见 test/support/sha256.dart。
  return sha256Hex(bytes);
}

/// **F-43**：基线元数据可比性校验项。
///
/// 负责人裁定（2026-10-16，F-43 / P2）：
/// 「校验基线元数据，并输出"历史值 / 本次值 / 差值或比例"；
///   **仍然不得把开发机耗时当作跨机器性能门槛**。」
///
/// 只有这些字段**全部一致**时，两次数值才可比 ——
/// 否则（换 seed、换内容版本、换场景时长、换帧预算）数值差异
/// 反映的是条件变化，而不是性能回归。
const List<String> kBaselineComparableFields = <String>[
  'seed',
  'contentVersion',
  'scenarioSeconds',
  'simulatedFrames',
  'frameBudgetMs',
];

/// 元数据比较结果。
class PerfBaselineComparison {
  const PerfBaselineComparison({
    required this.comparable,
    required this.mismatches,
    required this.lines,
  });

  /// 元数据是否全部一致（一致才可比较数值）。
  final bool comparable;

  /// 不一致的字段说明。
  final List<String> mismatches;

  /// 「历史值 / 本次值 / 差值 / 比例」逐项输出行。
  final List<String> lines;
}

/// 对比本次报告与只读基线：**先校验元数据，再逐项输出数值对照**。
///
/// **不抛断言失败** —— 按 F-43 要求，开发机耗时不是跨机器门槛；
/// 本函数的输出用于**验收记录与人工判读**。
PerfBaselineComparison comparePerfBaseline({
  required Map<String, Object?> current,
  required Map<String, Object?> baseline,
}) {
  final mismatches = <String>[];
  for (final field in kBaselineComparableFields) {
    final a = baseline[field];
    final b = current[field];
    if ('$a' != '$b') {
      mismatches.add('$field: 基线=$a，本次=$b');
    }
  }

  final lines = <String>[];
  void row(String label, Object? base, Object? now) {
    if (base is! num || now is! num) {
      return;
    }
    final delta = now - base;
    final ratio = base == 0 ? double.nan : now / base;
    final ratioText = ratio.isFinite ? '${ratio.toStringAsFixed(2)}×' : 'n/a';
    lines.add(
      '  ${label.padRight(18)} 历史 ${base.toStringAsFixed(3)}'
      '  本次 ${now.toStringAsFixed(3)}'
      '  差值 ${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(3)}'
      '  比例 $ratioText',
    );
  }

  final baseMs = (baseline['logicStepMs'] as Map?)?.cast<String, Object?>();
  final nowMs = (current['logicStepMs'] as Map?)?.cast<String, Object?>();
  for (final q in <String>['p50', 'p95', 'p99']) {
    row('logicStepMs.$q', baseMs?[q], nowMs?[q]);
  }

  final basePeaks =
      (baseline['objectPeaks'] as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{};
  final nowPeaks =
      (current['objectPeaks'] as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{};
  for (final key in basePeaks.keys) {
    row('objectPeaks.$key', basePeaks[key], nowPeaks[key]);
  }

  return PerfBaselineComparison(
    comparable: mismatches.isEmpty,
    mismatches: mismatches,
    lines: lines,
  );
}

/// 打印对照结果（信息性；**不作硬门槛**）。
void reportPerfComparison({
  required String label,
  required Map<String, Object?> current,
  required Map<String, Object?>? baseline,
}) {
  if (baseline == null) {
    stdout.writeln('[perf-compare] $label：无历史基线（跳过对照）');
    return;
  }
  final result = comparePerfBaseline(current: current, baseline: baseline);
  stdout.writeln('[perf-compare] $label');
  if (!result.comparable) {
    stdout.writeln('  ⚠️ 元数据不一致，数值**不可比**（条件已变）：');
    for (final m in result.mismatches) {
      stdout.writeln('    - $m');
    }
  } else {
    stdout.writeln('  元数据一致（seed/contentVersion/场景/帧预算）');
  }
  for (final line in result.lines) {
    stdout.writeln(line);
  }
  stdout.writeln('  （信息性对照 —— 开发机耗时不是跨机器性能门槛，F-43）');
}
