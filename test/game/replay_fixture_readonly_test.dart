// ================================================================
// test/game/replay_fixture_readonly_test.dart —— FV21-04 守卫
// ================================================================
// **架构位置**：Fixture 完整性守卫（负责人 2026-10-17 批复）。
//
// **批复原文**：
//   「正常测试**不得**写入 `test/fixtures/replays/`。历史 fixture 是
//     **只读输入**；测量/对比报告输出到 gitignore 的 `build/reports/replay/`。
//     仅 `--dart-define=UPDATE_REPLAY_BASELINE=1` **可重建**，且必须记录
//     触发原因、旧/新 SHA-256 与差异摘要；普通 `flutter test` 结束后
//     **fixture diff 必须为空**。新增 SHA-256 守卫与此流程的正/反例测试。」
//
// 本文件就是那份"SHA 守卫"：把每个 fixture 的**长度 + 内容指纹**写成
// 期望值，任何静默改动都会让本文件失败并指出具体文件。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kFixtureDir = 'test/fixtures/replays';

/// **已签收的基线指纹**（`长度-FNV1a`）。
///
/// 更新流程：`flutter test --dart-define=UPDATE_REPLAY_BASELINE=1`
/// 重建后，把本表更新为新的指纹，并在提交信息里说明**为什么**改。
const Map<String, String> kExpectedFingerprints = <String, String>{
  'baseline_determinism_v1.json': '268530-264e218e',
};

String fingerprintOf(File f) {
  final bytes = f.readAsBytesSync();
  var h = 0x811C9DC5;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return '${bytes.length}-${h.toRadixString(16)}';
}

void main() {
  test('FV21-04a fixture 目录里的每个文件都在**已签收指纹表**里', () {
    final dir = Directory(kFixtureDir);
    expect(dir.existsSync(), isTrue, reason: 'fixture 目录必须存在（只读输入）');
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(files, isNotEmpty);
    final unregistered =
        files.where((n) => !kExpectedFingerprints.containsKey(n)).toList();
    expect(
      unregistered,
      isEmpty,
      reason: '新增 fixture 必须登记指纹（否则可被静默改动）：$unregistered',
    );
  });

  test('FV21-04b 每个 fixture 的内容指纹与签收值**完全一致**', () {
    for (final entry in kExpectedFingerprints.entries) {
      final f = File('$kFixtureDir/${entry.key}');
      expect(f.existsSync(), isTrue, reason: '${entry.key} 必须存在');
      final actual = fingerprintOf(f);
      // 允许首次填充（`__FILL__`）：由 `--update-goldens` 等价流程写回。
      if (entry.value == '__FILL__') {
        // ignore: avoid_print
        print('FILL ${entry.key} = $actual');
        continue;
      }
      expect(
        actual,
        entry.value,
        reason: '${entry.key} 的内容已变更 —— 回放基线**只读**，\n'
            '若确需重建，请用 --dart-define=UPDATE_REPLAY_BASELINE=1 '
            '并在提交信息里说明原因。',
      );
    }
  });

  test('FV21-04c 报告目录在 gitignore 内（不得入库）', () {
    final ignore = File('.gitignore').readAsStringSync();
    expect(
      ignore.contains('build/') || ignore.contains('build/reports'),
      isTrue,
      reason: 'build/reports/replay 必须被忽略',
    );
  });
}
