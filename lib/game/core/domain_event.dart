// ================================================================
// lib/game/core/domain_event.dart —— 领域事件基类与 Core 事件
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §3
//   「事件必须不可变、有 runId、frameIndex、递增 eventIndex。」
//   「同一帧排序以系统顺序再以实体 ID 排序，确保回放一致。」
//
// 工作包纪律（03_实施工作包与交付标准.md §3）：
//   「任何新 DomainEvent 必须同时提交：事件定义、至少一个生产者、
//     至少一个表现/测试消费者。」
// 因此本文件只声明**已经在 Core 内有生产者与消费者**的事件；
// 战斗事件随对应系统（WP-03 起）逐个加入。
// ================================================================

/// 领域事件负载。
///
/// 只包含业务字段；`runId` / `frameIndex` / `eventIndex` 由 [EventBus] 盖章，
/// 生产者不需要（也不应该）自己维护这些元数据。
abstract class DomainEvent {
  const DomainEvent();

  /// 稳定的事件类型名，用于调试面板、回放比较与测试断言。
  ///
  /// 与协议 §3 表格中的事件名一致，不得随意改名。
  String get eventType;
}

/// 相位迁移完成。
///
/// 生产者：`PhaseController`。消费者：调试面板、生命周期测试。
class PhaseChanged extends DomainEvent {
  const PhaseChanged({required this.from, required this.to, required this.reason});

  final String from;
  final String to;
  final String reason;

  @override
  String get eventType => 'PhaseChanged';

  @override
  String toString() => 'PhaseChanged($from -> $to, $reason)';
}

/// 一局开始（Briefing 结束、进入 Playing 的那一刻）。
///
/// 生产者：`PhaseController`。消费者：回放记录、调试、测试。
class RunStarted extends DomainEvent {
  const RunStarted({
    required this.seed,
    required this.prngAlgorithm,
    required this.contentVersion,
  });

  final int seed;
  final String prngAlgorithm;
  final String contentVersion;

  @override
  String get eventType => 'RunStarted';

  @override
  String toString() =>
      'RunStarted(seed=$seed, prng=$prngAlgorithm, content=$contentVersion)';
}

/// 一局结束。
///
/// 生产者：`PhaseController`（进入 Result）。
/// 消费者：结算界面、本地记录、回放校验。
class RunEnded extends DomainEvent {
  const RunEnded({
    required this.result,
    required this.durationSeconds,
    required this.score,
    required this.seed,
    required this.bossHpRatio,
    required this.resultTier,
  });

  /// `victory` 或 `defeat`。
  final String result;
  final double durationSeconds;
  final int score;
  final int seed;
  final double bossHpRatio;

  /// 结算奖牌：`gold` / `silver` / `bronze` / `none`。
  ///
  /// 算法由协议 §3.1 固定：胜利 gold；失败但曾进入 Boss P3（bossHpRatio < 0.35）
  /// silver；失败且存活 ≥120 s bronze；其余 none。优先级 gold > silver > bronze > none。
  final String resultTier;

  @override
  String get eventType => 'RunEnded';
}
