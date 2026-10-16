// ================================================================
// lib/game/core/game_clock.dart —— 固定逻辑步进时钟
//
// **架构位置**：Core（运行时骨架） —— 按固定顺序驱动 Domain、结算伤害与实体增删、产出**不可变快照**与事件。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：仅 `Playing` 推进逻辑 · 实体增删经待提交队列统一提交（避免遍历中改集合）· 快照不可变。
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §4
//   「渲染帧可变，逻辑必须固定为 1/60 s。渲染帧 dt 先 clamp 至 50 ms，
//     再累加到 accumulator；单个渲染帧最多执行 3 个逻辑步，
//     超出的 accumulator 丢弃并记录性能告警，防止后台回来后追算伤害。」
//
// 以及 §2.1 的 Clock 契约：「固定逻辑步；最大补偿 50 ms，禁止巨帧穿透。」
//
// 两条保护的分工（实现时容易混淆，这里写明）：
//   * **50 ms clamp 是第一道、也是实际生效的那道保护**：
//     因为 50 ms 恰好等于 3 个逻辑步，clamp 之后单帧步数天然不超过上限；
//   * **单帧步数上限是兜底**：即使将来调整 clamp 常量或步长，
//     也不会出现一帧内追算几十步的情况。
// 因此真正需要监控的性能指标是「有多少渲染帧的 dt 超过了 50 ms」
// （[clampedRenderFrameCount]），而不是被丢弃的步数。
// ================================================================

/// 固定步进时钟。
///
/// 它只回答一个问题：**这一渲染帧应该跑几个逻辑步**。
/// 它不持有相位，也不推进任何规则 —— 相位门禁由调用方负责。
class GameClock {
  /// 逻辑步长：1/60 秒。产品与协议均以此为唯一逻辑时间单位。
  static const double fixedStepSeconds = 1.0 / 60.0;

  /// 单个渲染帧允许进入累加器的最大 dt（50 ms）。
  ///
  /// 超出部分直接丢弃：否则从后台切回、断点调试或严重卡顿之后，
  /// 一帧内会追算大量逻辑步，出现"瞬移穿墙/多次伤害"。
  static const double maxRenderDeltaSeconds = 0.05;

  /// 单个渲染帧最多执行的逻辑步数。
  static const int maxStepsPerRenderFrame = 3;

  double _accumulator = 0;
  double _elapsedSeconds = 0;
  int _frameIndex = 0;
  int _clampedRenderFrameCount = 0;
  int _droppedStepCount = 0;

  /// 已经推进的逻辑帧号（从 0 开始）。
  int get frameIndex => _frameIndex;

  /// 已经累计的逻辑时间（秒）。仅统计真正的逻辑步。
  double get elapsedSeconds => _elapsedSeconds;

  /// 尚未消费的累加器余量（秒）。诊断用。
  double get pendingAccumulatorSeconds => _accumulator;

  /// dt 超过 50 ms 而被 clamp 的渲染帧数量。
  ///
  /// **这是真正需要关注的性能告警**：持续大于 0 说明帧时间预算已被突破，
  /// 玩家看到的是"时间被丢弃"（游戏变慢）而不是瞬移。
  int get clampedRenderFrameCount => _clampedRenderFrameCount;

  /// 因超过单帧步数上限而被丢弃的累加器步数（兜底路径）。
  ///
  /// 在当前 50 ms clamp 下通常恒为 0 —— 这是正确行为，不是缺陷。
  int get droppedStepCount => _droppedStepCount;

  /// 用一次渲染帧的 [renderDeltaSeconds] 推进时钟。
  ///
  /// 返回本帧应当执行的逻辑步数（0..[maxStepsPerRenderFrame]）。
  /// 调用方应使用 [advanceAndRun] 或自行按返回步数调用 [consumeStep]。
  int accumulate(double renderDeltaSeconds) {
    if (renderDeltaSeconds <= 0) {
      return 0;
    }

    // 1) 先 clamp 巨帧 —— 这是实际生效的那道保护。
    final clamped = renderDeltaSeconds > maxRenderDeltaSeconds
        ? maxRenderDeltaSeconds
        : renderDeltaSeconds;
    if (clamped != renderDeltaSeconds) {
      _clampedRenderFrameCount++;
    }

    // 2) 累加（含上一帧的余量）。
    _accumulator += clamped;

    // 3) 计算本次允许执行的步数。
    var steps = (_accumulator / fixedStepSeconds).floor();
    if (steps <= 0) {
      return 0;
    }
    if (steps > maxStepsPerRenderFrame) {
      // 兜底路径：丢弃超出部分并记录告警。
      _droppedStepCount += steps - maxStepsPerRenderFrame;
      steps = maxStepsPerRenderFrame;
      _accumulator = 0;
    } else {
      _accumulator -= steps * fixedStepSeconds;
    }
    return steps;
  }

  /// 消费一个逻辑步，推进帧号与逻辑时间。
  void consumeStep() {
    _frameIndex++;
    _elapsedSeconds += fixedStepSeconds;
  }

  /// 把「取步数 → 逐步推进」合并为一次调用。
  ///
  /// [step] 每个逻辑步执行一次；它接收该步的帧号（步内已推进后的值）。
  int advanceAndRun(
    double renderDeltaSeconds,
    void Function(int frameIndex) step,
  ) {
    final steps = accumulate(renderDeltaSeconds);
    for (var i = 0; i < steps; i++) {
      consumeStep();
      step(_frameIndex);
    }
    return steps;
  }

  /// 复位到开局状态（新一局调用）。
  void reset() {
    _accumulator = 0;
    _elapsedSeconds = 0;
    _frameIndex = 0;
    _clampedRenderFrameCount = 0;
    _droppedStepCount = 0;
  }
}
