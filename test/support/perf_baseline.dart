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
