// ================================================================
// lib/game/infrastructure/diagnostics/diagnostics_sink_stub.dart —— Web 实现
// **架构位置**：Infrastructure 层（端口的 **Web** 实现）。
//
// **关键约束**：本文件**不得** import 任何 `dart:io` ✗ ——
//   它的存在就是为了让 Web 编译**根本看不到** io。
//
// **行为**：静默丢弃 + `canPersist == false`。
//   * 不写 localStorage（诊断是**开发期**产物，不该污染玩家存档 ✗）；
//   * 不抛异常（诊断不能拖垮游戏）；
//   * **不假装写过**（调用方通过 `canPersist` 就能知道）✓。
// ================================================================
// ================================================================

import 'diagnostics_sink.dart';

DiagnosticsSink createPlatformSink() => const _StubSink();

class _StubSink implements DiagnosticsSink {
  const _StubSink();

  @override
  bool get canPersist => false;

  @override
  void append(String content) {
    // Web：无处可写，也**不假装**写成功。
  }
}
