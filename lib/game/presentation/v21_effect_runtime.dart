// ================================================================
// lib/game/presentation/v21_effect_runtime.dart —— v2.1 状态动效实例管理
//
// **架构位置**：Presentation 层。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**：
//   * **并发上限**与**合并窗**来自 `V21EffectSpec`，不得在调用方另行判断；
//   * `reduceMotion` 只改变**显示**，**不得**改变状态、碰撞、伤害或时钟；
//   * 已销毁的实例必须及时移除，否则长时间对局会累积成性能问题。
// ================================================================

import 'v21_state_effects.dart';

/// 一个**正在播放**的状态动效实例。
class V21EffectInstance {
  V21EffectInstance({
    required this.spec,
    required this.startedAtSeconds,
    required this.centerX,
    required this.centerY,
    required this.size,
  });

  final V21EffectSpec spec;

  /// 起始时刻（**逻辑时间**，秒）—— 用逻辑时间才能"暂停即冻结"。
  final double startedAtSeconds;

  final double centerX;
  final double centerY;

  /// 本次实例的显示尺寸（击毁动效按敌人半径动态算，其余用 spec.size）。
  final double size;

  /// 该实例在 [nowSeconds] 时应显示的帧号；-1 表示不该显示（已结束/闪现间隙）。
  int frameAt(double nowSeconds, {required bool reduceMotion}) {
    final elapsedMs = ((nowSeconds - startedAtSeconds) * 1000).round();
    return reduceMotion
        ? spec.reduceMotionFrameAt(elapsedMs)
        : spec.frameAt(elapsedMs);
  }

  /// 是否已彻底结束（可以移除）。
  bool isFinished(double nowSeconds, {required bool reduceMotion}) {
    final elapsedMs = ((nowSeconds - startedAtSeconds) * 1000).round();
    if (reduceMotion && spec.reduceMotionFlashPeriodMs > 0) {
      // 状态类动效在 reduceMotion 下长期存在（随状态本身），
      // 由状态的生灭而非时长决定去留 —— 因此这里不判结束。
      return false;
    }
    if (spec.loop) {
      return false; // 循环动效随状态生灭。
    }
    final limit =
        reduceMotion ? spec.reduceMotionHoldMs : spec.totalMs;
    return elapsedMs >= limit;
  }
}

/// **状态动效实例管理器**（v2.1 / 冻结表 §5.1）。
///
/// 职责只有三件：**按并发上限收编、按时间自然淘汰、按类型合批**。
/// 不含 Canvas、不含 Flutter —— 因此可以逐项断言。
class V21EffectRuntime {
  V21EffectRuntime();

  final List<V21EffectInstance> instances = <V21EffectInstance>[];

  /// 每种动效**最近一次生成**的逻辑时间（用于合并窗）。
  final Map<String, double> _lastSpawnAt = <String, double>{};

  /// 尝试生成一个动效实例。
  ///
  /// 返回 `true` 表示已收编；`false` 表示被**合并窗**或**并发上限**拒绝。
  /// 拒绝是**正确行为**（冻结表 §5.1 的"最多 N"与"80ms 合并"），
  /// 不是缺陷 —— 因此不抛错。
  bool spawn({
    required V21EffectSpec spec,
    required double nowSeconds,
    required double centerX,
    required double centerY,
    double? size,
  }) {
    // ① 合并窗：同一类动效在窗口内重复触发时**只保留第一个**。
    if (spec.mergeWindowMs > 0) {
      final last = _lastSpawnAt[spec.id];
      if (last != null &&
          (nowSeconds - last) * 1000 < spec.mergeWindowMs) {
        return false;
      }
    }
    // ② 并发上限：超出时**淘汰最旧的**（而不是拒绝新的）——
    //    新的一次受击比旧的那次更值得显示。
    final sameKind =
        instances.where((i) => i.spec.id == spec.id).toList();
    if (sameKind.length >= spec.maxConcurrent) {
      sameKind.sort(
        (a, b) => a.startedAtSeconds.compareTo(b.startedAtSeconds),
      );
      instances.remove(sameKind.first);
    }

    instances.add(
      V21EffectInstance(
        spec: spec,
        startedAtSeconds: nowSeconds,
        centerX: centerX,
        centerY: centerY,
        size: size ?? spec.size,
      ),
    );
    _lastSpawnAt[spec.id] = nowSeconds;
    return true;
  }

  /// 移除某一类的全部实例（状态离开时调用，如"不再低血"）。
  void removeKind(String kind) {
    instances.removeWhere((i) => i.spec.id == kind);
    _lastSpawnAt.remove(kind);
  }

  /// 确保某类**状态动效**存在（已有则不重复生成）。
  ///
  /// 与 [spawn] 的区别：`spawn` 用于**瞬时**动效（受击/击毁），
  /// 这里用于**持续状态**（低血/濒危）—— 状态还在就不该重建，
  /// 否则每次 `PlayerVitalStateChanged` 都会让动画从头开始。
  void ensurePersistent({
    required V21EffectSpec spec,
    required double nowSeconds,
    required double centerX,
    required double centerY,
  }) {
    for (final i in instances) {
      if (i.spec.id == spec.id) {
        return;
      }
    }
    instances.add(
      V21EffectInstance(
        spec: spec,
        startedAtSeconds: nowSeconds,
        centerX: centerX,
        centerY: centerY,
        size: spec.size,
      ),
    );
  }

  /// 移除已结束的实例（每帧调用一次）。
  void prune(double nowSeconds, {required bool reduceMotion}) {
    instances.removeWhere(
      (i) => i.isFinished(nowSeconds, reduceMotion: reduceMotion),
    );
  }

  /// 清空（重开一局时调用，避免残留 —— AC-03 要求）。
  void clear() {
    instances.clear();
    _lastSpawnAt.clear();
  }
}

