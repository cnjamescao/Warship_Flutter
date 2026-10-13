// ================================================================
// lib/game/domain/player_system.dart —— 玩家移动、冲刺与生存
// ================================================================
// 依据：产品基线 §3.3（冲刺方向与碰撞）、§3.4（坐标与判定几何）
//
// 逐条对应的固定规则：
//   * 最大移速 340 px/s；**不使用惯性**，输入归零立即停止；
//   * 冲刺 2 层、每层 6.0 s、位移 0.22 s / 固定 360 px、无敌 0.22 s、
//     结束锁定 0.12 s；
//   * 冲刺方向：按下瞬间的移动向量 → 否则最近 0.5 s 内最后一个非零方向
//     → 否则向上；
//   * 冲刺路径被世界边界截断，不可穿出战场；
//   * 冲刺期间忽略敌方伤害与阻挡，但**不对敌人造成伤害**；
//   * 中心活动范围 x=30..1890、y=30..1050。
// ================================================================

import '../core/input_frame.dart';
import 'damage.dart';
import 'values.dart';

/// 玩家数值（从 `player.json` 映射而来）。
///
/// 放在 domain 而不是 content 是刻意的：domain 只接收值对象，
/// 由加载边界负责把 JSON 映射成本类型（技术架构 §1 的依赖方向）。
class PlayerTuning {
  const PlayerTuning({
    required this.spawnPosition,
    required this.moveSpeed,
    required this.bodyRadius,
    required this.bounds,
    required this.hpMax,
    required this.shieldMax,
    required this.shieldRegenDelaySeconds,
    required this.shieldRegenPerSecond,
    required this.dashMaxCharges,
    required this.dashRechargeSeconds,
    required this.dashDurationSeconds,
    required this.dashDistance,
    required this.dashInvulnerableSeconds,
    required this.dashEndLockSeconds,
    required this.dashDirectionFallbackWindowSeconds,
  });

  final Vec2 spawnPosition;
  final double moveSpeed;
  final double bodyRadius;
  final WorldBounds bounds;
  final int hpMax;
  final int shieldMax;
  final double shieldRegenDelaySeconds;
  final double shieldRegenPerSecond;
  final int dashMaxCharges;
  final double dashRechargeSeconds;
  final double dashDurationSeconds;
  final double dashDistance;
  final double dashInvulnerableSeconds;
  final double dashEndLockSeconds;
  final double dashDirectionFallbackWindowSeconds;

  /// 冲刺等效速度：固定距离 / 固定时长。
  double get dashSpeed => dashDistance / dashDurationSeconds;

  /// 从 `player.json` 的结构映射。非法字段由内容校验器提前拦下，
  /// 这里只做保守取值。
  factory PlayerTuning.fromConfig(Map<String, Object?> config) {
    final spawn = (config['spawnPosition'] as List?) ?? const <Object?>[960, 900];
    final hitbox = (config['bodyHitbox'] as Map?) ?? const <String, Object?>{};
    final bounds = (config['worldBounds'] as Map?) ?? const <String, Object?>{};
    final health = (config['health'] as Map?) ?? const <String, Object?>{};
    final shield = (config['shield'] as Map?) ?? const <String, Object?>{};
    final dash = (config['dash'] as Map?) ?? const <String, Object?>{};

    double num2(Object? value, double fallback) =>
        value is num ? value.toDouble() : fallback;

    return PlayerTuning(
      spawnPosition: Vec2(
        num2(spawn.isNotEmpty ? spawn[0] : null, 960),
        num2(spawn.length > 1 ? spawn[1] : null, 900),
      ),
      moveSpeed: num2(config['moveSpeed'], 340),
      bodyRadius: num2(hitbox['radius'], 30),
      bounds: WorldBounds(
        minX: num2(bounds['minX'], 30),
        maxX: num2(bounds['maxX'], 1890),
        minY: num2(bounds['minY'], 30),
        maxY: num2(bounds['maxY'], 1050),
      ),
      hpMax: (health['max'] as num?)?.toInt() ?? 100,
      shieldMax: (shield['max'] as num?)?.toInt() ?? 30,
      shieldRegenDelaySeconds: num2(shield['regenDelaySeconds'], 8.0),
      shieldRegenPerSecond: num2(shield['regenPerSecond'], 3),
      dashMaxCharges: (dash['maxCharges'] as num?)?.toInt() ?? 2,
      dashRechargeSeconds: num2(dash['rechargeSeconds'], 6.0),
      dashDurationSeconds: num2(dash['durationSeconds'], 0.22),
      dashDistance: num2(dash['distance'], 360),
      dashInvulnerableSeconds: num2(dash['invulnerableSeconds'], 0.22),
      dashEndLockSeconds: num2(dash['endLockSeconds'], 0.12),
      dashDirectionFallbackWindowSeconds:
          num2(dash['directionFallbackWindowSeconds'], 0.5),
    );
  }
}

/// 玩家实体状态。
class PlayerState {
  PlayerState({required this.tuning})
    : position = tuning.spawnPosition,
      health = Health(max: tuning.hpMax),
      shield = ShieldPool(max: tuning.shieldMax),
      dash = DashState(
        maxCharges: tuning.dashMaxCharges,
        rechargeSeconds: tuning.dashRechargeSeconds,
      ) {
    shieldRegen = ShieldRegen(
      delaySeconds: tuning.shieldRegenDelaySeconds,
      perSecond: tuning.shieldRegenPerSecond,
    );
  }

  final PlayerTuning tuning;

  Vec2 position;
  final Health health;
  final ShieldPool shield;
  final DashState dash;
  late final ShieldRegen shieldRegen;

  /// 最近一次**非零**移动方向（用于冲刺方向回退）。
  Vec2 lastMoveDirection = Vec2.zero;

  /// 最近一次非零移动发生的逻辑时间（秒）。
  double? lastMoveDirectionAt;

  bool get isAlive => !health.isDead;

  /// 冲刺是否处于无敌帧（当前实现与冲刺位移同长）。
  bool get isInvulnerable => dash.invulnerable;

  double get dashRemainingSeconds =>
      dash.isDashing ? dashDurationLeft : 0;

  /// 本次冲刺剩余时长（秒）。
  double dashDurationLeft = 0;

  CircleHitbox get hitbox => CircleHitbox(position, tuning.bodyRadius);

  void reset() {
    position = tuning.spawnPosition;
    health.current = tuning.hpMax;
    shield.max = tuning.shieldMax;
    shield.current = tuning.shieldMax;
    dash.reset();
    shieldRegen.reset();
    lastMoveDirection = Vec2.zero;
    lastMoveDirectionAt = null;
    dashDurationLeft = 0;
  }
}

/// 一次 `PlayerSystem.step` 产生的副作用，供事件层消费。
class PlayerStepResult {
  const PlayerStepResult({
    this.dashStarted = false,
    this.dashEnded = false,
    this.dashDirection = Vec2.zero,
    this.dashRechargeReady = false,
    this.shieldRestored = 0,
    this.truncatedByBounds = false,
  });

  final bool dashStarted;
  final bool dashEnded;
  final Vec2 dashDirection;
  final bool dashRechargeReady;
  final int shieldRestored;

  /// 本次冲刺是否因撞到世界边界而被截断。
  final bool truncatedByBounds;
}

/// 玩家移动与冲刺规则。纯 Dart，无副作用（只改传入的 [PlayerState]）。
class PlayerSystem {
  /// 推进一个逻辑步。
  ///
  /// 调用方必须在进入本步前锁定 [input]（技术架构 §4 第 1、4 步）。
  PlayerStepResult step({
    required PlayerState state,
    required InputFrame input,
    required double dt,
    required double elapsedSeconds,
  }) {
    var dashStarted = false;
    var dashEnded = false;
    var truncated = false;
    var dashDirection = Vec2.zero;

    // ---- 1. 锁定移动方向；无输入立即停止（无惯性） ----
    final move = input.normalizedMove;
    if (input.hasMoveInput) {
      state.lastMoveDirection = move;
      state.lastMoveDirectionAt = elapsedSeconds;
    }

    // ---- 2. 冲刺启动 ----
    if (input.dashRequested && state.dash.canDash) {
      dashDirection = _resolveDashDirection(state, input, elapsedSeconds);
      final started = state.dash.consume(
        dashDirection,
        distance: state.tuning.dashDistance,
      );
      if (started) {
        dashStarted = true;
        state.dashDurationLeft = state.tuning.dashDurationSeconds;
        state.dash.invulnerable = true;
      }
    }

    // ---- 3. 位移 ----
    if (state.dash.isDashing) {
      // 冲刺中：沿锁定方向按等效速度推进，并在边界处截断。
      final stepDistance = state.tuning.dashSpeed * dt;
      final travel = stepDistance < state.dash.remainingDistance
          ? stepDistance
          : state.dash.remainingDistance;
      final desired = state.position + state.dash.direction * travel;
      final clamped = state.tuning.bounds.clamp(desired);
      if (clamped != desired) {
        truncated = true;
        state.dash.remainingDistance = 0;
      } else {
        state.dash.remainingDistance -= travel;
      }
      state.position = clamped;

      // 冲刺时长与无敌帧同步推进。
      state.dashDurationLeft -= dt;
      if (state.dashDurationLeft <= 0) {
        state.dashDurationLeft = 0;
        state.dash.remainingDistance = 0;
        state.dash.invulnerable = false;
        state.dash.endLockRemaining = state.tuning.dashEndLockSeconds;
        dashEnded = true;
      }
    } else {
      // 常规移动：输入归零立即停止，不使用惯性。
      if (input.hasMoveInput) {
        state.position = state.tuning.bounds.clamp(
          state.position + move * (state.tuning.moveSpeed * dt),
        );
      }
      if (state.dash.endLockRemaining > 0) {
        state.dash.endLockRemaining -= dt;
        if (state.dash.endLockRemaining < 0) {
          state.dash.endLockRemaining = 0;
        }
      }
    }

    // ---- 4. 冲刺充能 ----
    final rechargeReady = state.dash.tick(dt);

    // ---- 5. 护盾恢复 ----
    final restored = state.shieldRegen.tick(dt, state.shield);

    return PlayerStepResult(
      dashStarted: dashStarted,
      dashEnded: dashEnded,
      dashDirection: dashDirection,
      dashRechargeReady: rechargeReady,
      shieldRestored: restored,
      truncatedByBounds: truncated,
    );
  }

  /// 冲刺方向：当前输入 → 最近 0.5 s 内最后一个非零方向 → 向上。
  Vec2 _resolveDashDirection(
    PlayerState state,
    InputFrame input,
    double elapsedSeconds,
  ) {
    if (input.hasMoveInput) {
      return input.normalizedMove;
    }
    final lastAt = state.lastMoveDirectionAt;
    final window = state.tuning.dashDirectionFallbackWindowSeconds;
    if (lastAt != null &&
        elapsedSeconds - lastAt <= window &&
        state.lastMoveDirection != Vec2.zero) {
      return state.lastMoveDirection;
    }
    // 从未移动（或已超出回退窗口）：向上。
    return const Vec2(0, -1);
  }
}
