// ================================================================
// lib/game/domain/damage.dart —— 伤害意图与结算
//
// **架构位置**：Domain（纯规则） —— 无 I/O、无 Flutter 依赖、不持有渲染状态；由 `GameRuntime` 驱动，
//   产出**意图/事件**，不直接改动 Core 的实体集合。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：确定性（同 seed + 同输入必同结果）· 表现无关（不得因"要画什么"改变规则）。
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §2.2
//       产品基线 §3.3（伤害、护盾和得分）
//
// 三条不可动摇的契约：
//   1. **伤害顺序固定**：无敌判定 → 护盾吸收 → HP → 死亡；
//   2. **同源实体在 0.25 秒内只可伤害玩家一次**（命中闸门）；
//   3. **只有 DamageSystem 可以更改 HP**（协议 §2.2）。
//
// 因此本文件是 HP 的唯一入口：任何系统想造成伤害都必须产出
// [DamageIntent]，由这里合并、过滤、结算。
// ================================================================

import 'values.dart';

/// 伤害类型。
enum DamageType {
  /// 标准伤害：先扣护盾，溢出部分扣 HP。
  standard,

  /// 突破伤害：**穿透护盾**直接扣 HP（产品基线 §5 的越界规则）。
  breach,
}

/// 一次伤害意图（协议 §2.2 规定的最低字段）。
final class DamageIntent {
  const DamageIntent({
    required this.sourceId,
    required this.targetId,
    required this.damageType,
    required this.rawDamage,
    required this.frameIndex,
    required this.hitKey,
    this.isCritical = false,
    this.attackId,
    this.sourceType,
  });

  final EntityId sourceId;
  final EntityId targetId;
  final DamageType damageType;
  final int rawDamage;
  final int frameIndex;

  /// 去重键。同一帧内相同 `hitKey` 的意图只结算一次 ——
  /// 这是 T-DMG-01「同一颗投射物同帧接触同敌人两次只造成一次伤害」的实现基础。
  final String hitKey;

  final bool isCritical;

  /// 攻击标识（例如 `sniper_line`、`boss_fan`），用于表现层路由与调试。
  final String? attackId;

  /// 来源类别（`enemy` / `boss` / `hazard` / `player`），用于表现层与指标。
  final String? sourceType;

  @override
  String toString() =>
      'DamageIntent($sourceId → $targetId, ${damageType.name}, $rawDamage, key=$hitKey)';
}

/// 一次伤害结算的结果。
final class DamageResult {
  const DamageResult({
    required this.shieldDamage,
    required this.hpDamage,
    required this.blockedByInvulnerability,
    required this.blockedByGate,
    required this.killed,
    required this.hpAfter,
    required this.shieldAfter,
  });

  static const DamageResult none = DamageResult(
    shieldDamage: 0,
    hpDamage: 0,
    blockedByInvulnerability: false,
    blockedByGate: false,
    killed: false,
    hpAfter: 0,
    shieldAfter: 0,
  );

  final int shieldDamage;
  final int hpDamage;

  /// 被无敌帧完全挡下（冲刺期间）。
  final bool blockedByInvulnerability;

  /// 被命中闸门或同帧去重挡下。
  final bool blockedByGate;

  final bool killed;
  final int hpAfter;
  final int shieldAfter;

  bool get dealtAnyDamage => shieldDamage > 0 || hpDamage > 0;
  int get totalDamage => shieldDamage + hpDamage;
}

/// 命中闸门：实现「同源 0.25 秒内只结算一次」与「同帧同键只结算一次」。
class HitGate {
  HitGate({this.sameSourceIntervalSeconds = 0.25});

  final double sameSourceIntervalSeconds;

  final Map<String, double> _lastHitAt = <String, double>{};
  final Set<String> _resolvedThisFrame = <String>{};
  int _frameIndex = -1;

  /// 进入新的逻辑帧：清空同帧去重集合。
  void beginFrame(int frameIndex) {
    if (frameIndex != _frameIndex) {
      _frameIndex = frameIndex;
      _resolvedThisFrame.clear();
    }
  }

  /// 是否允许该意图通过。
  ///
  /// [gateKey] 通常取 `sourceId`（同源间隔）；
  /// [hitKey] 取「投射物 + 目标」组合（同帧去重）。
  bool allows({
    required String gateKey,
    required String hitKey,
    required double nowSeconds,
  }) {
    if (_resolvedThisFrame.contains(hitKey)) {
      return false;
    }
    final last = _lastHitAt[gateKey];
    if (last != null && nowSeconds - last < sameSourceIntervalSeconds) {
      return false;
    }
    _resolvedThisFrame.add(hitKey);
    _lastHitAt[gateKey] = nowSeconds;
    return true;
  }

  void reset() {
    _lastHitAt.clear();
    _resolvedThisFrame.clear();
    _frameIndex = -1;
  }
}

/// 玩家受伤的结算器 —— 唯一可以更改玩家 HP / 护盾的地方。
class DamageSystem {
  DamageSystem({HitGate? gate}) : gate = gate ?? HitGate();

  final HitGate gate;

  /// 合并同一帧内针对同一目标的多个意图。
  ///
  /// 产品基线 §3.1：「同一帧多次命中应合并为可解释的伤害事件，
  /// 避免单个弹幕多次扣血」。合并后的原始伤害为各意图之和，
  /// 但只要其中任意一条是 `breach`，整体按穿透处理（突破伤害优先）。
  static List<DamageIntent> mergeSameFrame(List<DamageIntent> intents) {
    final byTarget = <EntityId, List<DamageIntent>>{};
    for (final intent in intents) {
      byTarget.putIfAbsent(intent.targetId, () => <DamageIntent>[]).add(intent);
    }

    final merged = <DamageIntent>[];
    for (final entry in byTarget.entries) {
      final group = entry.value;
      if (group.length == 1) {
        merged.add(group.first);
        continue;
      }
      // 同帧同键只保留第一条（例如同一投射物重复接触）。
      final seenKeys = <String>{};
      final unique = group.where((i) => seenKeys.add(i.hitKey)).toList();
      if (unique.length == 1) {
        merged.add(unique.first);
        continue;
      }
      merged.add(
        DamageIntent(
          sourceId: unique.first.sourceId,
          targetId: entry.key,
          damageType: unique.any((i) => i.damageType == DamageType.breach)
              ? DamageType.breach
              : DamageType.standard,
          rawDamage: unique.fold<int>(0, (sum, i) => sum + i.rawDamage),
          frameIndex: unique.first.frameIndex,
          hitKey: unique.map((i) => i.hitKey).join('+'),
          isCritical: unique.any((i) => i.isCritical),
          attackId: unique.first.attackId,
          sourceType: unique.first.sourceType,
        ),
      );
    }
    return merged;
  }

  /// 结算一次针对玩家的伤害。
  ///
  /// 严格按产品基线 §3.3 的顺序：无敌 → 护盾 → HP → 死亡。
  DamageResult applyToPlayer({
    required DamageIntent intent,
    required Health health,
    required ShieldPool shield,
    required bool invulnerable,
    required double nowSeconds,
  }) {
    gate.beginFrame(intent.frameIndex);

    // 1) 无敌判定：冲刺无敌帧内完全免疫，且**不消耗闸门**。
    if (invulnerable) {
      return DamageResult(
        shieldDamage: 0,
        hpDamage: 0,
        blockedByInvulnerability: true,
        blockedByGate: false,
        killed: false,
        hpAfter: health.current,
        shieldAfter: shield.current,
      );
    }

    // 2) 命中闸门。
    final allowed = gate.allows(
      gateKey: intent.sourceId.toString(),
      hitKey: '${intent.hitKey}|${intent.targetId}',
      nowSeconds: nowSeconds,
    );
    if (!allowed) {
      return DamageResult(
        shieldDamage: 0,
        hpDamage: 0,
        blockedByInvulnerability: false,
        blockedByGate: true,
        killed: false,
        hpAfter: health.current,
        shieldAfter: shield.current,
      );
    }

    // 3) 护盾吸收（突破伤害跳过）。
    var shieldDamage = 0;
    var remaining = intent.rawDamage;
    if (intent.damageType == DamageType.standard) {
      shieldDamage = shield.absorb(remaining);
      remaining -= shieldDamage;
    }

    // 4) HP。
    final hpDamage = health.applyDamage(remaining);

    return DamageResult(
      shieldDamage: shieldDamage,
      hpDamage: hpDamage,
      blockedByInvulnerability: false,
      blockedByGate: false,
      killed: health.isDead,
      hpAfter: health.current,
      shieldAfter: shield.current,
    );
  }

  void reset() => gate.reset();
}

/// 护盾恢复（产品基线 §3.3）。
///
/// 「最后一次**实际扣除 HP 或护盾**后 8.0 秒开始；每秒 +3；
///   受伤立即重置计时」。这里把计时器与恢复集中在一处，
/// 避免各系统各自决定何时回盾。
class ShieldRegen {
  ShieldRegen({
    required this.delaySeconds,
    required this.perSecond,
  }) : _timer = delaySeconds;

  final double delaySeconds;
  final double perSecond;

  double _timer;
  double _fractional = 0;

  /// 距离开始恢复还剩多少秒（0 表示正在恢复）。
  double get remainingDelay => _timer;
  bool get isRegenerating => _timer <= 0;

  /// 受到任何**实际**伤害时调用：重置延迟。
  void notifyDamaged() {
    _timer = delaySeconds;
    _fractional = 0;
  }

  /// 每逻辑步推进。返回本步实际恢复的护盾点数。
  int tick(double dt, ShieldPool shield) {
    if (dt <= 0) {
      return 0;
    }
    if (_timer > 0) {
      _timer -= dt;
      if (_timer > 0) {
        return 0;
      }
    }
    if (shield.isFull) {
      return 0;
    }
    _fractional += perSecond * dt;
    final whole = _fractional.floor();
    if (whole <= 0) {
      return 0;
    }
    _fractional -= whole;
    return shield.restore(whole);
  }

  void reset() {
    _timer = delaySeconds;
    _fractional = 0;
  }
}
