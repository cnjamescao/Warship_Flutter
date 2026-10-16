// ================================================================
// lib/game/infrastructure/performance_report.dart —— 性能采样报告
//
// **架构位置**：Infrastructure（平台与 IO 适配） —— 把平台能力（音频/触觉/存档/性能）包成**可替换的端口**，便于测试注入替身。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：在假异步测试环境中须可注入替身 · 失败不得影响规则 · 平台不支持时静默 no-op。
// ================================================================
// 依据：Spec/02_技术/v2.0/04_测试计划与验收用例.md §5
//   「发布验收记录模板 … 性能 | 场景 seed、对象峰值、
//     p50/p95/p99 帧时间、降级是否发生」
//
// ⚠️ **范围声明（重要）**：
//   本模块产出的是**逻辑步成本**报告，不是帧时间报告。
//   无头测试无法测量 GPU 绘制、合成与垂直同步 —— 那些只能在
//   profile/release 构建的真实设备上采样。
//
//   因此：
//     * `logicStepMs` 回答"模拟本身是否吃得下 16.67 ms 预算"；
//     * AC-07 要求的**帧时间** p50/p95/p99 仍必须在真机上测。
//   报告里把两者分开写，避免把逻辑成本误当成帧时间。
// ================================================================

import 'dart:convert';

/// 一次性能采样的结果。
class PerformanceReport {
  const PerformanceReport({
    required this.seed,
    required this.contentVersion,
    required this.scenarioSeconds,
    required this.simulatedFrames,
    required this.logicP50Ms,
    required this.logicP95Ms,
    required this.logicP99Ms,
    required this.peakEnemies,
    required this.peakEnemyProjectiles,
    required this.peakPlayerProjectiles,
    required this.peakHazards,
    required this.degradationLevel,
    this.frameBudgetMs = 16.67,
    this.note,
  });

  final int seed;
  final String contentVersion;

  /// 场景覆盖的有效战斗时长。
  final double scenarioSeconds;

  /// 实际推进的逻辑帧数。
  final int simulatedFrames;

  /// **逻辑步**耗时（毫秒）—— 不是帧时间。
  final double logicP50Ms;
  final double logicP95Ms;
  final double logicP99Ms;

  final int peakEnemies;
  final int peakEnemyProjectiles;
  final int peakPlayerProjectiles;
  final int peakHazards;

  /// 采样期间是否发生了视觉降级。
  final String degradationLevel;

  /// 60 FPS 的帧预算。
  final double frameBudgetMs;

  final String? note;

  /// 逻辑成本占帧预算的比例（p95）。
  double get logicBudgetUsage => logicP95Ms / frameBudgetMs;

  /// 逻辑侧是否守住预算。**这不等于 AC-07 通过** ——
  /// AC-07 要求的是帧时间，必须真机采样。
  bool get logicMeetsBudget => logicP95Ms < frameBudgetMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'seed': seed,
    'contentVersion': contentVersion,
    'scenarioSeconds': scenarioSeconds,
    'simulatedFrames': simulatedFrames,
    'logicStepMs': <String, double>{
      'p50': logicP50Ms,
      'p95': logicP95Ms,
      'p99': logicP99Ms,
    },
    'objectPeaks': <String, int>{
      'enemies': peakEnemies,
      'enemyProjectiles': peakEnemyProjectiles,
      'playerProjectiles': peakPlayerProjectiles,
      'hazards': peakHazards,
    },
    'degradationLevel': degradationLevel,
    'frameBudgetMs': frameBudgetMs,
    'logicBudgetUsageP95': double.parse(logicBudgetUsage.toStringAsFixed(4)),
    'logicMeetsBudget': logicMeetsBudget,
    'scope':
        'logic-step cost only; AC-07 frame-time sampling still requires '
        'profile/release builds on real devices',
    if (note != null) 'note': note,
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 人类可读的一行摘要（便于贴进验收记录）。
  String summaryLine() =>
      'seed=$seed ${scenarioSeconds.toStringAsFixed(0)}s '
      'logic p50=${logicP50Ms.toStringAsFixed(3)}ms '
      'p95=${logicP95Ms.toStringAsFixed(3)}ms '
      'p99=${logicP99Ms.toStringAsFixed(3)}ms '
      '(${(logicBudgetUsage * 100).toStringAsFixed(1)}% of frame budget) '
      'peaks enemies=$peakEnemies enemyProj=$peakEnemyProjectiles '
      'playerProj=$peakPlayerProjectiles hazards=$peakHazards '
      'degradation=$degradationLevel';
}

/// 从一组逻辑步耗时构造报告。
PerformanceReport buildReport({
  required int seed,
  required String contentVersion,
  required double scenarioSeconds,
  required List<double> stepDurationsMs,
  required int peakEnemies,
  required int peakEnemyProjectiles,
  required int peakPlayerProjectiles,
  required int peakHazards,
  required String degradationLevel,
  String? note,
}) {
  final sorted = List<double>.from(stepDurationsMs)..sort();
  double at(double fraction) {
    if (sorted.isEmpty) {
      return 0;
    }
    final index = ((sorted.length - 1) * fraction).round();
    return sorted[index.clamp(0, sorted.length - 1)];
  }

  return PerformanceReport(
    seed: seed,
    contentVersion: contentVersion,
    scenarioSeconds: scenarioSeconds,
    simulatedFrames: sorted.length,
    logicP50Ms: at(0.50),
    logicP95Ms: at(0.95),
    logicP99Ms: at(0.99),
    peakEnemies: peakEnemies,
    peakEnemyProjectiles: peakEnemyProjectiles,
    peakPlayerProjectiles: peakPlayerProjectiles,
    peakHazards: peakHazards,
    degradationLevel: degradationLevel,
    note: note,
  );
}
