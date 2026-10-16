// ================================================================
// lib/game/core/baseline_recorder.dart —— AC-06 无伤通关基准录制
//
// **架构位置**：Core（运行时骨架） —— 按固定顺序驱动 Domain、结算伤害与实体增删、产出**不可变快照**与事件。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：仅 `Playing` 推进逻辑 · 实体增删经待提交队列统一提交（避免遍历中改集合）· 快照不可变。
// ================================================================
// 技术协议 §5.1 / 测试计划第 95 行：
//   「基准首次录制**必须来自一次真实人工操作**。指定的研发或 QA
//     基准操作员在**无 debug cheat、无数值修改、无手工编辑 replay 的
//     release 构建**中，用键鼠/触摸完成一次通关；录制全量输入并保留
//     录屏证据。…成功条件为 **180 秒前胜利且全程 `hpDamage=0`**
//     （护盾承伤允许）。」
//
// 本类只负责**忠实记录**，不做任何搜索、求解或"补一次"：
//   * 逐帧记录真实输入；
//   * 记录选卡与风险门选择（来自真实事件）；
//   * **只要出现过一次 `hpDamage > 0` 就标记失败** —— 不允许事后
//     挑一局"看起来干净"的；
//   * 只有满足成功条件时才写出文件。
//
// 这样"基准是否合规"由**操作本身**决定，而不是由写文件的人决定。
// ================================================================

import 'dart:convert';

import 'domain_event.dart';
import 'input_frame.dart';

/// 录制结果。
class BaselineRecording {
  BaselineRecording({
    required this.seed,
    required this.contentVersion,
    required this.manifestSha256,
  });

  final int seed;
  final String contentVersion;
  final String manifestSha256;

  /// 逐帧输入（**原样**，不插值、不修补）。
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];

  /// 选卡（帧号 → **选卡 ID**）。§5.1 要求记录"选卡 ID"。
  final Map<int, String> cardSelections = <int, String>{};

  /// 风险门选择（帧号 → 选项 ID）。
  final Map<int, String> riskSelections = <int, String>{};

  /// 全程是否**从未受到 HP 伤害**。
  bool hpNeverDamaged = true;

  /// 是否胜利。
  bool victory = false;

  String? resultOutcome;
  int? score;
  double? durationSeconds;

  int _frameIndex = 0;

  /// 记录一帧真实输入。
  void recordFrame(InputFrame frame) {
    frames.add(<String, Object?>{
      'x': frame.moveDirection.x,
      'y': frame.moveDirection.y,
      'dash': frame.dashRequested,
      if (frame.pauseRequested) 'pause': true,
    });
    _frameIndex++;
  }

  /// 消费真实事件：记录选择、跟踪 HP 伤害与胜负。
  void consume(DomainEvent event) {
    switch (event) {
      case UpgradeSelected(:final cardId):
        cardSelections[_frameIndex] = cardId;
      case RiskSelected(:final optionId):
        riskSelections[_frameIndex] = optionId;
      case PlayerDamaged(:final hpDamage):
        // **一键否决**：只要掉过 HP，这局就不能作为无伤基准。
        if (hpDamage > 0) {
          hpNeverDamaged = false;
        }
      case RunEnded(:final result, :final score, :final durationSeconds):
        resultOutcome = result;
        victory = result == 'victory';
        this.score = score;
        this.durationSeconds = durationSeconds;
      default:
        break;
    }
  }

  /// 是否满足 §5.1 的成功条件。
  bool get isEligibleBaseline => victory && hpNeverDamaged;

  /// 序列化为 §5.1 要求的 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'seed': seed,
    'contentVersion': contentVersion,
    'manifestSha256': manifestSha256,
    'result': resultOutcome ?? 'running',
    'score': score ?? 0,
    'durationSeconds': durationSeconds ?? 0,
    'hpNeverDamaged': hpNeverDamaged,
    'frames': frames,
    'cardSelections': cardSelections.map((k, v) => MapEntry('$k', v)),
    'riskSelections': riskSelections,
    'note': 'AC-06 无伤通关基准（协议 §5.1）。由指定基准操作员在一次'
        '真实人工操作中录制；满足"180 秒前胜利且全程 hpDamage=0"才写出。'
        '素材或内容版本变更时必须显式更新版本、manifest hash 与变更说明。',
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// 运行时可得的内容指纹：`records=<条数>;version=<内容版本>`。
///
/// **这不是 §5.1 要的 SHA-256** —— 应用里只有构建复制品
/// （`assets/config/v2/manifest.json`），拿不到仓库里的
/// `素材/manifest.json` 原文件。因此录制端写指纹，
/// 提交前用 `dart run tool/finalize_baseline.dart` 盖上真实 SHA-256。
///
/// 与 `ReplayRecord.matches` 的既有口径一致（同一个字符串既做指纹、
/// 也做版本校验），避免出现两套互不相认的"版本标识"。
String manifestFingerprint({
  required int recordCount,
  required String contentVersion,
}) => 'records=$recordCount;version=$contentVersion';
