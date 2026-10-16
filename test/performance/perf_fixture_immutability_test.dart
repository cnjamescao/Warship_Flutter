// ================================================================
// test/performance/perf_fixture_immutability_test.dart —— F-42 守卫（第 4 条）
// ================================================================
// 负责人裁定（2026-10-16，F-42 / P1）第 4 条：
//   「增加回归测试：正常测试前后比较 fixture 的 SHA-256，发生变化即失败。」
//
// **背景**：修复前 `logic_budget_test.dart` / `object_cap_stress_test.dart`
// 会 `writeAsStringSync` 改写这两个 fixture，导致：
//   1. 每次跑测试都弄脏工作区（可能误提交当机测量值）；
//   2. 测试"先写后读同一文件"的断言**恒为真**，测不出任何回归。
//
// 本文件把 fixture 的**内容哈希钉死**：任何改写（无论来自测试、CI 还是
// 误操作）都会让本用例失败并给出修法。
//
// ⚠️ **顺序说明（如实记录局限）**：Flutter 测试分文件独立进程运行，
// 因此本守卫**无法**在同一进程内做到"跑完那两项测试后立即比较"。
// 它实际提供的是"**下一次运行时**发现 fixture 已被改动" ——
// 配合已落地的根因修复（那两项测试不再写 fixture），足以阻止误提交。
// 真正的事前拦截由**不写 fixture**本身保证。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/sha256.dart';

/// 已提交基线的**权威 SHA-256**（重建基线时按 F-42 第 3 条同步更新）。
const Map<String, String> kExpectedFixtureSha256 = <String, String>{
  'logic_budget_v1.json':
      '45ee72fdca6660847cc89703c8c8438d4a90d5166892a93f1823170ca30dfbfc',
  'object_cap_stress_v1.json':
      '7b5d4935492a327b69817d736c4f32b29e88a51004b9d843fb003d0c17a2c70b',
};

void main() {
  test('F-42 性能 fixture 必须只读：内容哈希不得被测试改写', () {
    final mismatched = <String>[];
    final missing = <String>[];

    for (final entry in kExpectedFixtureSha256.entries) {
      final file = File('test/fixtures/performance/${entry.key}');
      if (!file.existsSync()) {
        missing.add(entry.key);
        continue;
      }
      final actual = sha256Hex(file.readAsBytesSync());
      if (actual != entry.value) {
        mismatched.add(
          '${entry.key}\n    期望 ${entry.value}\n    实际 $actual',
        );
      }
    }

    expect(
      missing,
      isEmpty,
      reason: '基线 fixture 缺失：$missing',
    );
    expect(
      mismatched,
      isEmpty,
      reason: '以下性能 fixture 的内容**被改写了** —— 按 F-42 裁定，\n'
          '`test/fixtures/performance/*.json` 是**只读、受版本控制的基线输入**，\n'
          '正常测试与 CI **禁止改写**：\n${mismatched.join("\n")}\n\n'
          '若确需重建基线，必须走**显式维护流程**：\n'
          '  UPDATE_PERF_BASELINE=1 flutter test test/performance/\n'
          '并按裁定第 3 条记录环境、原因与前后差异，\n'
          '然后同步更新本文件中的 kExpectedFixtureSha256。',
    );
  });
}
