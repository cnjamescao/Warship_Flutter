// ================================================================
// lib/game/presentation/v21_result_notice.dart —— 结果徽记队列与时序（无文字）
//
// **架构位置**：Presentation 层。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**：
//   * **视觉层无文字**：徽记只有图形，说明文字只走无障碍语义；
//   * 单一队列按**产生顺序**逐个播放，**前项结束才显示后项**；
//   * 队列**不暂停战斗、不丢事件**（战斗逻辑与它完全解耦）；
//   * 位置/尺寸来自固定目标区 `1728,28,132,176`，**按源图纵横比 contain**。
//
// **依据**：`Spec/01_产品/v2.1/Warship_v2.1功能冻结表.md` §2.3。
// ================================================================

import 'dart:ui' show Rect;

/// 结果徽记的四种来源（对应四张真实素材）。
enum V21ResultKind {
  upgrade,   // 任意自动强化
  supply,    // RG-SUPPLY
  bounty,    // RG-BOUNTY
  overload,  // RG-OVERLOAD
}

extension V21ResultKindAsset on V21ResultKind {
  /// 该徽记的 Asset ID（四枚真实素材，见素材规范）。
  String get assetId => switch (this) {
    V21ResultKind.upgrade => 'UI-V21-AUTO-UPGRADE-EMBLEM',
    V21ResultKind.supply => 'UI-V21-RISK-SUPPLY-EMBLEM',
    V21ResultKind.bounty => 'UI-V21-RISK-BOUNTY-EMBLEM',
    V21ResultKind.overload => 'UI-V21-RISK-OVERLOAD-EMBLEM',
  };

  /// 无障碍语义标签的 catalog key。
  ///
  /// **只有这两个 key** —— 冻结表把它们固定为：
  /// `获得强化：{name}，等级 {level}，{description}` /
  /// `风险结果：{name}，{effect}`。
  String get ariaKey => this == V21ResultKind.upgrade
      ? 'toast.upgradeAria'
      : 'toast.riskAria';
}

/// 一条待显示的结果通知。
class V21ResultNotice {
  const V21ResultNotice({
    required this.kind,
    required this.args,
    required this.ordinal,
  });

  final V21ResultKind kind;

  /// 语义模板参数（强化：`name`/`level`/`description`；风险：`name`/`effect`）。
  ///
  /// ⚠️ 其中 `name`/`description` 等**存的是 catalog key**，
  /// 必须由调用方逐级解析后再套模板（否则会显示 key 原文 ✗）。
  final Map<String, Object?> args;

  /// 全局序号（与 `RiskGateResolution.resultNoticeOrdinal` 对账）。
  final int ordinal;
}

/// 徽记播放**时序**（冻结表 §2.3，逐毫秒写死）。
class V21EmblemTiming {
  const V21EmblemTiming._();

  /// 弹出：0 → 90ms。
  static const int popInMs = 90;

  /// 停留：90 → 580ms。
  static const int holdMs = 580;

  /// 收束：580 → 330ms。
  static const int outroMs = 330;

  /// 总计 **1000ms**（90 + 580 + 330）。
  static const int totalMs = 1000;

  /// 给定 `elapsedMs`，返回**缩放系数**（弹出放大、收束缩小）。
  ///
  /// 分三段线性插值：0→90ms 由 0.72 升到 1.00；90→580ms 保持 1.00；
  /// 580→910ms 由 1.00 降到 0.86 并淡出。
  static double scaleAt(int elapsedMs) {
    if (elapsedMs <= 0) {
      return 0.72;
    }
    if (elapsedMs < popInMs) {
      final k = elapsedMs / popInMs;
      return 0.72 + (1.00 - 0.72) * k;
    }
    if (elapsedMs < popInMs + holdMs) {
      return 1.00;
    }
    if (elapsedMs < totalMs) {
      final k = (elapsedMs - popInMs - holdMs) / outroMs;
      return 1.00 + (0.86 - 1.00) * k.clamp(0.0, 1.0);
    }
    return 0.86;
  }

  /// 给定 `elapsedMs`，返回**不透明度**（收束段淡出）。
  static double opacityAt(int elapsedMs) {
    if (elapsedMs <= 0) {
      return 0.0;
    }
    if (elapsedMs < popInMs) {
      return (elapsedMs / popInMs).clamp(0.0, 1.0);
    }
    if (elapsedMs < popInMs + holdMs) {
      return 1.0;
    }
    if (elapsedMs < totalMs) {
      final k = (elapsedMs - popInMs - holdMs) / outroMs;
      return (1.0 - k).clamp(0.0, 1.0);
    }
    return 0.0;
  }
}

/// **单一结果队列**（冻结表 §2.3）。
///
/// 「并发事件按产生顺序进入**单一结果队列**，**前项结束后才显示后项**；
///   队列**不暂停战斗、不丢事件**。」
///
/// 本类**不含渲染**：只回答"此刻应显示哪一条、进行到第几毫秒"。
class V21ResultNoticeQueue {
  V21ResultNoticeQueue();

  final List<V21ResultNotice> _pending = <V21ResultNotice>[];
  V21ResultNotice? _current;

  /// 当前项的开始时刻（**逻辑时间**，秒）；`null` 表示无正在播放的项。
  double? _startedAtSeconds;

  /// 尚无正在播放的项时，等待的对列（只读快照，供测试/调试）。
  List<V21ResultNotice> get pending => List<V21ResultNotice>.unmodifiable(_pending);

  /// 正在播放的项。
  V21ResultNotice? get current => _current;

  /// 队列长度（含正在播放的一项）。
  int get length => _pending.length + (_current == null ? 0 : 1);

  /// 入队。**永不丢事件** —— 即使正在播放别的项，也只会排队。
  void enqueue(V21ResultNotice notice) {
    _pending.add(notice);
  }

  /// 每帧调用：若当前项已播完，则推进到下一条。
  ///
  /// [nowSeconds] 必须是**逻辑时间** ⇒ 暂停即冻结 ✓
  /// 返回当前正在播放的项（可能为 null）。
  V21ResultNotice? advance(double nowSeconds) {
    // 先处理"当前项已结束"。
    if (_current != null && _startedAtSeconds != null) {
      final elapsedMs =
          ((nowSeconds - _startedAtSeconds!) * 1000).round();
      if (elapsedMs >= V21EmblemTiming.totalMs) {
        _current = null;
        _startedAtSeconds = null;
      }
    }
    // 没有正在播放的项 → 取下一条（**前项结束后才显示后项**）。
    if (_current == null && _pending.isNotEmpty) {
      _current = _pending.removeAt(0);
      _startedAtSeconds = nowSeconds;
    }
    return _current;
  }

  /// 当前项的播放进度（毫秒）；无当前项时返回 0。
  int elapsedMsAt(double nowSeconds) {
    if (_current == null || _startedAtSeconds == null) {
      return 0;
    }
    final ms = ((nowSeconds - _startedAtSeconds!) * 1000).round();
    return ms.clamp(0, V21EmblemTiming.totalMs);
  }

  /// 清空（重开一局必须调用，避免上一局的徽记残留 —— AC-03）。
  void clear() {
    _pending.clear();
    _current = null;
    _startedAtSeconds = null;
  }
}

// ---------------------------------------------------------------
// 几何（冻结表 §2.3）
// ---------------------------------------------------------------

/// 设计基准画布。
const double kEmblemDesignWidth = 1920;
const double kEmblemDesignHeight = 1080;

/// 固定目标区域：`left=1728, top=28, width=132, height=176`。
const Rect kEmblemDesignRect = Rect.fromLTWH(1728, 28, 132, 176);

/// 距右/上边的最小边距。
const double kEmblemMinEdgeMargin = 24;

/// 计算给定视口下的徽记目标区域。
///
/// 规则（冻结表 §2.3）：
/// * 设计基准 `1920×1080` 下**原样**使用 `1728,28,132,176`；
/// * **小于该宽度的视口等比缩放**，且距右/上**至少 24 logical px**；
/// * 实际图形**按源图纵横比 contain**（由绘制方负责）。
Rect emblemRectFor(double viewportWidth, double viewportHeight) {
  final scale = viewportWidth < kEmblemDesignWidth
      ? (viewportWidth - kEmblemMinEdgeMargin * 2) / kEmblemDesignRect.width
      : 1.0;
  final s = scale.clamp(0.0, 1.0);
  final w = kEmblemDesignRect.width * s;
  final h = kEmblemDesignRect.height * s;
  final rightGap = kEmblemDesignWidth - kEmblemDesignRect.right;
  final left = viewportWidth - rightGap * s - w;
  final top = kEmblemDesignRect.top * s;
  return Rect.fromLTWH(
    left < kEmblemMinEdgeMargin ? kEmblemMinEdgeMargin : left,
    top < kEmblemMinEdgeMargin ? kEmblemMinEdgeMargin : top,
    w,
    h,
  );
}

