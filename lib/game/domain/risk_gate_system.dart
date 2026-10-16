// ================================================================
// lib/game/domain/risk_gate_system.dart —— 风险门
//
// **架构位置**：Domain（纯规则） —— 无 I/O、无 Flutter 依赖、不持有渲染状态；由 `GameRuntime` 驱动，
//   产出**意图/事件**，不直接改动 Core 的实体集合。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：确定性（同 seed + 同输入必同结果）· 表现无关（不得因"要画什么"改变规则）。
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
