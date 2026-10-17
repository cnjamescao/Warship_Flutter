// ================================================================
// lib/game/presentation/v21_state_effects.dart —— v2.1 状态动效时序
//
// **架构位置**：Presentation 层。**纯数据 + 纯函数**的时序模型，
//   不含 Canvas、不含 Flutter Widget —— 因此可以**逐帧断言**，不必截图。
//
// **为什么单独成文件**：v2.1 的 5 类状态动效各有精确的帧间隔、
//   销毁/循环时长、blend、并发上限与 reduceMotion 规则（冻结表 §5.1）。
//   若把这些数字散落在绘制代码里，既无法测试也无法复核 ——
//   而**动效时序错位**恰恰是"看不出来但玩家能感觉到"的一类缺陷。
//
// **依据**：`Spec/01_产品/v2.1/Warship_v2.1功能冻结表.md` §5.1。
// ================================================================

import 'dart:ui' show BlendMode;

/// 一类状态动效的**精确时序规格**（冻结表 §5.1 逐字转写）。
class V21EffectSpec {
  const V21EffectSpec({
    required this.id,
    required this.assetId,
    required this.size,
    required this.frameCount,
    required this.frameOffsetsMs,
    required this.totalMs,
    required this.loop,
    required this.blendMode,
    required this.maxConcurrent,
    this.mergeWindowMs = 0,
    required this.reduceMotionHoldMs,
    this.reduceMotionFlashMs = 0,
    this.reduceMotionFlashPeriodMs = 0,
    required this.anchor,
  });

  final String id;
  final String assetId;

  /// 目标显示尺寸（logical px，正方形）。
  final double size;

  final int frameCount;

  /// 各帧的**起始毫秒**（长度必须等于 [frameCount]）。
  final List<int> frameOffsetsMs;

  /// 总时长：非循环为"销毁时刻"，循环为"一轮时长"。
  final int totalMs;

  /// 是否循环播放（低血 / 濒危为 true）。
  final bool loop;

  final BlendMode blendMode;

  /// **同屏并发上限**（冻结表 §5.1 的"最多 N"）。
  final int maxConcurrent;

  /// 命中类动效的**合并窗**（ms）；0 表示不合并。
  final int mergeWindowMs;

  /// `reduceMotion=true` 时保留的**峰值帧时长**（ms）。
  final int reduceMotionHoldMs;

  /// `reduceMotion=true` 时状态类动效的**闪现**时长与周期（ms）。
  /// 0 表示该动效在 reduceMotion 下不闪现（只保留峰值帧）。
  final int reduceMotionFlashMs;
  final int reduceMotionFlashPeriodMs;

  final List<double> anchor;

  /// **给定 t（ms）应显示第几帧**。
  ///
  /// 非循环：超过 [totalMs] 返回 -1（已销毁）。
  /// 循环：按 [totalMs] 取模。
  int frameAt(int elapsedMs) {
    if (elapsedMs < 0) {
      return -1;
    }
    var t = elapsedMs;
    if (loop) {
      t = elapsedMs % totalMs;
    } else if (elapsedMs >= totalMs) {
      return -1;
    }
    var index = 0;
    for (var i = 0; i < frameOffsetsMs.length; i++) {
      if (t >= frameOffsetsMs[i]) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  /// **reduceMotion=true 时**该动效是否正在显示（以及显示哪一帧）。
  ///
  /// 规则（冻结表 §5.1）：
  /// * 受击/击毁：保留**中间峰值帧** [reduceMotionHoldMs]；
  /// * 低血/濒危：保留**第一帧**，每 [reduceMotionFlashPeriodMs]
  ///   仅闪现 [reduceMotionFlashMs]。
  int reduceMotionFrameAt(int elapsedMs) {
    if (reduceMotionFlashPeriodMs > 0) {
      // 状态类：周期性闪现第一帧。
      if (elapsedMs < 0) {
        return -1;
      }
      final phase = elapsedMs % reduceMotionFlashPeriodMs;
      return phase < reduceMotionFlashMs ? 0 : -1;
    }
    return elapsedMs >= 0 && elapsedMs < reduceMotionHoldMs ? 1 : -1;
  }
}

/// **v2.1 五类状态动效的规格表**（冻结表 §5.1 逐字转写）。
///
/// ⚠️ 表里的每个数字都能在冻结表 §5.1 找到对应单元格；
/// **改动这些数字等于改产品口径**，需走变更流程。
const Map<String, V21EffectSpec> kV21StateEffects = <String, V21EffectSpec>{
  // Shield hit：4 帧，0/67/134/201ms，267ms 销毁，screen，最多 2。
  'shieldHit': V21EffectSpec(
    id: 'shieldHit',
    assetId: 'GFX-V21-PLAYER-SHIELD-HIT',
    size: 168,
    frameCount: 4,
    frameOffsetsMs: <int>[0, 67, 134, 201],
    totalMs: 267,
    loop: false,
    blendMode: BlendMode.screen,
    maxConcurrent: 2,
    reduceMotionHoldMs: 160,
    anchor: <double>[0.5, 0.5],
  ),
  // HP hit：3 帧，0/100/220ms，320ms 销毁，additive，80ms 合并，最多 2。
  'hpHit': V21EffectSpec(
    id: 'hpHit',
    assetId: 'GFX-V21-PLAYER-HP-HIT',
    size: 144,
    frameCount: 3,
    frameOffsetsMs: <int>[0, 100, 220],
    totalMs: 320,
    loop: false,
    blendMode: BlendMode.plus, // additive
    maxConcurrent: 2,
    mergeWindowMs: 80,
    reduceMotionHoldMs: 160,
    anchor: <double>[0.5, 0.5],
  ),
  // Low：3 帧，0/300/600ms，1200ms 循环，screen，仅 1。
  'low': V21EffectSpec(
    id: 'low',
    assetId: 'GFX-V21-PLAYER-LOW',
    size: 180,
    frameCount: 3,
    frameOffsetsMs: <int>[0, 300, 600],
    totalMs: 1200,
    loop: true,
    blendMode: BlendMode.screen,
    maxConcurrent: 1,
    reduceMotionHoldMs: 120,
    reduceMotionFlashMs: 120,
    reduceMotionFlashPeriodMs: 1200,
    anchor: <double>[0.5, 0.5],
  ),
  // Critical：3 帧，0/200/400ms，800ms 循环，additive，仅 1。
  'critical': V21EffectSpec(
    id: 'critical',
    assetId: 'GFX-V21-PLAYER-CRITICAL',
    size: 184,
    frameCount: 3,
    frameOffsetsMs: <int>[0, 200, 400],
    totalMs: 800,
    loop: true,
    blendMode: BlendMode.plus,
    maxConcurrent: 1,
    reduceMotionHoldMs: 120,
    reduceMotionFlashMs: 120,
    reduceMotionFlashPeriodMs: 800,
    anchor: <double>[0.5, 0.5],
  ),
  // Enemy destroy：3 帧，0/140/280ms，420ms 销毁，additive，最多 12。
  'enemyDestroy': V21EffectSpec(
    id: 'enemyDestroy',
    assetId: 'GFX-V21-ENEMY-DESTROY',
    size: 0, // 尺寸按敌人半径动态计算（clamp(radius×4.2, 90, 216)）
    frameCount: 3,
    frameOffsetsMs: <int>[0, 140, 280],
    totalMs: 420,
    loop: false,
    blendMode: BlendMode.plus,
    maxConcurrent: 12,
    reduceMotionHoldMs: 160,
    anchor: <double>[0.5, 0.5],
  ),
};

/// 敌人击毁动效的尺寸规则（冻结表 §5.1）：
/// `clamp(entityRadius × 4.2, 90, 216)`。
double enemyDestroySize(double entityRadius) =>
    (entityRadius * 4.2).clamp(90, 216);
