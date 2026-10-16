// ================================================================
// lib/game/domain/upgrade_system.dart —— 升级草案与 modifier 应用
//
// **架构位置**：Domain（纯规则） —— 无 I/O、无 Flutter 依赖、不持有渲染状态；由 `GameRuntime` 驱动，
//   产出**意图/事件**，不直接改动 Core 的实体集合。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：确定性（同 seed + 同输入必同结果）· 表现无关（不得因"要画什么"改变规则）。
// ================================================================
// 依据：产品基线 §4.2（升级阈值与抽取）
//
// 每次三选一的固定流程：
//   过滤不可用卡 → 先放入保证卡 → 加权无放回抽取至 3 张
//   → **固定候选顺序写入事件**
//
// 保证规则：
//   * 第 1 次必有 UP-PULSE-RATE；
//   * 第 2 次必有 UP-PULSE-SPREAD 或 UP-MISSILE-UNLOCK；
//   * 第 3 次及以后至少 1 张来自已拥有系列或生存系列；
//   * 连续两次没有伤害卡时，第三次强制加入伤害卡；
//   * 每张卡同局只可抽到 maxLevel 级；满级与互斥卡过滤。
//
// 时间门：第 1 次草案不得早于有效战斗时间 15.0 秒。15 秒前积累的经验
// **照常保留**，15.0 秒时若已达 20 立即打开；未达到则在后续首次达到时打开。
// ================================================================

import '../core/random_source.dart';
import 'values.dart';

/// 一条升级效果。`kind` 决定语义，参数保持原样供各系统解释。
class UpgradeEffect {
  const UpgradeEffect(this.kind, this.params);

  final String kind;
  final Map<String, Object?> params;

  String? get weaponId => params['weaponId'] as String?;
  String? get stat => params['stat'] as String?;
  double? get factor => (params['factor'] as num?)?.toDouble();
  double? get amount => (params['amount'] as num?)?.toDouble();
  double? get amountPerLevel => (params['amountPerLevel'] as num?)?.toDouble();
  String? get chainId => params['chainId'] as String?;

  List<double> get numbers =>
      ((params['countByLevel'] ??
                  params['angleDegreesByLevel'] ??
                  params['hopsByLevel'] ??
                  params['radiusByLevel']) as List?)
              ?.whereType<num>()
              .map((n) => n.toDouble())
              .toList(growable: false) ??
      const <double>[];
}

/// 一张升级卡（从 `upgrades.json` 映射）。
class UpgradeCard {
  const UpgradeCard({
    required this.id,
    required this.nameKey,
    required this.descKey,
    required this.series,
    required this.maxLevel,
    required this.weight,
    required this.prerequisites,
    required this.excludes,
    required this.effects,
    required this.iconAssetId,
    required this.rarity,
  });

  final String id;
  final String nameKey;
  final String descKey;
  final String series;
  final int maxLevel;
  final int weight;
  final List<String> prerequisites;
  final List<String> excludes;
  final List<UpgradeEffect> effects;
  final String iconAssetId;
  final String rarity;

  static UpgradeCard fromConfig(Map<String, Object?> config) => UpgradeCard(
    id: config['id'] as String? ?? 'UP-UNKNOWN',
    nameKey: config['nameKey'] as String? ?? '',
    descKey: config['descKey'] as String? ?? '',
    series: config['series'] as String? ?? 'unknown',
    maxLevel: (config['maxLevel'] as num?)?.toInt() ?? 1,
    weight: (config['weight'] as num?)?.toInt() ?? 0,
    prerequisites: ((config['prerequisites'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false),
    excludes: ((config['excludes'] as List?) ?? const [])
        .whereType<String>()
        .toList(growable: false),
    iconAssetId: config['iconAssetId'] as String? ?? '',
    rarity: config['rarity'] as String? ?? 'common',
    effects: ((config['effects'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (m) => UpgradeEffect(
            m['kind'] as String? ?? 'unknown',
            m.cast<String, Object?>(),
          ),
        )
        .toList(growable: false),
  );
}

/// 一次草案的候选结果。
class DraftOffer {
  const DraftOffer({
    required this.candidates,
    required this.guaranteed,
    required this.draftIndex,
  });

  /// 三张候选卡的 ID，**顺序已固定**（保证卡在前）。
  final List<String> candidates;

  /// 本次被强制放入的卡。
  final List<String> guaranteed;

  /// 这是第几次草案（0 起）。
  final int draftIndex;

  bool get isComplete => candidates.length == 3;

  @override
  String toString() =>
      'DraftOffer#$draftIndex ${candidates.join(", ")} (guaranteed: ${guaranteed.join(", ")})';
}

/// 一局内的升级状态。
class UpgradeState {
  UpgradeState({required this.maxDrafts});

  final int maxDrafts;

  /// 卡 ID → 已取得等级。
  final Map<String, int> levels = <String, int>{};

  /// 已完成的草案次数。
  int draftCount = 0;

  /// 连续未出现伤害卡的草案次数。
  int consecutiveDraftsWithoutDamage = 0;

  /// 本局已选择的升级卡次数（等于 `draftCount`；产品基线 §6 的"升级数"
  /// 定义为此值，**不是** HUD 的 Lv 数字）。
  int get upgradeCount => draftCount;

  bool get isMaxed => draftCount >= maxDrafts;

  int levelOf(String cardId) => levels[cardId] ?? 0;

  bool owns(String cardId) => levelOf(cardId) > 0;

  /// 已拥有的全部系列。
  Set<String> get ownedSeries => <String>{
    for (final entry in levels.entries)
      if (entry.value > 0) entry.key,
  };

  /// 已拥有的卡的系列集合（需要卡片表才能解析，由系统注入）。
  void reset() {
    levels.clear();
    draftCount = 0;
    consecutiveDraftsWithoutDamage = 0;
  }
}

/// 加权抽卡所需的随机上下文。
class DraftContext {
  const DraftContext({
    required this.combatSeconds,
    required this.xp,
    required this.damageCardIds,
  });

  final double combatSeconds;
  final int xp;

  /// 哪些卡算"伤害卡"（由内容配置显式声明，不在代码里推断）。
  final Set<String> damageCardIds;
}

/// 升级系统。
class UpgradeSystem {
  UpgradeSystem({
    required List<UpgradeCard> cards,
    required List<int> xpThresholds,
    required this.firstDraftEarliestSecond,
    required this.maxDrafts,
    required this.draftSize,
    required this.damageCardIds,
    this.guaranteedFirstDraft = const <String>['UP-PULSE-RATE'],
    this.guaranteedSecondDraftAnyOf = const <String>[
      'UP-PULSE-SPREAD',
      'UP-MISSILE-UNLOCK',
    ],
  }) : _cards = <String, UpgradeCard>{
         for (final card in cards) card.id: card,
       },
       _order = cards.map((c) => c.id).toList(growable: false),
       _thresholds = List<int>.unmodifiable(xpThresholds);

  final Map<String, UpgradeCard> _cards;
  final List<String> _order;
  final List<int> _thresholds;

  final double firstDraftEarliestSecond;
  final int maxDrafts;
  final int draftSize;
  final Set<String> damageCardIds;
  final List<String> guaranteedFirstDraft;
  final List<String> guaranteedSecondDraftAnyOf;

  UpgradeCard? card(String id) => _cards[id];

  List<int> get xpThresholds => _thresholds;

  /// 第 [draftIndex] 次草案所需的累计经验；超出范围返回 null。
  int? thresholdFor(int draftIndex) =>
      draftIndex < _thresholds.length ? _thresholds[draftIndex] : null;

  // ------------------------------------------------------------
  // 时间门（T-UP-00）
  // ------------------------------------------------------------

  /// 草案是否应当打开。
  ///
  /// * 已达到最大草案次数 → 不再打开（经验仍可计分）；
  /// * 未达该次阈值 → 不打开；
  /// * 第 1 次且未到 15.0 秒 → 不打开，但**经验保留**。
  bool isDraftDue({
    required int xp,
    required int draftCount,
    required double combatSeconds,
  }) {
    if (draftCount >= maxDrafts) {
      return false;
    }
    final threshold = thresholdFor(draftCount);
    if (threshold == null || xp < threshold) {
      return false;
    }
    if (draftCount == 0 && combatSeconds < firstDraftEarliestSecond) {
      return false;
    }
    return true;
  }

  // ------------------------------------------------------------
  // 候选生成（T-UP-01 / T-UP-02）
  // ------------------------------------------------------------

  /// 当前可用的卡 ID 列表（已按固定顺序）。
  ///
  /// 过滤规则：满级、互斥（双向）、前置不满足。
  List<String> availableCards(UpgradeState state) {
    final available = <String>[];
    for (final id in _order) {
      final card = _cards[id]!;
      if (state.levelOf(id) >= card.maxLevel) {
        continue; // 满级
      }
      // 互斥：本卡排斥的卡已拥有，或已拥有的卡排斥本卡。
      var blocked = false;
      for (final excluded in card.excludes) {
        if (state.owns(excluded)) {
          blocked = true;
          break;
        }
      }
      if (!blocked) {
        for (final owned in state.levels.keys) {
          if (state.levelOf(owned) <= 0) {
            continue;
          }
          if (_cards[owned]?.excludes.contains(id) ?? false) {
            blocked = true;
            break;
          }
        }
      }
      if (blocked) {
        continue;
      }
      if (!_prerequisitesMet(card, state)) {
        continue;
      }
      if (card.weight <= 0) {
        continue;
      }
      available.add(id);
    }
    return available;
  }

  bool _prerequisitesMet(UpgradeCard card, UpgradeState state) {
    for (final prereq in card.prerequisites) {
      if (prereq == 'anyPulseCard') {
        // 语义前置：至少取得 1 张脉冲系列卡。
        final hasPulse = state.levels.entries.any(
          (e) => e.value > 0 && _cards[e.key]?.series == 'pulse',
        );
        if (!hasPulse) {
          return false;
        }
        continue;
      }
      if (!state.owns(prereq)) {
        return false;
      }
    }
    return true;
  }

  /// 生成本次草案。
  ///
  /// 返回 null 表示候选池为空（属于配置错误，内容校验器应已拦下；
  /// 运行期遇到时安全跳过而不崩溃）。
  DraftOffer? generateDraft({
    required UpgradeState state,
    required RandomSource rng,
    required DraftContext context,
  }) {
    final available = availableCards(state);
    if (available.isEmpty) {
      return null;
    }

    final guaranteed = <String>[];
    final picked = <String>[];

    void tryGuarantee(String id) {
      if (picked.length >= draftSize) {
        return;
      }
      if (available.contains(id) && !picked.contains(id)) {
        picked.add(id);
        guaranteed.add(id);
      }
    }

    // ---- 保证卡 ----
    if (state.draftCount == 0) {
      for (final id in guaranteedFirstDraft) {
        tryGuarantee(id);
      }
    } else if (state.draftCount == 1) {
      // 「或」关系：取第一个可用的即可，不把两张都塞进去。
      for (final id in guaranteedSecondDraftAnyOf) {
        if (available.contains(id) && !picked.contains(id)) {
          tryGuarantee(id);
          break;
        }
      }
    } else {
      // 第 3 次及以后：至少 1 张来自已拥有系列或生存系列。
      final ownedSeries = _ownedSeries(state);
      final preferred = available.firstWhere(
        (id) =>
            !picked.contains(id) &&
            (ownedSeries.contains(_cards[id]!.series) ||
                _cards[id]!.series == 'survival'),
        orElse: () => '',
      );
      if (preferred.isNotEmpty) {
        tryGuarantee(preferred);
      }
    }

    // 连续两次没有伤害卡 → 强制加入一张伤害卡。
    if (state.consecutiveDraftsWithoutDamage >= 2) {
      final damageCard = available.firstWhere(
        (id) => damageCardIds.contains(id) && !picked.contains(id),
        orElse: () => '',
      );
      if (damageCard.isNotEmpty) {
        tryGuarantee(damageCard);
      }
    }

    // ---- 加权无放回抽取至 3 张 ----
    final pool = available.where((id) => !picked.contains(id)).toList();
    while (picked.length < draftSize && pool.isNotEmpty) {
      final chosen = _weightedDraw(pool, rng);
      pool.remove(chosen);
      picked.add(chosen);
    }

    state.draftCount += 1;

    // 记录"本次是否含伤害卡"，供下一次的干旱规则使用。
    final hasDamage = picked.any(damageCardIds.contains);
    state.consecutiveDraftsWithoutDamage = hasDamage
        ? 0
        : state.consecutiveDraftsWithoutDamage + 1;

    return DraftOffer(
      candidates: List<String>.unmodifiable(picked),
      guaranteed: List<String>.unmodifiable(guaranteed),
      draftIndex: state.draftCount - 1,
    );
  }

  /// 加权无放回抽取一张。
  ///
  /// 使用 `rng.nextInt(totalWeight)` 走权重区间 —— 只依赖 [RandomSource]
  /// 的整数原语，因此回放一致。
  String _weightedDraw(List<String> pool, RandomSource rng) {
    var total = 0;
    for (final id in pool) {
      total += _cards[id]!.weight;
    }
    if (total <= 0) {
      return pool.first;
    }
    var roll = rng.nextInt(total);
    for (final id in pool) {
      final weight = _cards[id]!.weight;
      if (roll < weight) {
        return id;
      }
      roll -= weight;
    }
    return pool.last;
  }

  Set<String> _ownedSeries(UpgradeState state) => <String>{
    for (final entry in state.levels.entries)
      if (entry.value > 0) _cards[entry.key]!.series,
  };

  /// 应用一次选择：提升等级并返回该卡的 effects。
  List<UpgradeEffect> applyCard(UpgradeState state, String cardId) {
    final card = _cards[cardId];
    if (card == null) {
      return const <UpgradeEffect>[];
    }
    final current = state.levelOf(cardId);
    if (current >= card.maxLevel) {
      return const <UpgradeEffect>[]; // 满级不再叠加
    }
    state.levels[cardId] = current + 1;
    return card.effects;
  }

  /// 已选升级（用于结算页"本局构筑"）。
  Map<String, int> selectedLevels(UpgradeState state) =>
      Map<String, int>.unmodifiable(state.levels);
}

/// 把 modifier 应用到数值上的辅助：把某张卡的全部等级折算为倍率/增量的
/// 累加器，交给 [ModifierStack]。
///
/// 之所以单独放在这里而不是塞进 [UpgradeSystem]：它需要玩家/武器的
/// 具体数值容器，属于调用方的职责。
class UpgradeAccumulator {
  final Map<String, int> _levels = <String, int>{};

  void setLevel(String cardId, int level) => _levels[cardId] = level;

  int levelOf(String cardId) => _levels[cardId] ?? 0;

  /// 计算「每级 +X」类效果的累计增量。
  double totalAdd(UpgradeSystem system, String effectKind, String stat) {
    var total = 0.0;
    for (final entry in _levels.entries) {
      final card = system.card(entry.key);
      if (card == null) {
        continue;
      }
      for (final effect in card.effects) {
        if (effect.kind == effectKind && effect.stat == stat) {
          total += (effect.amountPerLevel ?? effect.amount ?? 0) * entry.value;
        }
      }
    }
    return total;
  }

  /// 计算「逐级叠乘」类效果的累计倍率。
  double totalMultiply(UpgradeSystem system, String effectKind) {
    var factor = 1.0;
    for (final entry in _levels.entries) {
      final card = system.card(entry.key);
      if (card == null) {
        continue;
      }
      for (final effect in card.effects) {
        if (effect.kind == effectKind) {
          final f = effect.factor ?? 1.0;
          for (var i = 0; i < entry.value; i++) {
            factor *= f;
          }
        }
      }
    }
    return factor;
  }
}
