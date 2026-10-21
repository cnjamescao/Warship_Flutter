// ================================================================
// lib/game/infrastructure/diagnostics/diagnostics_sink.dart —— 诊断输出端口
// **架构位置**：Infrastructure 层（端口）。**平台无关** —— 只有接口与
//   条件导出，本文件**不含任何 `dart:io`** ✓
//
// **为什么存在（W1 的核心要求）**：
//   技术设计 §平台隔离：「把 `dart:io` 诊断/基准输出迁入**条件导出适配器**；
//   共享表现层**只依赖抽象接口**」。
//
//   改之前：`warship_v2_game.dart`（表现层）直接
//   `import 'dart:io'` 并用 `Platform.environment` + `File` 写日志 ✗ ——
//   这会让 Web 端**在编译期就失败**（`dart:io` 在 Web 不可用 ✗），
//   而现在 Web 是**正式端**，这条路必须封住。
//
// **实现分工**：
//   * `diagnostics_sink_io.dart`   → 桌面（真写文件）；
//   * `diagnostics_sink_stub.dart` → Web（**静默丢弃**，不假装写过）。
// ================================================================
// ================================================================

import 'diagnostics_sink_stub.dart'
    if (dart.library.io) 'diagnostics_sink_io.dart';

/// 诊断输出的**能力接口**（表现层只依赖它）。
abstract interface class DiagnosticsSink {
  /// 是否真的能落盘（Web 恒为 false）。
  ///
  /// 调用方据此决定"要不要收集这些数据" —— 若不能落盘还去收集，
  /// 就是白白消耗帧预算 ✗。
  bool get canPersist;

  /// 追加一条诊断内容（**失败必须静默**：诊断不能拖垮游戏）。
  void append(String content);
}

/// 取得当前平台的实现（**唯一入口**）。
///
/// 用条件导出在**编译期**选择实现 —— 因此 Web 产物里**不会**包含
/// `dart:io` 的引用 ✓（这是 `if (dart.library.io)` 的意义：
/// 裁剪发生在编译期，不是运行期判断 ✗）。
DiagnosticsSink createDiagnosticsSink() => createPlatformSink();
