// ================================================================
// test/architecture/platform_isolation_test.dart —— W1 守卫（WEB-T-01）
// ================================================================
// **架构位置**：架构守卫。锁定 **共享层不得直接依赖 `dart:io`**。
//
// **依据**（技术设计 §平台隔离）：
//   「把 `dart:io` 诊断/基准输出迁入**条件导出适配器**；
//     共享表现层**只依赖抽象接口**。」
//
// **为什么这条必须自动化**：Web 是**正式端**，而 `dart:io` 在 Web 上
// **编译期就不可用** ✗。一旦有人（包括我）在表现层写回
// `import 'dart:io'`，Web 构建会**整体失败** —— 而且往往是
// 在打包阶段才发现 ✗。这条守卫把它提前到单元测试。
//
// **豁免**：`infrastructure/diagnostics/diagnostics_sink_io.dart`
// 是**端口的 IO 实现**，按设计**必须**用 `dart:io` ✓（它只在
// 有 io 的平台被条件导出选中）。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许直接使用 `dart:io` 的**唯一**文件（条件导出端口的 IO 实现）。
const Set<String> kAllowedIoFiles = <String>{
  'lib/game/infrastructure/diagnostics/diagnostics_sink_io.dart',
};

/// 参与"不得用 io"检查的**共享层**目录。
///
/// `lib/game/presentation/`（表现层）与 `lib/game/domain/`（规则层）
/// 是两端共用的核心 —— 它们必须平台无关 ✗。
const List<String> kSharedLayerDirs = <String>[
  'lib/game/presentation',
  'lib/game/domain',
  'lib/game/core',
];

void main() {
  test('W1-a 共享层（presentation/domain/core）**不得** import dart:io', () {
    final offenders = <String>[];
    for (final dir in kSharedLayerDirs) {
      final d = Directory(dir);
      if (!d.existsSync()) {
        continue;
      }
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) {
          continue;
        }
        final src = f.readAsStringSync();
        // 只看**真的 import**，不看注释里提到（注释里说"不用 dart:io"是允许的 ✓）。
        final importsIo = RegExp(
          r'''^\s*import\s+['"]dart:io['"]''',
          multiLine: true,
        ).hasMatch(src);
        if (importsIo) {
          offenders.add(f.path);
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '以下共享层文件直接依赖 dart:io —— Web 构建会失败 ✗：\n'
          '${offenders.join("\n")}\n'
          '请改为依赖条件导出端口（见 diagnostics/diagnostics_sink.dart）。',
    );
  });

  test('W1-b 唯一允许用 io 的实现文件**必须存在且有条件导出守护**', () {
    for (final allowed in kAllowedIoFiles) {
      expect(File(allowed).existsSync(), isTrue,
          reason: '$allowed 应存在（端口的 IO 实现）');
    }
    // 端口本体必须用条件导出，否则"编译期裁剪"不成立。
    final port = File(
      'lib/game/infrastructure/diagnostics/diagnostics_sink.dart',
    ).readAsStringSync();
    expect(
      port.contains("dart.library.io"),
      isTrue,
      reason: '必须用 `if (dart.library.io)` 条件导出，'
          '这样 Web 产物里**根本不会**出现 io 引用',
    );
    expect(
      RegExp(r'''^\s*import\s+['"]dart:io['"]''', multiLine: true)
          .hasMatch(port),
      isFalse,
      reason: '端口本体**不得** import dart:io（它必须平台无关）',
    );
  });

  test('W1-c 端口有两个实现（io + stub）', () {
    for (final f in <String>[
      'lib/game/infrastructure/diagnostics/diagnostics_sink_io.dart',
      'lib/game/infrastructure/diagnostics/diagnostics_sink_stub.dart',
    ]) {
      expect(File(f).existsSync(), isTrue, reason: '$f 缺失');
    }
    // stub 不得 import io。
    final stub = File(
      'lib/game/infrastructure/diagnostics/diagnostics_sink_stub.dart',
    ).readAsStringSync();
    expect(
      RegExp(r'''^\s*import\s+['"]dart:io['"]''', multiLine: true)
          .hasMatch(stub),
      isFalse,
      reason: 'Web 的 stub 实现**不得**依赖 dart:io',
    );
  });
}
