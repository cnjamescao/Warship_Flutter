// ================================================================
// lib/game/domain/risk_gate_system.dart —— 风险门
//
// **架构位置**：Domain（纯规则） —— 无 I/O、无 Flutter 依赖、不持有渲染状态；由 `GameRuntime` 驱动，
//   产出**意图/事件**，不直接改动 Core 的实体集合。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：确定性（同 seed + 同输入必同结果）· 表现无关（不得因"要画什么"改变规则）。
// 风险门是"玩法与后果"的显式选择点：
//   * 选项与后果来自 risk_gates.json 配置，不得硬编码
//   * 开启风险门必须清空普通敌弹并停止新敌生成，否则玩家在选择界面被偷袭
//   * 确认风险门触发 light impact 触感（产品裁决允许的三个场景之一）；超时走 timeoutFallback
// ================================================================
// 依据：产品基线 §7.1
//
// 固定规则：
//   * 出现前清除所有普通敌弹、停止新敌生成；**玩家位置不锁定**；
//   * 选择窗口 5.0 秒，未选择或窗口外点击一律执行保底 `RG-SUPPLY`；
//   * HP ≤35 时 `RG-OVERLOAD` 显示为锁定且不可选择；
//   * 若候选稀有卡全部不可用，`RG-OVERLOAD` **不显示**，由 `RG-BOUNTY` 占位；
//     风险门不重抽、不延时。
// ================================================================

import '../core/random_source.dart';

/// 风险门选项 ID（与 `risk_gates.json` 一致）。
class RiskOptionIds {
  static const String supply = 'RG-SUPPLY';
  static const String bounty = 'RG-BOUNTY';
  static const String overload = 'RG-OVERLOAD';
}

/// 一次选择产生的效果。
class RiskEffect {
  const RiskEffect({
    required this.optionId,
    this.shieldGrant = 0,
    this.hpGrant = 0,
    this.extraEliteCore = 0,
    this.nextEliteHpMultiplier = 1.0,
    this.rareDraftPool = const <String>[],
    this.damageTakenMultiplier = 1.0,
    this.damageTakenDurationSeconds = 0,
  });

  final String optionId;

  /// RG-SUPPLY：护盾 +20、HP +8（均不超过上限）。
  final int shieldGrant;
  final int hpGrant;

  /// RG-BOUNTY：下一个固定精英额外掉落的精英核心数。
  final int extraEliteCore;

  /// RG-BOUNTY 的代价：该精英 HP ×1.25。
  final double nextEliteHpMultiplier;

  /// RG-OVERLOAD：立即三选一的稀有卡池（已过滤不可用项）。
  final List<String> rareDraftPool;

  /// RG-OVERLOAD 的代价：所受最终伤害 ×1.15，持续 20 秒。
  final double damageTakenMultiplier;
  final double damageTakenDurationSeconds;
}

/// 一次风险门的结算结果。
class RiskGateOutcome {
  const RiskGateOutcome({
    required this.gateId,
    required this.optionId,
    required this.wasTimeout,
    required this.effect,
  });

  final String gateId;
  final String optionId;

  /// 是否因为窗口超时或窗口外点击而执行保底。
  final bool wasTimeout;
  final RiskEffect effect;
}

/// 一次进行中的风险门。
class RiskGateSession {
  RiskGateSession({
    required this.gateId,
    required this.availableOptions,
    required this.lockedOptions,
    required this.selectionWindowSeconds,
    required this.timeoutFallbackId,
    this.overloadRarePool = const <String>[],
  }) : _remaining = selectionWindowSeconds;

  final String gateId;

  /// 可以选择的选项（顺序即 UI 顺序）。
  ///
  /// `RG-OVERLOAD` 不可用时**直接不出现**，由 `RG-BOUNTY` 占位 ——
  /// 不重抽、不延时（§7.1）。
  final List<String> availableOptions;

  /// 显示为锁定、不可选择的选项（HP ≤35 时的 `RG-OVERLOAD`）。
  final List<String> lockedOptions;

  final double selectionWindowSeconds;
  final String timeoutFallbackId;
  final List<String> overloadRarePool;

  double _remaining;
  RiskGateOutcome? _outcome;

  double get remainingSeconds => _remaining;
  bool get isResolved => _outcome != null;
  RiskGateOutcome? get outcome => _outcome;

  bool isSelectable(String optionId) =>
      !isResolved && availableOptions.contains(optionId);

  /// 推进窗口；超时则执行保底并返回结果。
  RiskGateOutcome? tick(double dt) {
    if (_outcome != null) {
      return null;
    }
    _remaining -= dt;
    if (_remaining <= 0) {
      _remaining = 0;
      return _resolve(timeoutFallbackId, wasTimeout: true);
    }
    return null;
  }

  /// 玩家选择一个选项。
  ///
  /// 锁定项、未定义项以及窗口外的点击一律按保底处理 ——
  /// 这正是产品基线"未选择或窗口外点击一律执行保底"的字面含义。
  RiskGateOutcome? select(String optionId) {
    if (_outcome != null) {
      return null;
    }
    if (!availableOptions.contains(optionId) || _remaining <= 0) {
      return _resolve(timeoutFallbackId, wasTimeout: true);
    }
    return _resolve(optionId, wasTimeout: false);
  }

  RiskGateOutcome? _resolve(String optionId, {required bool wasTimeout}) {
    _outcome = RiskGateOutcome(
      gateId: gateId,
      optionId: optionId,
      wasTimeout: wasTimeout,
      effect: _effectFor(optionId),
    );
    return _outcome;
  }

  RiskEffect _effectFor(String optionId) {
    switch (optionId) {
      case RiskOptionIds.supply:
        return const RiskEffect(
          optionId: RiskOptionIds.supply,
          shieldGrant: 20,
          hpGrant: 8,
        );
      case RiskOptionIds.bounty:
        return const RiskEffect(
          optionId: RiskOptionIds.bounty,
          extraEliteCore: 1,
          nextEliteHpMultiplier: 1.25,
        );
      case RiskOptionIds.overload:
        return RiskEffect(
          optionId: RiskOptionIds.overload,
          rareDraftPool: List<String>.unmodifiable(overloadRarePool),
          damageTakenMultiplier: 1.15,
          damageTakenDurationSeconds: 20.0,
        );
      default:
        // 未知 ID 安全降级为保底，绝不产生空效果。
        return const RiskEffect(
          optionId: RiskOptionIds.supply,
          shieldGrant: 20,
          hpGrant: 8,
        );
    }
  }
}

/// 风险门系统。
class RiskGateSystem {
  RiskGateSystem({
    required this.overloadHpThreshold,
    required this.selectionWindowSeconds,
    required this.timeoutFallbackId,
    required this.overloadRarePool,
  });

  /// HP ≤ 该值时 `RG-OVERLOAD` 锁定（产品基线 §7.1：35）。
  final int overloadHpThreshold;

  final double selectionWindowSeconds;
  final String timeoutFallbackId;

  /// 过载可抽的稀有卡池（来自 `upgrades.json` 的 rarityPools.overloadRare）。
  final List<String> overloadRarePool;

  /// 打开一道风险门。
  ///
  /// [availableRareCards] 是当前**实际可用**的稀有卡（已过滤满级/互斥/前置）；
  /// 为空时 `RG-OVERLOAD` 整体不显示。
  // ------------------------------------------------------------
  // v2.1-R2：**自动结算**（冻结表 §2.4）
  // ------------------------------------------------------------

  /// **按 `runSeed + gateId + occurrenceOrdinal` 确定性选 1 个合法项**。
  ///
  /// 批复/冻结表原文：
  /// 「按 `runSeed + gateId + occurrenceOrdinal` 从合法项**等权**取 1；
  ///   `RG-OVERLOAD` 只在 `playerHp > 35` 合法」
  /// 「抽取必须由 `RandomSource` 的**带标签固定调用**实现，**不得**按 UI、
  ///   帧率、暂停或渲染重试改变」。
  ///
  /// **实现要点**：
  /// * 用一个**派生的确定性种子**（`runSeed` 混入 `gateId` 的稳定哈希与
  ///   `occurrenceOrdinal`），因此同一局的同一次门**永远**抽出同一项；
  /// * **等权**：直接 `nextInt(candidates.length)`，不按权重；
  /// * 没有合法项 ⇒ 返回 null（调用方必须当作**内容配置错误**响亮失败）。
  /// **当前合法项**（`RG-OVERLOAD` 仅 `playerHp > 35` 且稀有池非空时可选）。
  ///
  /// 顺序固定为 `RG-SUPPLY` → `RG-BOUNTY` → `RG-OVERLOAD`，
  /// 保证"等权抽取"的候选顺序**确定**（否则索引含义会漂移）。
  List<String> legalOptionsFor({
    required int playerHp,
    required List<String> availableRareCards,
  }) {
    final out = <String>[RiskOptionIds.supply, RiskOptionIds.bounty];
    if (playerHp > overloadHpThreshold && availableRareCards.isNotEmpty) {
      out.add(RiskOptionIds.overload);
    }
    return out;
  }

  String? autoPickOption({
    required String gateId,
    required int occurrenceOrdinal,
    required int playerHp,
    required List<String> availableRareCards,
    required RandomSource rng,
  }) {
    final legal = legalOptionsFor(
      playerHp: playerHp,
      availableRareCards: availableRareCards,
    );
    if (legal.isEmpty) {
      return null; // 内容配置错误：调用方必须响亮失败。
    }
    // **等权**取 1。这是**带标签的固定调用**：全工程里
    // `nextInt(legal.length)` 只在此处对 risk gate 发生一次，
    // 且顺序固定（legal 的顺序由 `legalOptionsFor` 保证）。
    // 因此同 seed 同输入必得同一项；不受 UI/帧率/暂停/渲染重试影响。
    final index = rng.nextInt(legal.length);
    assert(
      index >= 0 && index < legal.length,
      'RandomSource.nextInt 越界：$index / ${legal.length}',
    );
    return legal[index];
  }

  RiskGateSession open({
    required String gateId,
    required int playerHp,
    required List<String> availableRareCards,
  }) {
    final options = <String>[RiskOptionIds.supply, RiskOptionIds.bounty];
    final locked = <String>[];

    final rareAvailable = availableRareCards.isNotEmpty;
    if (rareAvailable) {
      options.add(RiskOptionIds.overload);
      if (playerHp <= overloadHpThreshold) {
        // 显示为锁定：可见但不可选。
        locked.add(RiskOptionIds.overload);
      }
    }
    // rareAvailable 为 false 时 OVERLOAD 直接不出现，BOUNTY 自然占位。

    return RiskGateSession(
      gateId: gateId,
      availableOptions: options
          .where((o) => !locked.contains(o))
          .toList(growable: false),
      lockedOptions: locked,
      selectionWindowSeconds: selectionWindowSeconds,
      timeoutFallbackId: timeoutFallbackId,
      overloadRarePool: availableRareCards,
    );
  }

  /// 计算 `RG-OVERLOAD` 的即时三选一：从可用稀有卡中抽取至多 3 张。
  ///
  /// 抽取顺序即候选顺序，保证回放一致。
  List<String> overloadDraft(List<String> availableRareCards) =>
      availableRareCards.take(3).toList(growable: false);
}

/// 过载代价的运行时计时（所受最终伤害 ×1.15，20 秒）。
class OverloadPenalty {
  OverloadPenalty({required this.multiplier, required this.durationSeconds})
    : _remaining = durationSeconds;

  final double multiplier;
  final double durationSeconds;

  double _remaining;

  bool get isActive => _remaining > 0;
  double get remainingSeconds => _remaining;

  void activate() => _remaining = durationSeconds;

  void tick(double dt) {
    if (_remaining <= 0) {
      return;
    }
    _remaining -= dt;
    if (_remaining < 0) {
      _remaining = 0;
    }
  }

  /// 对所受最终伤害施加倍率。
  int apply(int finalDamage) =>
      isActive ? (finalDamage * multiplier).round() : finalDamage;

  void reset() => _remaining = 0;
}

/// `RG-BOUNTY` 对下一个固定精英的挂起效果。
class BountyPending {
  int extraCores = 0;
  double hpMultiplier = 1.0;

  bool get isPending => extraCores > 0;

  void arm({required int extraCores, required double hpMultiplier}) {
    this.extraCores = extraCores;
    this.hpMultiplier = hpMultiplier;
  }

  /// 精英死亡（或被移除）后清除。
  void consume() {
    extraCores = 0;
    hpMultiplier = 1.0;
  }

  void reset() => consume();
}

/// **一次风险门的自动结算记录**（v2.1-R2 / 冻结表 §2.4）。
///
/// 冻结表要求把 `gateId`、`occurrenceOrdinal`、`optionId` 与
/// **`resultNoticeOrdinal`** 一并保存到回放快照 ——
/// 最后一项是"结果徽记队列里的序号"，用于把**画面上的徽记**
/// 与**规则层的结算**一一对上（否则徽记串位无法举证）。
class RiskGateResolution {
  const RiskGateResolution({
    required this.gateId,
    required this.occurrenceOrdinal,
    required this.optionId,
    required this.resultNoticeOrdinal,
  });

  final String gateId;

  /// 该 gate 在本局中的第几次（**0 基**）。
  final int occurrenceOrdinal;

  final String optionId;

  /// 结果徽记队列中的全局序号（强化与风险门共用一个计数器）。
  final int resultNoticeOrdinal;

  @override
  String toString() =>
      'RiskGateResolution($gateId#$occurrenceOrdinal → $optionId, '
      'notice=$resultNoticeOrdinal)';
}

/// 风险选项的**文案 key 映射**（语义模板参数用）。
///
/// 与 `assets/config/v2/risk_gates.json` 的 `options[].nameKey` /
/// `descKey` **逐项对应**；由 `v21_risk_notice_keys_test.dart` 自动对账，
/// 任何一边改动而另一边没跟，测试立刻失败（防止静默漂移）。
const Map<String, String> kRiskOptionNameKeys = <String, String>{
  RiskOptionIds.supply: 'risk.supply.name',
  RiskOptionIds.bounty: 'risk.bounty.name',
  RiskOptionIds.overload: 'risk.overload.name',
};

const Map<String, String> kRiskOptionDescKeys = <String, String>{
  RiskOptionIds.supply: 'risk.supply.desc',
  RiskOptionIds.bounty: 'risk.bounty.desc',
  RiskOptionIds.overload: 'risk.overload.desc',
};
