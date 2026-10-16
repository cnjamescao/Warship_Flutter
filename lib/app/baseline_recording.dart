// ================================================================
// lib/app/baseline_recording.dart —— AC-06 基准录制的应用层装配
//
// **架构位置**：App（装配与路由） —— 注入依赖、相位与页面路由；**禁止直接遍历战斗实体**。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：内容校验失败必须拒绝开局（不得默认值兜底）· 本层不得引用 Domain 具体规则类型。
// ================================================================
// 协议 §5.1 要求基准来自**一次真实人工操作**。因此录制**默认关闭**，
// 只有操作员显式开启时才生效 —— 日常构建不会产生"基准"。
//
// 开启方式（不需要改代码，也不需要 debug 构建）：
//
//   flutter build macos --release \
//     --dart-define=WARSHIP_RECORD_BASELINE=/绝对路径/baseline_clear_v1.json
//
// 或直接 `flutter run --release --dart-define=...`。
//
// 为什么用 `--dart-define` 而不是配置文件：它**不改动仓库**，
// 因此"用哪次运行产出基准"这件事不会混进版本历史；
// 同时它是 release 构建可用的（协议要求 release 构建）。
// ================================================================

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../game/core/baseline_recorder.dart';

/// 录制目标路径；空字符串表示**不录制**。
const String kBaselineOutputPath = String.fromEnvironment(
  'WARSHIP_RECORD_BASELINE',
);

/// 当前构建是否开启了基准录制。
bool get isBaselineRecordingEnabled => kBaselineOutputPath.isNotEmpty;

/// 按构建配置创建录制器（未开启时返回 null）。
BaselineRecording? createBaselineRecorder({
  required int seed,
  required String contentVersion,
  required String manifestSha256,
}) {
  if (!isBaselineRecordingEnabled) {
    return null;
  }
  return BaselineRecording(
    seed: seed,
    contentVersion: contentVersion,
    manifestSha256: manifestSha256,
  );
}

/// 对局结束时尝试写出基准。
///
/// **只有满足 §5.1 的成功条件才写**（180 秒前胜利 且 全程无 HP 伤害）；
/// 否则**什么都不写**，并打印原因 —— 不合格的局不能被留下来当基准，
/// 哪怕它是"最接近的一次"。
void writeBaselineIfEligible(BaselineRecording? recorder) {
  if (recorder == null) {
    return;
  }
  if (!recorder.isEligibleBaseline) {
    stderr.writeln(
      '[baseline] 本局**不合格**，未写出基准。'
      '胜利=${recorder.victory}，全程无 HP 伤害=${recorder.hpNeverDamaged}。'
      '§5.1 要求「180 秒前胜利 且 hpDamage 全程为 0」。',
    );
    return;
  }

  // ⚠️ macOS 应用是**沙盒**的：写到 `~/Desktop` 会被系统拒绝。
  // 沙盒下 `HOME` 指向容器内的 Data 目录，因此优先写那里 ——
  // 研发可以从
  // `~/Library/Containers/<bundle-id>/Data/Documents/` 读到。
  // 若 dart-define 给的路径可写则优先用它。
  final candidates = <String>[
    kBaselineOutputPath,
    if (!kIsWeb && Platform.environment['HOME'] != null)
      '${Platform.environment['HOME']}/Documents/$kBaselineFileName',
  ];

  for (final path in candidates) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(recorder.encode());
      _reportWritten(file, recorder);
      return;
    } catch (error) {
      stderr.writeln('[baseline] 写入失败（$path）：$error');
    }
  }
  stderr.writeln('[baseline] ❌ 所有候选路径都写不进去，基准未保存。');
}

String get kBaselineFileName => 'warship_baseline.json';

void _reportWritten(File file, BaselineRecording recorder) {
  stdout.writeln('[baseline] 已写出合规基准：${file.absolute.path}');
    stdout.writeln(
      '[baseline] 帧数=${recorder.frames.length}，'
      '选卡=${recorder.cardSelections.length}，'
      '风险门=${recorder.riskSelections.length}，'
      '用时=${recorder.durationSeconds?.toStringAsFixed(1)} 秒',
    );
    stdout.writeln(
      '[baseline] 请把它提交到 test/fixtures/replays/baseline_clear_v1.json，'
      '并在发布验收记录登记操作员角色、设备/OS、构建 revision、'
      'manifest SHA-256 与录屏路径。',
    );
}
