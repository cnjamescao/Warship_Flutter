// ================================================================
// lib/game/presentation/v21_result_medal.dart —— v2.1 奖章入场与 Toast 几何
//
// **架构位置**：Presentation 层。**纯数据 + 纯函数**，不依赖 Canvas。
//
// **为什么做成纯模型**：奖章入场是"时间轴动画"（分段插值 + 旋转 +
//   透明度），Toast 是"固定几何 + 窄屏夹紧"。两者都是**可计算的数值性质**，
//   用截图只能验"某一瞬间像不像"，验不了"180ms 处的 scale 是不是 1.12"。
//
// **依据**：`Spec/01_产品/v2.1/Warship_v2.1功能冻结表.md` §5.2（奖章）
//   与 §2.3（Toast 位置）。
// ================================================================

import 'dart:math' as math;

import 'dart:ui' show Rect;

/// 奖章入场的**某一瞬间**的变换状态。
class MedalFrame {
  const MedalFrame({
    required this.scale,
    required this.rotationDegrees,
    required this.opacity,
    required this.offsetY,
    required this.starOpacity,
  });

  final double scale;
  final double rotationDegrees;
  final double opacity;

  /// 相对锚点的纵向偏移（Bronze 的"y +32→0"用）。
  final double offsetY;

  /// 星芒（Gold 180–500ms 的 opacity 0→1）。
  final double starOpacity;

  @override
  String toString() =>
      'MedalFrame(scale=$scale, rot=$rotationDegrees, opacity=$opacity, '
      'y=$offsetY, star=$starOpacity)';
}

/// 一档奖章的入场时间轴规格（冻结表 §5.2 逐字转写）。
class MedalTimeline {
  const MedalTimeline({
    required this.tier,
    required this.assetId,
    required this.cueId,
    required this.segments,
    required this.totalMs,
    required this.usesAdditive,
  });

  final String tier;
  final String assetId;
  final String cueId;
  final List<MedalSegment> segments;

  /// 入场结束的时刻（之后停在最终帧）。
  final int totalMs;

  /// **必须为 false** —— 冻结表 §5.2：「三者**普通 alpha 合成**，
  /// **不可用 additive 覆盖结果文字**」。
  final bool usesAdditive;

  /// 计算 `elapsedMs` 时的变换状态（超过总时长则停在最终帧）。
  MedalFrame at(int elapsedMs) {
    final t = math.max(0, elapsedMs);
    var scale = segments.isEmpty ? 1.0 : segments.last.toScale;
    var rotation = segments.isEmpty ? 0.0 : segments.last.toRotation;
    var opacity = segments.isEmpty ? 1.0 : segments.last.toOpacity;
    var offsetY = segments.isEmpty ? 0.0 : segments.last.toOffsetY;
    var star = segments.isEmpty ? 1.0 : segments.last.toStarOpacity;

    for (final seg in segments) {
      if (t >= seg.endMs) {
        scale = seg.toScale;
        rotation = seg.toRotation;
        opacity = seg.toOpacity;
        offsetY = seg.toOffsetY;
        star = seg.toStarOpacity;
        continue;
      }
      if (t <= seg.startMs) {
        // 还没进入该段：保持该段的起始值。
        scale = seg.fromScale;
        rotation = seg.fromRotation;
        opacity = seg.fromOpacity;
        offsetY = seg.fromOffsetY;
        star = seg.fromStarOpacity;
        break;
      }
      // 段内线性插值。
      final span = (seg.endMs - seg.startMs).toDouble();
      final k = span <= 0 ? 1.0 : ((t - seg.startMs) / span).clamp(0.0, 1.0);
      double lerp(double a, double b) => a + (b - a) * k;
      scale = lerp(seg.fromScale, seg.toScale);
      rotation = lerp(seg.fromRotation, seg.toRotation);
      opacity = lerp(seg.fromOpacity, seg.toOpacity);
      offsetY = lerp(seg.fromOffsetY, seg.toOffsetY);
      star = lerp(seg.fromStarOpacity, seg.toStarOpacity);
      break;
    }
    return MedalFrame(
      scale: scale,
      rotationDegrees: rotation,
      opacity: opacity,
      offsetY: offsetY,
      starOpacity: star,
    );
  }
}

/// 时间轴的一段（闭开区间 `[startMs, endMs)`，端点为右值时取 `endMs`）。
class MedalSegment {
  const MedalSegment({
    required this.startMs,
    required this.endMs,
    this.fromScale = 1,
    this.toScale = 1,
    this.fromRotation = 0,
    this.toRotation = 0,
    this.fromOpacity = 1,
    this.toOpacity = 1,
    this.fromOffsetY = 0,
    this.toOffsetY = 0,
    this.fromStarOpacity = 0,
    this.toStarOpacity = 0,
  });

  final int startMs;
  final int endMs;
  final double fromScale;
  final double toScale;
  final double fromRotation;
  final double toRotation;
  final double fromOpacity;
  final double toOpacity;
  final double fromOffsetY;
  final double toOffsetY;
  final double fromStarOpacity;
  final double toStarOpacity;
}

/// **三档奖章的入场时间轴**（冻结表 §5.2 逐字转写）。
///
/// 目标尺寸统一为 **192×192 logical px**，锚点为结果卡中心。
const Map<String, MedalTimeline> kV21MedalTimelines = <String, MedalTimeline>{
  // Gold：0–180ms scale 0.60→1.12、rotation -10°→0°；
  //       180–500ms scale 1.12→1.00，星芒 opacity 0→1。
  'gold': MedalTimeline(
    tier: 'gold',
    assetId: 'UI-V21-RESULT-MEDAL-GOLD',
    cueId: 'SFX-V21-MEDAL-GOLD',
    segments: <MedalSegment>[
      MedalSegment(
        startMs: 0, endMs: 180,
        fromScale: 0.60, toScale: 1.12,
        fromRotation: -10, toRotation: 0,
      ),
      MedalSegment(
        startMs: 180, endMs: 500,
        fromScale: 1.12, toScale: 1.00,
        fromStarOpacity: 0, toStarOpacity: 1,
      ),
    ],
    totalMs: 500,
    usesAdditive: false,
  ),
  // Silver：0–160ms xScale 0.15→1.05；160–420ms xScale 1.05→1.00、opacity 0.75→1。
  'silver': MedalTimeline(
    tier: 'silver',
    assetId: 'UI-V21-RESULT-MEDAL-SILVER',
    cueId: 'SFX-V21-MEDAL-SILVER',
    segments: <MedalSegment>[
      MedalSegment(
        startMs: 0, endMs: 160,
        fromScale: 0.15, toScale: 1.05,
      ),
      MedalSegment(
        startMs: 160, endMs: 420,
        fromScale: 1.05, toScale: 1.00,
        fromOpacity: 0.75, toOpacity: 1,
      ),
    ],
    totalMs: 420,
    usesAdditive: false,
  ),
  // Bronze：0–180ms y +32→0、scale 0.75→1.05；180–380ms scale 1.05→1.00。
  'bronze': MedalTimeline(
    tier: 'bronze',
    assetId: 'UI-V21-RESULT-MEDAL-BRONZE',
    cueId: 'SFX-V21-MEDAL-BRONZE',
    segments: <MedalSegment>[
      MedalSegment(
        startMs: 0, endMs: 180,
        fromScale: 0.75, toScale: 1.05,
        fromOffsetY: 32, toOffsetY: 0,
      ),
      MedalSegment(
        startMs: 180, endMs: 380,
        fromScale: 1.05, toScale: 1.00,
      ),
    ],
    totalMs: 380,
    usesAdditive: false,
  ),
};

/// 奖章的**目标尺寸**（logical px，正方形）。
const double kV21MedalSize = 192;

// ---------------------------------------------------------------
// Toast 几何（冻结表 §2.3）
// ---------------------------------------------------------------

/// 设计基准画布（冻结表 §2.3 的坐标都以它为基准）。
const double kToastDesignWidth = 1920;
const double kToastDesignHeight = 1080;

/// 设计基准下的 Toast 矩形：`left=1540, top=104, 332×76`。
const Rect kToastDesignRect = Rect.fromLTWH(1540, 104, 332, 76);

/// **窄屏时的最小边距**（冻结表 §2.3：「距右/上边至少 24 logical px」）。
const double kToastMinEdgeMargin = 24;

/// 计算给定视口下的 Toast 矩形。
///
/// 规则（冻结表 §2.3）：
/// * 设计基准 `1920×1080` 下**原样**使用 `left=1540, top=104, 332×76`；
/// * **小于该宽度的视口按等比缩放**，且距**右/上边至少 24 logical px**。
///
/// 实现要点：缩放系数按"能塞进可用宽度"算 ——
/// 可用宽度 = 视口宽 − 右边距 − 左边距保护。
Rect toastRectFor(double viewportWidth, double viewportHeight) {
  final scale = viewportWidth < kToastDesignWidth
      ? (viewportWidth - kToastMinEdgeMargin * 2) / kToastDesignRect.width
      : 1.0;
  final s = scale.clamp(0.0, 1.0);
  final w = kToastDesignRect.width * s;
  final h = kToastDesignRect.height * s;
  // 右锚定：距右边 24；顶锚定：距顶 24（窄屏时保证不小于 24）。
  final right = kToastDesignWidth - kToastDesignRect.right;
  final left = viewportWidth - right * s - w;
  final top = kToastDesignRect.top * s;
  return Rect.fromLTWH(
    math.max(kToastMinEdgeMargin, left),
    math.max(kToastMinEdgeMargin, top),
    w,
    h,
  );
}
