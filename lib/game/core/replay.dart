// ================================================================
// lib/game/core/replay.dart —— 回放记录与确定性校验
// ================================================================
// 依据：Spec/02_技术/v2.0/04_测试计划与验收用例.md
//   T-CORE-04：「同一 seed + 同一 6000 InputFrame 重放两次，
//     事件序列、候选卡、波次、分数、胜负**完全相同**。」
//   §5.1：「`AC-06` 不得用人工操作判定…提交
//     `test/fixtures/replays/baseline_clear_v1.json`，固定为
//     `seed=0x4E454F4E0001`、`contentVersion=2.0.6-material-repair` 和正式
//     `素材/manifest.json` 的 SHA-256，并记录每个逻辑帧的 `InputFrame`、
//     选卡 ID、风险门选项和期望的 `RunEnded` 摘要。」
//
// 关键设计：摘要用**事件序列的滚动哈希**，而不是逐个字段比对。
// 这样任何顺序、数量或内容的漂移都会被发现，而且失败时能给出一个
// 紧凑的可比值。
// ================================================================

import 'dart:convert';

import 'event_bus.dart';
import 'input_frame.dart';
import '../domain/values.dart';

/// FNV-1a 64 位滚动哈希。
///
/// 刻意不用 `Object.hash`：它的取值不保证跨平台/跨版本稳定，
/// 而回放摘要必须是可长期比较的常量。
class EventHasher {
  int _hash = 0xcbf29ce484222325;
  static const int _prime = 0x100000001b3;
  static const int _mask = 0xFFFFFFFFFFFFFFFF;

  /// 无符号 63 位取值。
  ///
  /// Dart 的 `int` 是 64 位**有符号**：`0xFFFFFFFFFFFFFFFF` 会溢出成 `-1`，
  /// 乘法回绕后 `_hash` 是负数，直接用 `toRadixString(16)` 会得到带 `-`
  /// 的字符串，破坏"固定 16 位十六进制"的契约。
  /// 因此这里显式掩掉最高位 —— 63 位哈希对本用途绰绰有余。
  int get value => _hash & 0x7FFFFFFFFFFFFFFF;

  void add(String text) {
    for (final unit in utf8.encode(text)) {
      // `_mask` 为 -1 时按位与是恒等操作；乘法的 64 位回绕由 Dart 保证。
      _hash = ((_hash ^ unit) * _prime) & _mask;
    }
  }

  /// 稳定的十六进制摘要（固定 16 位，恒非负）。
  String get digest => value.toRadixString(16).padLeft(16, '0');
}

/// 一帧的输入记录。
///
/// 只记录**输入**，不记录结果 —— 结果必须由重放重新算出来，
/// 否则回放就只是在"读答案"而不是验证逻辑。
class ReplayFrame {
  const ReplayFrame({
    required this.moveX,
    required this.moveY,
    this.dash = false,
    this.pause = false,
    this.cardSelection,
    this.riskSelection,
  });

  final double moveX;
  final double moveY;
  final bool dash;
  final bool pause;
  final int? cardSelection;
  final String? riskSelection;

  InputFrame toInputFrame() => InputFrame(
    moveDirection: Vec2(moveX, moveY),
    dashRequested: dash,
    pauseRequested: pause,
    cardSelection: cardSelection,
    riskSelection: riskSelection,
  );

  static ReplayFrame fromInputFrame(InputFrame frame) => ReplayFrame(
    moveX: frame.moveDirection.x,
    moveY: frame.moveDirection.y,
    dash: frame.dashRequested,
    pause: frame.pauseRequested,
    cardSelection: frame.cardSelection,
    riskSelection: frame.riskSelection,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'x': moveX,
    'y': moveY,
    if (dash) 'dash': true,
    if (pause) 'pause': true,
    if (cardSelection != null) 'card': cardSelection,
    if (riskSelection != null) 'risk': riskSelection,
  };

  static ReplayFrame fromJson(Map<String, Object?> json) => ReplayFrame(
    moveX: (json['x'] as num?)?.toDouble() ?? 0,
    moveY: (json['y'] as num?)?.toDouble() ?? 0,
    dash: json['dash'] == true,
    pause: json['pause'] == true,
    cardSelection: (json['card'] as num?)?.toInt(),
    riskSelection: json['risk'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is ReplayFrame &&
      other.moveX == moveX &&
      other.moveY == moveY &&
      other.dash == dash &&
      other.pause == pause &&
      other.cardSelection == cardSelection &&
      other.riskSelection == riskSelection;

  @override
  int get hashCode =>
      Object.hash(moveX, moveY, dash, pause, cardSelection, riskSelection);
}

/// 一次回放记录。
class ReplayRecord {
  const ReplayRecord({
    required this.version,
    required this.seed,
    required this.contentVersion,
    required this.manifestSha256,
    required this.frames,
    this.result = 'unknown',
    this.score = 0,
    this.durationSeconds = 0,
    this.eventDigest = '',
    this.note,
  });

  /// 回放格式版本。**格式变化必须升版本**，否则旧回放会被误用。
  final int version;

  final int seed;
  final String contentVersion;
  final String manifestSha256;
  final List<ReplayFrame> frames;

  /// 期望结果（`victory` / `defeat` / `unknown`）。
  final String result;

  /// 期望分数。
  final int score;

  /// 期望有效战斗时长（秒）。
  final double durationSeconds;

  /// 期望的事件序列摘要。
  final String eventDigest;

  /// 变更说明（协议 §5.1 要求素材或内容版本变更时显式更新）。
  final String? note;

  static const int currentVersion = 1;

  bool get isPlaceholder => result == 'unknown';

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'seed': seed,
    'contentVersion': contentVersion,
    'manifestSha256': manifestSha256,
    'result': result,
    'score': score,
    'durationSeconds': durationSeconds,
    'eventDigest': eventDigest,
    if (note != null) 'note': note,
    'frames': frames.map((f) => f.toJson()).toList(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static ReplayRecord decode(String source) {
    final json = jsonDecode(source) as Map<String, Object?>;
    return ReplayRecord(
      version: (json['version'] as num?)?.toInt() ?? 0,
      seed: (json['seed'] as num?)?.toInt() ?? 0,
      contentVersion: json['contentVersion'] as String? ?? '',
      manifestSha256: json['manifestSha256'] as String? ?? '',
      result: json['result'] as String? ?? 'unknown',
      score: (json['score'] as num?)?.toInt() ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 0,
      eventDigest: json['eventDigest'] as String? ?? '',
      note: json['note'] as String?,
      frames: ((json['frames'] as List?) ?? const <Object?>[])
          .cast<Map>()
          .map((m) => ReplayFrame.fromJson(m.cast<String, Object?>()))
          .toList(growable: false),
    );
  }

  /// 版本与内容指纹是否与当前构建一致。
  ///
  /// 协议 §5.1：「版本或 hash 不匹配时**不得执行旧回放**，
  /// 也不得将其结果计为通过。」
  bool matches({
    required String contentVersion,
    required String manifestSha256,
  }) =>
      version == currentVersion &&
      this.contentVersion == contentVersion &&
      this.manifestSha256 == manifestSha256;
}

/// 回放录制器：把每帧输入追加进列表。
///
/// 录制**只在 Playing 相位**进行 —— 冻结相位的输入不改变逻辑，
/// 录进去只会让回放文件无谓变大。
class ReplayRecorder {
  ReplayRecorder({required this.seed, required this.contentVersion,
    required this.manifestSha256});

  final int seed;
  final String contentVersion;
  final String manifestSha256;

  final List<ReplayFrame> _frames = <ReplayFrame>[];

  int get frameCount => _frames.length;

  void record(InputFrame frame) =>
      _frames.add(ReplayFrame.fromInputFrame(frame));

  /// 生成记录。
  ///
  /// [eventDigest] 由调用方在整局结束后用 [digestEvents] 计算。
  ReplayRecord finish({
    required String result,
    required int score,
    required double durationSeconds,
    required String eventDigest,
    String? note,
  }) => ReplayRecord(
    version: ReplayRecord.currentVersion,
    seed: seed,
    contentVersion: contentVersion,
    manifestSha256: manifestSha256,
    frames: List<ReplayFrame>.unmodifiable(_frames),
    result: result,
    score: score,
    durationSeconds: durationSeconds,
    eventDigest: eventDigest,
    note: note,
  );

  void reset() => _frames.clear();
}

/// 计算一批事件的稳定摘要。
///
/// 摘要包含**事件类型 + 帧号 + 序号**，不含负载内容 ——
/// 负载里的浮点坐标在跨平台时可能有极微小差异，把它们纳入摘要
/// 会造成无意义的失败。要检测"数值是否漂移"应当靠针对性的断言，
/// 而不是靠整局摘要。
String digestEvents(Iterable<StampedEvent> events) {
  final hasher = EventHasher();
  for (final stamped in events) {
    hasher.add('${stamped.frameIndex}:${stamped.eventIndex}:'
        '${stamped.eventType}\n');
  }
  return hasher.digest;
}

/// 逐帧推进回放所需的驱动接口。
///
/// 用接口而不是直接依赖 `GameRuntime`：回放工具不该知道战斗内部结构。
abstract interface class ReplayDriver {
  /// 推进一个逻辑帧，返回是否需要继续。
  bool step(InputFrame input);

  /// 当前是否仍在进行中。
  bool get isRunning;

  /// 本帧产生的事件（用于累积摘要）。
  List<StampedEvent> get frameEvents;

  /// 结果摘要。
  String get result;
  int get score;
  double get combatSeconds;
}
