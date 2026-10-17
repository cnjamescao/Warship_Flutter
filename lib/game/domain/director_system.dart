// ================================================================
// lib/game/domain/director_system.dart —— 波次调度与动态校正
//
// **⚠️ 易错点（真实事故）**：
//   * **「延后批次」分支里有提前 return**：
//     `if (triggers.isNotEmpty || _deferred != null) return triggers;` ——
//     延后未解决时**会阻止推进新行**。我在排查 F-39 时首先怀疑这里，
//     实测该路径正常（`nextRowIndex` 走到 31/31、`deferred=false`），
//     真因在别处（bootstrap 漏传 `bossSystem`）。**但这条早退本身
//     确实是波次停滞的合理嫌疑，改动时务必留意。**
//   * **行触发是 `while (startSecond <= combatSeconds)`**，一次可推进多行；
//     Boss 行与风险门行**不由生成流程处理**，而是交给上层状态机。
//   * `minimumUpgradesAt()` 只用于**动态校正**判定，
//     **不门控波次行触发**（我一度误判为 Boss 不出现的原因）。
// ================================================================
// 依据：产品基线 §6（波次和导演器表）
//
// **架构位置**：Domain 层 —— **纯规则**，无 I/O、无 Flutter 依赖、
//   不持有渲染状态。由 `GameRuntime` 按固定顺序驱动，每步产出的
//   是**意图/事件**，由 Core 统一结算与提交。
//
// **与谁交互**：
//   * 上游：`GameRuntime._stepOnce()` 传入本步的 `dt`/输入/世界状态
//   * 下游：返回"待施加的意图"（移动、伤害、生成请求…），
//     **本层不直接改动 Core 的实体集合**
//
// **关键约束**：
//   * **确定性**：同一 seed + 同一输入序列必须产出完全相同的结果 ——
//     禁止使用 `DateTime.now()`、未播种随机、或集合遍历顺序依赖
//   * **表现无关**：本层不得因"要画什么"而改变规则
//     （由 `acceptance_visual_must_not_affect_rules_test.dart` 守住）
// 逐条对应的固定规则：
//   * 生成点 y=-80，x 只能取 240/480/720/960/1200/1440/1680；
//   * 队形中心距玩家当前 x **不得小于 360**；所有合法点都不满足时
//     延后该批最多 1.0 秒，**不可贴脸生成**；
//   * 每一行在时间窗开始时执行**一次**；
//   * 动态校正每 10 秒评估一次，只改变**下两批普通敌人数量**：
//     HP ≤35 或过去 15 秒 HP 伤害 ≥30 → 各减 1 个 Scout（无 Scout 则减 Wing）；
//     HP ≥80、15 秒未受伤且升级数达标 → 各加 1 个 Scout（同屏上限 45）；
//   * 不得改变敌种、精英、风险门、预警时长或 Boss。
// ================================================================

import 'values.dart';

/// 波次中的一批生成。
class WaveSpawn {
  const WaveSpawn({
    required this.enemyId,
    required this.count,
    required this.formation,
    this.centerX,
    this.isElite = false,
    this.affixId,
  });

  final String enemyId;
  final int count;
  final String formation;
  final double? centerX;
  final bool isElite;
  final String? affixId;

  WaveSpawn withCount(int newCount) => WaveSpawn(
    enemyId: enemyId,
    count: newCount < 0 ? 0 : newCount,
    formation: formation,
    centerX: centerX,
    isElite: isElite,
    affixId: affixId,
  );

  static WaveSpawn fromConfig(Map<String, Object?> config) => WaveSpawn(
    enemyId: config['enemyId'] as String? ?? 'EN-UNKNOWN',
    count: (config['count'] as num?)?.toInt() ?? 0,
    formation: config['formation'] as String? ?? 'line',
    centerX: (config['centerX'] as num?)?.toDouble(),
    isElite: config['isElite'] == true,
    affixId: config['affixId'] as String?,
  );
}

/// 波次表中的一行。
class WaveRow {
  const WaveRow({
    required this.startSecond,
    required this.spawns,
    this.riskGateId,
    this.bossEntry = false,
    this.clearEnemyBullets = false,
    this.dynamicAdjustmentAllowed = true,
  });

  final int startSecond;
  final List<WaveSpawn> spawns;
  final String? riskGateId;
  final bool bossEntry;
  final bool clearEnemyBullets;
  final bool dynamicAdjustmentAllowed;

  bool get isRiskGate => riskGateId != null;
  bool get isBossEntry => bossEntry;

  static WaveRow fromConfig(Map<String, Object?> config) => WaveRow(
    startSecond: (config['startSecond'] as num?)?.toInt() ?? 0,
    spawns: ((config['spawns'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => WaveSpawn.fromConfig(m.cast<String, Object?>()))
        .toList(growable: false),
    riskGateId: config['riskGateId'] as String?,
    bossEntry: config['bossEntry'] == true,
    clearEnemyBullets: config['clearEnemyBullets'] == true,
    dynamicAdjustmentAllowed: config['dynamicAdjustmentAllowed'] != false,
  );
}

/// 最低升级数时段（产品基线 §6）。
class MinimumUpgradeWindow {
  const MinimumUpgradeWindow({
    required this.fromSecond,
    required this.toSecond,
    required this.minimumUpgrades,
  });

  final double fromSecond;
  final double toSecond;
  final int minimumUpgrades;

  static MinimumUpgradeWindow fromConfig(Map<String, Object?> config) =>
      MinimumUpgradeWindow(
        fromSecond: (config['fromSecond'] as num?)?.toDouble() ?? 0,
        toSecond: (config['toSecond'] as num?)?.toDouble() ?? 0,
        minimumUpgrades: (config['minimumUpgrades'] as num?)?.toInt() ?? 0,
      );
}

/// 动态校正的档位。
enum AdjustmentKind { none, reduce, increase }

/// 一次调整决策的结果，供调试面板与日志消费。
class AdjustmentDecision {
  const AdjustmentDecision({
    required this.kind,
    required this.atSecond,
    this.scoutDelta = 0,
    this.wingDelta = 0,
    this.reason = '',
  });

  final AdjustmentKind kind;
  final double atSecond;
  final int scoutDelta;
  final int wingDelta;
  final String reason;
}

/// 本步应当执行的一个波次动作。
class DirectorTrigger {
  const DirectorTrigger({
    required this.row,
    required this.spawns,
    this.centerX,
    this.deferredReason,
  });

  final WaveRow row;

  /// 已应用动态校正后的生成列表。
  final List<WaveSpawn> spawns;

  /// 本批的队形中心 x（null 表示没有可用的安全生成点，已延后）。
  final double? centerX;

  final String? deferredReason;

  bool get isDeferred => centerX == null && spawns.isNotEmpty;
}

/// 导演器：波次推进、生成点安全选择与动态校正。
class DirectorSystem {
  DirectorSystem({
    required List<WaveRow> rows,
    required List<MinimumUpgradeWindow> minimumUpgradeWindows,
    required this.eliteRules,
    this.spawnY = -80,
    this.spawnXPoints = const <double>[240, 480, 720, 960, 1200, 1440, 1680],
    this.minDistanceFromPlayerX = 360,
    this.deferMaxSeconds = 1.0,
    this.totalEnemyCap = 45,
    this.evaluateIntervalSeconds = 10.0,
    this.reduceHpAtOrBelow = 35,
    this.reduceDamageInLast15s = 30,
    this.increaseHpAtOrAbove = 80,
  }) : _rows = List<WaveRow>.unmodifiable(rows),
       _windows = List<MinimumUpgradeWindow>.unmodifiable(
         minimumUpgradeWindows,
       );

  final List<WaveRow> _rows;
  final List<MinimumUpgradeWindow> _windows;

  /// 精英倍率（供生成时使用；Director 只在固定精英事件上消费它）。
  final Map<String, int> eliteRules;

  // ---- F-39 诊断（**只读**，不参与任何规则判定） ----
  //
  // 存在理由：实测应用流中 `combatSeconds` 已推进到 180 秒，
  // 但 150 秒的 `bossEntry` 行从未触发。怀疑卡在
  // 「2. 先处理被延后的批次」的提前 return 上，需要观测
  // `_nextRowIndex` 与 `_deferred` 的实际状态，而不是继续推测。

  /// 总行数。
  int get rowCount => _rows.length;

  /// 是否存在**未解决的延后批次**（存在时会阻止推进新行）。
  bool get hasDeferredBatch => _deferred != null;

  /// 被延后行的 `startSecond`（无则 null）。
  int? get deferredStartSecond => _deferred?.row.startSecond;

  /// 尚未触发的行里最早的一行的 `startSecond`（全触发完则 null）。
  /// **是否还有尚未触发的 Boss 入场行**（v2.1 清场四条件之一）。
  ///
  /// 清场判定必须排除"Director 还没跑完、后面还有 Boss 要来"的情形，
  /// 否则玩家会在 Boss 出现前就"清场胜利"。
  bool get hasFutureBossEntry {
    for (var i = _nextRowIndex; i < _rows.length; i++) {
      if (_rows[i].bossEntry) {
        return true;
      }
    }
    return _deferred != null && _deferred!.row.bossEntry;
  }

  /// **Director 是否已跑完全部行**（v2.1 清场四条件之一）。
  bool get isExhausted =>
      _nextRowIndex >= _rows.length && _deferred == null;

  int? get nextPendingRowSecond =>
      _nextRowIndex < _rows.length ? _rows[_nextRowIndex].startSecond : null;

  final double spawnY;
  final List<double> spawnXPoints;
  final double minDistanceFromPlayerX;
  final double deferMaxSeconds;
  final int totalEnemyCap;
  final double evaluateIntervalSeconds;
  final int reduceHpAtOrBelow;
  final int reduceDamageInLast15s;
  final int increaseHpAtOrAbove;

  int _nextRowIndex = 0;

  /// 首次评估时刻。
  ///
  /// 刻意**不是 0**：在 t=0 时"过去 15 秒未受 HP 伤害"是平凡成立的，
  /// 会让每一次开局都立刻把教程波次加成 +1，等于绕过了策划写死的难度曲线。
  /// "每 10 秒评估一次"应当理解为 t=10/20/…，评估前必须真的流逝过时间。
  late double _nextEvaluationAt = evaluateIntervalSeconds;

  /// 待应用的调整量（作用于接下来的两批）。
  int _pendingScoutDelta = 0;
  int _pendingWingDelta = 0;
  int _pendingBatches = 0;

  /// 被延后的批次：记录原行与已等待时长。
  _DeferredBatch? _deferred;

  final List<AdjustmentDecision> decisions = <AdjustmentDecision>[];

  List<WaveRow> get rows => _rows;
  int get nextRowIndex => _nextRowIndex;

  /// 还需要应用调整的批次数量（诊断用）。
  int get pendingBatches => _pendingBatches;

  void reset() {
    _nextRowIndex = 0;
    _nextEvaluationAt = evaluateIntervalSeconds;
    _pendingScoutDelta = 0;
    _pendingWingDelta = 0;
    _pendingBatches = 0;
    _deferred = null;
    decisions.clear();
  }

  /// 某一时刻的最低升级数。
  int minimumUpgradesAt(double second) {
    for (final window in _windows) {
      if (second >= window.fromSecond && second <= window.toSecond) {
        return window.minimumUpgrades;
      }
    }
    return 0;
  }

  /// 在一个逻辑步内推进导演器。
  ///
  /// 返回本步应当触发的动作（通常 0 或 1 个；延后批次可能在之后补发）。
  List<DirectorTrigger> step({
    required double combatSeconds,
    required Vec2 playerPosition,
    required int playerHp,
    required int hpDamageInLast15s,
    required int upgradeCount,
    required int activeEnemyCount,
  }) {
    // ---- 1. 到点评估动态校正 ----
    if (combatSeconds >= _nextEvaluationAt) {
      _nextEvaluationAt = combatSeconds + evaluateIntervalSeconds;
      _evaluate(
        atSecond: combatSeconds,
        playerHp: playerHp,
        hpDamageInLast15s: hpDamageInLast15s,
        upgradeCount: upgradeCount,
      );
    }

    final triggers = <DirectorTrigger>[];

    // ---- 2. 先处理被延后的批次 ----
    final deferred = _deferred;
    if (deferred != null) {
      final centerX = selectSpawnCenterX(
        playerX: playerPosition.x,
        desiredCenterX: deferred.desiredCenterX,
      );
      if (centerX != null) {
        _deferred = null;
        triggers.add(
          DirectorTrigger(
            row: deferred.row,
            spawns: deferred.spawns,
            centerX: centerX,
          ),
        );
      } else if (combatSeconds - deferred.since >= deferMaxSeconds) {
        // 超过最大延后时间：用最远的合法点兜底，绝不允许贴脸生成。
        _deferred = null;
        final fallback = _farthestPointFrom(playerPosition.x);
        triggers.add(
          DirectorTrigger(
            row: deferred.row,
            spawns: deferred.spawns,
            centerX: fallback,
            deferredReason: '延后超过 ${deferMaxSeconds}s，改用最远生成点',
          ),
        );
      }
      // 延后期间不再推进新行，避免同一秒堆叠两批。
      if (triggers.isNotEmpty || _deferred != null) {
        return triggers;
      }
    }

    // ---- 3. 推进到点的波次行 ----
    while (_nextRowIndex < _rows.length &&
        _rows[_nextRowIndex].startSecond <= combatSeconds) {
      final row = _rows[_nextRowIndex];
      _nextRowIndex++;

      if (row.isRiskGate || row.isBossEntry) {
        // 风险门与 Boss 入场不由生成流程处理，交由上层状态机。
        triggers.add(DirectorTrigger(row: row, spawns: const [], centerX: null));
        continue;
      }
      if (row.spawns.isEmpty) {
        continue;
      }

      final adjusted = _applyAdjustment(row);
      if (adjusted.isEmpty) {
        continue;
      }

      final desired = _desiredCenterX(row);
      final centerX = selectSpawnCenterX(
        playerX: playerPosition.x,
        desiredCenterX: desired,
      );

      if (centerX == null) {
        // 所有合法点都太靠近玩家：延后，绝不可贴脸生成。
        _deferred = _DeferredBatch(
          row: row,
          spawns: adjusted,
          desiredCenterX: desired,
          since: combatSeconds,
        );
        break;
      }

      triggers.add(
        DirectorTrigger(row: row, spawns: adjusted, centerX: centerX),
      );
      break; // 一个逻辑步只处理一行，避免同一帧堆叠多批
    }

    // 动态校正只作用于两批，批次出队时递减。
    if (triggers.isNotEmpty && _pendingBatches > 0) {
      _pendingBatches--;
      if (_pendingBatches == 0) {
        _pendingScoutDelta = 0;
        _pendingWingDelta = 0;
      }
    }

    return triggers;
  }

  /// 选择安全的生成中心 x。
  ///
  /// 只考虑距玩家当前 x ≥ [minDistanceFromPlayerX] 的点；
  /// 在合法点中选取最接近 [desiredCenterX] 的一个（结果确定，无随机）。
  /// 没有任何合法点时返回 null，由调用方延后。
  double? selectSpawnCenterX({
    required double playerX,
    required double desiredCenterX,
  }) {
    double? best;
    var bestDistance = double.infinity;
    for (final point in spawnXPoints) {
      if ((point - playerX).abs() < minDistanceFromPlayerX) {
        continue;
      }
      final distance = (point - desiredCenterX).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = point;
      }
    }
    return best;
  }

  double _farthestPointFrom(double playerX) {
    var best = spawnXPoints.first;
    var bestDistance = -1.0;
    for (final point in spawnXPoints) {
      final distance = (point - playerX).abs();
      if (distance > bestDistance) {
        bestDistance = distance;
        best = point;
      }
    }
    return best;
  }

  double _desiredCenterX(WaveRow row) {
    for (final spawn in row.spawns) {
      final center = spawn.centerX;
      if (center != null) {
        return center;
      }
    }
    return 960; // 缺省居中
  }

  /// 应用待生效的动态校正，只改普通 Scout/Wing 的数量。
  List<WaveSpawn> _applyAdjustment(WaveRow row) {
    if (!row.dynamicAdjustmentAllowed) {
      return row.spawns;
    }
    if (_pendingBatches <= 0 ||
        (_pendingScoutDelta == 0 && _pendingWingDelta == 0)) {
      return row.spawns;
    }

    final result = <WaveSpawn>[];
    final hasScout = row.spawns.any((s) => s.enemyId == 'EN-SCOUT');
    final hasWing = row.spawns.any((s) => s.enemyId == 'EN-WING');

    // 减少时：优先减 Scout，无 Scout 才减 Wing。
    // 增加时：只加 Scout。
    var scoutDelta = _pendingScoutDelta;
    var wingDelta = _pendingWingDelta;
    if (scoutDelta < 0 && !hasScout && hasWing) {
      wingDelta += scoutDelta;
      scoutDelta = 0;
    }
    if (scoutDelta > 0 && !hasScout) {
      scoutDelta = 0; // 不新增敌种，只在已有 Scout 的批次上加
    }

    var total = 0;
    for (final spawn in row.spawns) {
      total += spawn.count;
    }
    final wouldBeTotal = total + scoutDelta + wingDelta;
    if (wouldBeTotal > totalEnemyCap) {
      final overflow = wouldBeTotal - totalEnemyCap;
      scoutDelta -= overflow;
      if (scoutDelta < 0) {
        wingDelta += scoutDelta;
        scoutDelta = 0;
      }
    }

    for (final spawn in row.spawns) {
      if (spawn.isElite) {
        result.add(spawn); // 精英永不被校正
        continue;
      }
      if (spawn.enemyId == 'EN-SCOUT') {
        result.add(spawn.withCount(spawn.count + scoutDelta));
      } else if (spawn.enemyId == 'EN-WING') {
        result.add(spawn.withCount(spawn.count + wingDelta));
      } else {
        result.add(spawn);
      }
    }
    return result.where((s) => s.count > 0).toList(growable: false);
  }

  void _evaluate({
    required double atSecond,
    required int playerHp,
    required int hpDamageInLast15s,
    required int upgradeCount,
  }) {
    final reduce = playerHp <= reduceHpAtOrBelow ||
        hpDamageInLast15s >= reduceDamageInLast15s;
    if (reduce) {
      _pendingScoutDelta = -1;
      _pendingWingDelta = 0;
      _pendingBatches = 2;
      decisions.add(
        AdjustmentDecision(
          kind: AdjustmentKind.reduce,
          atSecond: atSecond,
          scoutDelta: -1,
          reason: playerHp <= reduceHpAtOrBelow
              ? 'HP ≤ $reduceHpAtOrBelow'
              : '近 15 秒 HP 伤害 ≥ $reduceDamageInLast15s',
        ),
      );
      return;
    }

    final minimum = minimumUpgradesAt(atSecond);
    final increase = playerHp >= increaseHpAtOrAbove &&
        hpDamageInLast15s == 0 &&
        upgradeCount >= minimum;
    if (increase) {
      _pendingScoutDelta = 1;
      _pendingWingDelta = 0;
      _pendingBatches = 2;
      decisions.add(
        AdjustmentDecision(
          kind: AdjustmentKind.increase,
          atSecond: atSecond,
          scoutDelta: 1,
          reason: 'HP ≥ $increaseHpAtOrAbove 且未受伤且升级数 ≥ $minimum',
        ),
      );
      return;
    }

    decisions.add(
      AdjustmentDecision(
        kind: AdjustmentKind.none,
        atSecond: atSecond,
        reason: '不满足增减条件',
      ),
    );
  }
}

class _DeferredBatch {
  _DeferredBatch({
    required this.row,
    required this.spawns,
    required this.desiredCenterX,
    required this.since,
  });

  final WaveRow row;
  final List<WaveSpawn> spawns;
  final double desiredCenterX;
  final double since;
}
