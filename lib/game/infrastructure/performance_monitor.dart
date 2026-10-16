// ================================================================
// lib/game/infrastructure/performance_monitor.dart —— 帧时间与降级
//
// **架构位置**：Infrastructure（平台与 IO 适配） —— 把平台能力（音频/触觉/存档/性能）包成**可替换的端口**，便于测试注入替身。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：在假异步测试环境中须可注入替身 · 失败不得影响规则 · 平台不支持时静默 no-op。
// 本文件做运行期性能观测：
//   * 观测不得改变行为：采样不能影响规则结果（不得消耗随机源、不得改变步序）
//   * 降级必须只影响表现：逻辑步结果在任何降级档位下必须一致（有独立用例）
// ================================================================
// 依据：产品基线 §2（性能硬约束）
//   「60 FPS 目标；95% 帧 ≤20 ms、99% 帧 ≤33 ms」；
//   降级顺序：「星云 → 非关键粒子 → 命中碎片 → 伤害数字」；
//   **永不降级**：预警、HUD、碰撞、Boss 弱点。
//
// 架构 §2.1 的 infrastructure 职责：
//   「音频限频、存档、资源预载、平台失焦、**性能采样**」——
//   它不参与产品规则，因此这里只输出"建议的视觉档位"，
//   由表现层自己决定怎么画。
// ================================================================

import 'dart:math' as math;

/// 可降级的视觉层级，**顺序即降级顺序**。
///
/// 索引越大 = 越先被牺牲。枚举顺序就是产品基线 §2 的顺序，
/// 因此 `index` 可以直接当作等级比较。
enum DegradationLevel {
  /// 全效果。
  none,

  /// 关掉背景星云层（最外层视差）。
  nebula,

  /// 再关掉非关键粒子（环境飘尘、引擎尾迹粒子）。
  particles,

  /// 再关掉命中碎片。
  hitDebris,

  /// 最后关掉伤害数字。
  damageNumbers;

  /// 该层是否仍应绘制。
  ///
  /// 语义要点：`level` 表示**已经牺牲到哪一层**。
  /// 因此 `allows(x)` 用**严格大于**：索引比当前档位更靠内（更晚被牺牲）
  /// 的层才继续画。
  ///
  /// 例：`level = hitDebris` 时命中碎片**已经不画**，
  /// 但比它更内层的伤害数字仍然画。
  ///
  /// 参数应当是**可降级层**（`nebula` 起）；`none` 只是"未降级"的起点，
  /// 不参与比较。
  bool allows(DegradationLevel layer) => layer.index > index;
}

/// 帧时间采样与降级决策。
class PerformanceMonitor {
  PerformanceMonitor({
    this.windowSize = 120,
    this.targetFrameMs = 16.67,
    this.p95BudgetMs = 20.0,
    this.p99BudgetMs = 33.0,
    this.minSamplesBeforeDegrading = 30,
    this.upgradeHoldFrames = 180,
    this.degradeCooldownFrames = 30,
  }) : assert(windowSize > 0);

  /// 滑动窗口长度（帧）。120 帧≈2 秒，足够短以反映当下压力，
  /// 又足够长以避免单帧抖动触发降级。
  final int windowSize;

  final double targetFrameMs;

  /// 95% 帧必须 ≤ 该值。
  final double p95BudgetMs;

  /// 99% 帧必须 ≤ 该值。
  final double p99BudgetMs;

  /// 样本不足时不降级 —— 开局前几帧必然偏慢（资源解码）。
  final int minSamplesBeforeDegrading;

  /// 提升画质前需要连续达标的帧数（滞回，避免档位抖动）。
  final int upgradeHoldFrames;

  /// 两次降级之间的最小间隔帧数（默认 30 帧≈0.5 秒）。
  ///
  /// 没有这个冷却的话，一旦进入超预算状态就会**每帧降一档**，
  /// 一次 1 秒的卡顿会把画面直接削到最低档 —— 那不是"逐级降级"，
  /// 而是"一次抖动就全关"。产品基线只规定了降级的**顺序**，
  /// 没有规定速率，因此这里取一个保守的工程值。
  final int degradeCooldownFrames;

  final List<double> _samples = <double>[];

  DegradationLevel _level = DegradationLevel.none;
  int _goodFrameStreak = 0;
  int _framesSinceDegrade = 0;

  /// 累计帧数与其中超过 33 ms 的帧数（长稳测试用）。
  int totalFrames = 0;
  int overBudgetFrames = 0;

  DegradationLevel get level => _level;
  int get sampleCount => _samples.length;

  /// 记录一帧的耗时（秒）。
  void recordFrame(double dtSeconds) {
    final ms = dtSeconds * 1000;
    totalFrames++;
    if (ms > p99BudgetMs) {
      overBudgetFrames++;
    }
    _samples.add(ms);
    if (_samples.length > windowSize) {
      _samples.removeAt(0);
    }
    _updateLevel();
  }

  /// 分位数（毫秒）。样本不足时返回 0。
  double percentile(double fraction) {
    if (_samples.isEmpty) {
      return 0;
    }
    final sorted = List<double>.from(_samples)..sort();
    final index = ((sorted.length - 1) * fraction).round();
    return sorted[index.clamp(0, sorted.length - 1)];
  }

  double get p50 => percentile(0.50);
  double get p95 => percentile(0.95);
  double get p99 => percentile(0.99);

  double get mean =>
      _samples.isEmpty ? 0 : _samples.reduce((a, b) => a + b) / _samples.length;

  /// 当前窗口是否满足性能预算。
  bool get meetsBudget => p95 <= p95BudgetMs && p99 <= p99BudgetMs;

  /// 超预算帧占比。
  double get overBudgetRatio =>
      totalFrames == 0 ? 0 : overBudgetFrames / totalFrames;

  void _updateLevel() {
    if (_samples.length < minSamplesBeforeDegrading) {
      return;
    }

    if (!meetsBudget) {
      // 压力过大：降一级。逐级下降 + 冷却，免得一次卡顿就把画面削光。
      _goodFrameStreak = 0;
      _framesSinceDegrade++;
      if (_framesSinceDegrade < degradeCooldownFrames) {
        return;
      }
      if (_level != DegradationLevel.damageNumbers) {
        _level = DegradationLevel.values[_level.index + 1];
        _framesSinceDegrade = 0;
      }
      return;
    }

    _framesSinceDegrade = 0;

    // 已经达标：需要连续达标一段时间才恢复一档（滞回）。
    if (_level == DegradationLevel.none) {
      return;
    }
    if (p95 <= p95BudgetMs * 0.85) {
      _goodFrameStreak++;
      if (_goodFrameStreak >= upgradeHoldFrames) {
        _level = DegradationLevel.values[_level.index - 1];
        _goodFrameStreak = 0;
      }
    } else {
      _goodFrameStreak = 0;
    }
  }

  /// 诊断摘要（发布验收记录模板要求）。
  Map<String, Object?> summary() => <String, Object?>{
    'frames': totalFrames,
    'p50Ms': double.parse(p50.toStringAsFixed(2)),
    'p95Ms': double.parse(p95.toStringAsFixed(2)),
    'p99Ms': double.parse(p99.toStringAsFixed(2)),
    'overBudgetRatio': double.parse(overBudgetRatio.toStringAsFixed(4)),
    'degradationLevel': _level.name,
  };

  void reset() {
    _samples.clear();
    _level = DegradationLevel.none;
    _goodFrameStreak = 0;
    _framesSinceDegrade = 0;
    totalFrames = 0;
    overBudgetFrames = 0;
  }
}

/// 对象预算计数器。
///
/// 产品基线 §6：同屏敌人 45、敌方投射物 90、我方投射物 120、
/// 粒子 180、伤害数字 20。
class ObjectBudget {
  const ObjectBudget({
    this.enemies = 45,
    this.enemyProjectiles = 90,
    this.playerProjectiles = 120,
    this.particles = 180,
    this.damageNumbers = 20,
  });

  final int enemies;
  final int enemyProjectiles;
  final int playerProjectiles;
  final int particles;
  final int damageNumbers;

  /// 是否还能再分配一个该类对象。
  static bool canAllocate(int current, int cap) => current < cap;

  /// 超出预算时该拒绝谁：**低优先级特效先被拒绝**，
  /// 预警、HUD、碰撞与 Boss 弱点永不因预算被拒。
  static bool shouldRejectNonCritical(int current, int cap) => current >= cap;
}

/// 分帧采样器：以固定间隔记录，避免每帧都做排序。
class FrameTimer {
  FrameTimer({this.sampleEveryFrames = 10});

  final int sampleEveryFrames;
  int _counter = 0;
  final Stopwatch _stopwatch = Stopwatch();

  void start() {
    _stopwatch
      ..reset()
      ..start();
  }

  /// 结束本次测量；返回是否记录了一次样本。
  bool stop(PerformanceMonitor monitor) {
    _stopwatch.stop();
    _counter++;
    if (_counter % sampleEveryFrames != 0) {
      return false;
    }
    monitor.recordFrame(_stopwatch.elapsedMicroseconds / 1e6);
    return true;
  }

  /// 用已知的帧间隔直接记录（测试与固定步进环境用）。
  static double framesToMs(int frames, {double stepMs = 1000 / 60}) =>
      frames * stepMs;

  static int msToFrames(double ms, {double stepMs = 1000 / 60}) =>
      (ms / stepMs).round();

  static double maxOf(Iterable<double> values) =>
      values.isEmpty ? 0 : values.reduce(math.max);
}
