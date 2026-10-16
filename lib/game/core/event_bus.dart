// ================================================================
// lib/game/core/event_bus.dart —— 事件收集与盖章
//
// **架构位置**：Core（运行时骨架） —— 按固定顺序驱动 Domain、结算伤害与实体增删、产出**不可变快照**与事件。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：仅 `Playing` 推进逻辑 · 实体增删经待提交队列统一提交（避免遍历中改集合）· 快照不可变。
//
// **本文件是"Core 对外广播"的通道** —— 音频、触觉、表现层都只是消费者。
//
// **要点与易错点**：
//   * **事件是"一帧内的瞬时数据"，不是状态**：
//     总线内**最多保留最近 256 条**（供调试与回放）。**需要历史请写入
//     recorder** —— 不要指望从总线里翻出几百帧前的事件。
//   * **消费语义是"取出并转交"**：`GameRuntime` 每帧 `drain()` 一次，
//     把本帧事件交给音频/触觉，并保留给表现层读取。
//     **不要在别处再 drain** —— 那会吞掉别人还没读到的事件。
//   * **消费者不得反向修改 Domain**（架构 §7）：
//     音频/触觉/表现只能读事件，不能凭事件改规则状态。
//   * **事件携带的阈值字段是"结算后"的值**（`*After` / `*Ratio`）——
//     判断档位请用这些，不要用结算前的值。
//   * **事件的发送顺序是有意义的**：同一帧内"先预警后发射"等时序
//     由 `GameRuntime` 保证，消费方不应重排序。
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §3
//   「事件必须不可变、有 runId、frameIndex、递增 eventIndex。」
//   「事件最多保留最近 256 条用于调试。」
//
// 设计要点：
//   * 生产者只构造不可变负载；
//   * 盖章（runId / frameIndex / eventIndex）由总线统一完成，
//     因此不存在"某个系统忘了填序号"导致回放不可比的可能；
//   * 总线按步驱动：每个逻辑步开始时 [beginStep]，结束时 [drainStep]。
// ================================================================

import 'domain_event.dart';
import 'run_context.dart';

/// 已盖章的事件：负载 + 归属与序号。
class StampedEvent {
  const StampedEvent({
    required this.event,
    required this.runId,
    required this.frameIndex,
    required this.eventIndex,
  });

  final DomainEvent event;
  final String runId;
  final int frameIndex;
  final int eventIndex;

  String get eventType => event.eventType;

  @override
  String toString() =>
      '[$frameIndex#$eventIndex $eventType] ${event.toString()}';
}

/// 事件总线：收集本步产生的事件，并维护调试环形缓冲。
class EventBus {
  EventBus({this.debugCapacity = 256});

  /// 调试用的事件保留上限（协议 §3：最多保留最近 256 条）。
  final int debugCapacity;

  final List<StampedEvent> _pending = <StampedEvent>[];
  final List<StampedEvent> _debugRing = <StampedEvent>[];

  /// 尚未被消费的本步事件（只读视图）。
  List<StampedEvent> get pending => List<StampedEvent>.unmodifiable(_pending);

  /// 调试环形缓冲（最近 [debugCapacity] 条）。
  List<StampedEvent> get debugHistory => List<StampedEvent>.unmodifiable(_debugRing);

  /// 发出一个事件。由总线负责盖 runId / frameIndex / eventIndex。
  void emit(DomainEvent event, RunContext context) {
    final stamped = StampedEvent(
      event: event,
      runId: context.runId,
      frameIndex: context.frameIndex,
      eventIndex: context.consumeEventIndex(),
    );
    _pending.add(stamped);
    _debugRing.add(stamped);
    if (_debugRing.length > debugCapacity) {
      _debugRing.removeRange(0, _debugRing.length - debugCapacity);
    }
  }

  /// 取走本步的全部事件，交给表现层消费。
  List<StampedEvent> drain() {
    if (_pending.isEmpty) {
      return const <StampedEvent>[];
    }
    final drained = List<StampedEvent>.unmodifiable(_pending);
    _pending.clear();
    return drained;
  }

  /// 丢弃未消费的事件（新一局 / 释放时调用，防止旧事件泄漏到新局）。
  void clear() {
    _pending.clear();
    _debugRing.clear();
  }
}

/// 事件按类型过滤的便捷扩展，测试与表现层都用得到。
extension StampedEventListFilter on Iterable<StampedEvent> {
  /// 取出所有指定类型的负载。
  Iterable<T> ofType<T extends DomainEvent>() =>
      where((e) => e.event is T).map((e) => e.event as T);
}
