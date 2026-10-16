// ================================================================
// lib/game/core/run_context.dart —— 一局的身份与序号
//
// **架构位置**：Core（运行时骨架） —— 按固定顺序驱动 Domain、结算伤害与实体增删、产出**不可变快照**与事件。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：仅 `Playing` 推进逻辑 · 实体增删经待提交队列统一提交（避免遍历中改集合）· 快照不可变。
// RunContext 是一局的身份与随机源容器：
//   * 含 RunIdentity（runId / seed / PRNG 算法名 / 内容版本 / manifest SHA-256）
//   * 这些字段是回放可复现的全部依据；内容版本或 manifest 变化后旧基准即失效
//   * runId 仅供诊断关联，不得参与任何随机或判定
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §2
//   core 负责「Run ID、种子、逻辑时钟、状态、固定 dt、事件序号」。
//
// 以及产品基线 §3.2：一局只使用一个确定性 PRNG，
// 同一 seed + 同一输入序列必须产生完全相同的结果。
// ================================================================

import 'random_source.dart';

/// 一局的不可变身份信息。
///
/// `runId` 与 `seed` 只在**新局创建时**生成一次（技术架构 §3.2：
/// 旧对象不得再向 HUD、音频或 Flame World 发事件）。
class RunIdentity {
  const RunIdentity({
    required this.runId,
    required this.seed,
    required this.prngAlgorithm,
    required this.contentVersion,
    required this.contentManifestSha256,
  });

  /// 本局唯一 ID，用于事件归属校验与调试。
  final String runId;

  /// 本局随机种子。回放以它 + 输入序列为准。
  final int seed;

  /// PRNG 算法名，写入 `RunStarted`。
  final String prngAlgorithm;

  /// 内容版本，当前唯一允许值为 `2.0.6-material-repair`。
  final String contentVersion;

  /// 正式 `素材/manifest.json` 的 SHA-256；回放与验收依赖它。
  final String contentManifestSha256;
}

/// 一局的运行时计数器与随机源。
///
/// 事件序号必须单调递增，以保证回放时事件序列可比较（协议 §3）。
class RunContext {
  RunContext({required this.identity, required this.random})
    : assert(identity.seed == random.seed, 'RunContext 的 seed 必须与随机源一致');

  final RunIdentity identity;
  final RandomSource random;

  int _frameIndex = 0;
  int _eventIndex = 0;

  /// 当前逻辑帧号。
  int get frameIndex => _frameIndex;

  /// 下一个事件序号。
  int get nextEventIndex => _eventIndex;

  String get runId => identity.runId;
  int get seed => identity.seed;

  /// 由时钟驱动的帧号同步。
  void setFrameIndex(int value) {
    assert(value >= _frameIndex, 'frameIndex 不得回退');
    _frameIndex = value;
  }

  /// 取用一个事件序号（写事件时调用）。
  int consumeEventIndex() => _eventIndex++;
}
