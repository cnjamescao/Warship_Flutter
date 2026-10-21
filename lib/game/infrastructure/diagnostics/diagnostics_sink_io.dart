// ================================================================
// lib/game/infrastructure/diagnostics/diagnostics_sink_io.dart —— 桌面实现
// **架构位置**：Infrastructure 层（端口的 **IO** 实现）。
//
// **关键约束**：
//   * 本文件**允许** import `dart:io` —— 它只在有 `dart.library.io`
//     的平台被条件导出选中 ✓；
//   * 写失败**必须静默**（架构 §7：诊断不能拖垮游戏）；
//   * 落盘位置沿用 v2.0 的约定（`$HOME/Documents/warship_assets.log`），
//     保证既有排查流程不变 ✓。
// ================================================================
// ================================================================

import 'dart:io';

import 'diagnostics_sink.dart';

/// 诊断日志文件名（与 v2.0 一致，避免排查流程断档）。
const String kDiagnosticsFileName = 'warship_assets.log';

DiagnosticsSink createPlatformSink() => const _IoSink();

class _IoSink implements DiagnosticsSink {
  const _IoSink();

  @override
  bool get canPersist => Platform.environment['HOME'] != null;

  @override
  void append(String content) {
    final home = Platform.environment['HOME'];
    if (home == null) {
      return;
    }
    try {
      final dir = Directory('$home/Documents');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      File('${dir.path}/$kDiagnosticsFileName').writeAsStringSync(
        content,
        mode: FileMode.append,
      );
    } catch (_) {
      // 诊断失败静默继续（架构 §7）。
    }
  }
}
