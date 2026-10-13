// ================================================================
// lib/game/domain/enemy_system.dart —— 敌人移动、攻击与越界
// ================================================================
// 依据：产品基线 §5（敌人、掉落与精英）
//
// 逐条对应的固定规则：
//   * Scout 180 px/s 下行 + 以自身初始 x 为中心、振幅 80、周期 1.6 s 正弦横摆；
//   * Wing 140 px/s，V 队形偏移 (-100,40)/(0,0)/(100,40)，每 1.8 s 射 1 弹；
//   * Sniper 70 px/s，移动到 y=260 后停驻，0.75 s 线形预警后射高速弹，冷却 3.0 s；
//   * Bomber 55 px/s，每 3.5 s 在自身正下方投半径 90 危险区；
//   * Shield 85 px/s，正面锥 120° 减伤 75%，每 2.5 s 三连点射；
//   * 所有带冷却攻击的第一发在实体**完全进入**（中心 y≥0）后等完整冷却；
//   * 越界：中心越过 y=1140 发生一次突破（移除、无奖励、穿透护盾扣血）；
//     中心首次进入 y=920 显示逃逸预警。
// ================================================================

import 'dart:math' as math;

import 'values.dart';

/// 敌人移动档案。
class MoveProfile {
  const MoveProfile({
    required this.kind,
    required this.speed,
    this.amplitude = 0,
    this.periodSeconds = 0,
    this.formationOffsets = const <Vec2>[],
    this.holdY,
  });

  /// `sineDescent` / `formationDescent` / `descentThenHold` / `straightDescent`。
  final String kind;
  final double speed;
  final double amplitude;
  final double periodSeconds;

  /// 队形相对中心的偏移（仅 `formationDescent`）。
  final List<Vec2> formationOffsets;

  /// 停驻的 y（仅 `descentThenHold`）。
  final double? holdY;

  static MoveProfile fromConfig(Map<String, Object?>? config) {
    if (config == null) {
      return const MoveProfile(kind: 'straightDescent', speed: 0);
    }
    double num2(Object? v, [double fallback = 0]) =>
        v is num ? v.toDouble() : fallback;
    return MoveProfile(
      kind: config['kind'] as String? ?? 'straightDescent',
      speed: num2(config['speed']),
      amplitude: num2(config['amplitude']),
      periodSeconds: num2(config['periodSeconds']),
      holdY: config['holdY'] is num
          ? (config['holdY'] as num).toDouble()
          : null,
      formationOffsets: ((config['formationOffsets'] as List?) ?? const [])
          .whereType<List>()
          .map(
            (pair) => Vec2(
              num2(pair.isNotEmpty ? pair[0] : null),
              num2(pair.length > 1 ? pair[1] : null),
            ),
          )
          .toList(growable: false),
    );
  }
}

/// 投射物规格。
class ProjectileSpec {
  const ProjectileSpec({
    required this.damage,
    required this.speed,
    required this.radius,
    required this.lifetimeSeconds,
    this.assetId,
  });

  final int damage;
  final double speed;
  final double radius;
  final double lifetimeSeconds;
  final String? assetId;
}

/// 危险区规格（Bomber）。
class HazardSpec {
  const HazardSpec({
    required this.radius,
    required this.activeSeconds,
    required this.tickSeconds,
    required this.damagePerTick,
    this.assetId,
  });

  final double radius;
  final double activeSeconds;
  final double tickSeconds;
  final int damagePerTick;
  final String? assetId;
}

/// 攻击档案。
class AttackProfile {
  const AttackProfile({
    required this.attackId,
    required this.intervalSeconds,
    required this.telegraphSeconds,
    this.telegraphShape = 'none',
    this.telegraphAssetId,
    this.projectile,
    this.hazard,
    this.burstCount = 1,
    this.burstAngleOffsetsDegrees = const <double>[0],
    this.dropAt = 'self',
    this.aim = 'playerCurrentPosition',
  });

  final String attackId;
  final double intervalSeconds;
  final double telegraphSeconds;
  final String telegraphShape;
  final String? telegraphAssetId;
  final ProjectileSpec? projectile;
  final HazardSpec? hazard;
  final int burstCount;
  final List<double> burstAngleOffsetsDegrees;
  final String dropAt;
  final String aim;

  static AttackProfile? fromConfig(Map<String, Object?>? config) {
    if (config == null) {
      return null;
    }
    double num2(Object? v, [double fallback = 0]) =>
        v is num ? v.toDouble() : fallback;
    final projectile = config['projectile'] as Map?;
    final hazard = config['hazard'] as Map?;
    return AttackProfile(
      attackId: config['attackId'] as String? ?? 'unknown',
      intervalSeconds: num2(config['intervalSeconds']),
      telegraphSeconds: num2(config['telegraphSeconds']),
      telegraphShape: config['telegraphShape'] as String? ?? 'none',
      telegraphAssetId: config['telegraphAssetId'] as String?,
      burstCount: (config['burstCount'] as num?)?.toInt() ?? 1,
      burstAngleOffsetsDegrees:
          ((config['burstAngleOffsetsDegrees'] as List?) ?? const [0])
              .whereType<num>()
              .map((n) => n.toDouble())
              .toList(growable: false),
      dropAt: config['dropAt'] as String? ?? 'self',
      aim: config['aim'] as String? ?? 'playerCurrentPosition',
      projectile: projectile == null
          ? null
          : ProjectileSpec(
              damage: (projectile['damage'] as num?)?.toInt() ?? 0,
              speed: num2(projectile['speed']),
              radius: num2(projectile['radius']),
              lifetimeSeconds: num2(projectile['lifetimeSeconds']),
              assetId: projectile['assetId'] as String?,
            ),
      hazard: hazard == null
          ? null
          : HazardSpec(
              radius: num2(hazard['radius']),
              activeSeconds: num2(hazard['activeSeconds']),
              tickSeconds: num2(hazard['tickSeconds']),
              damagePerTick: (hazard['damagePerTick'] as num?)?.toInt() ?? 0,
              assetId: hazard['assetId'] as String?,
            ),
    );
  }
}

/// 敌人配置（从 `enemies.json` 映射）。
class EnemyTuning {
  const EnemyTuning({
    required this.id,
    required this.hp,
    required this.radius,
    required this.contactDamage,
    required this.xp,
    required this.score,
    required this.spawnWindowStart,
    required this.spawnWindowEnd,
    required this.move,
    required this.breachDamage,
    required this.bodyAssetId,
    this.attack,
    this.frontShieldReduction = 0,
    this.frontShieldFacing = const Vec2(0, 1),
  });

  final String id;
  final int hp;
  final double radius;
  final int contactDamage;
  final int xp;
  final int score;
  final int spawnWindowStart;
  final int spawnWindowEnd;
  final MoveProfile move;
  final AttackProfile? attack;
  final int breachDamage;
  final String? bodyAssetId;

  /// 正面减伤（Shield 为 0.75）。
  final double frontShieldReduction;

  /// 正面朝向；产品基线 §3.4 固定为 (0,1)（向下）。
  final Vec2 frontShieldFacing;

  bool get hasFrontShield => frontShieldReduction > 0;

  static EnemyTuning fromConfig(Map<String, Object?> config) {
    final hitbox = (config['bodyHitbox'] as Map?) ?? const <String, Object?>{};
    final window = (config['spawnWindow'] as Map?) ?? const <String, Object?>{};
    final shield = (config['frontShield'] as Map?) ?? const <String, Object?>{};
    final assets = (config['assets'] as Map?) ?? const <String, Object?>{};
    final facing = (shield['facing'] as List?) ?? const [0, 1];

    return EnemyTuning(
      id: config['id'] as String? ?? 'UNKNOWN',
      hp: (config['hp'] as num?)?.toInt() ?? 1,
      radius: (hitbox['radius'] as num?)?.toDouble() ?? 30,
      contactDamage: (config['contactDamage'] as num?)?.toInt() ?? 0,
      xp: (config['xp'] as num?)?.toInt() ?? 0,
      score: (config['score'] as num?)?.toInt() ?? 0,
      spawnWindowStart: (window['startSecond'] as num?)?.toInt() ?? 0,
      spawnWindowEnd: (window['endSecond'] as num?)?.toInt() ?? 150,
      move: MoveProfile.fromConfig(
        (config['moveProfile'] as Map?)?.cast<String, Object?>(),
      ),
      attack: AttackProfile.fromConfig(
        (config['attackProfile'] as Map?)?.cast<String, Object?>(),
      ),
      breachDamage: (config['breachDamage'] as num?)?.toInt() ?? 8,
      bodyAssetId: assets['bodyAssetId'] as String?,
      frontShieldReduction:
          (shield['damageReduction'] as num?)?.toDouble() ?? 0,
      frontShieldFacing: Vec2(
        facing.isNotEmpty && facing[0] is num
            ? (facing[0] as num).toDouble()
            : 0,
        facing.length > 1 && facing[1] is num
            ? (facing[1] as num).toDouble()
            : 1,
      ),
    );
  }
}

/// 精英词缀。
class EliteAffix {
  const EliteAffix({
    required this.id,
    this.moveSpeedMultiplier = 1.0,
    this.shieldGrantAmount = 0,
    this.shieldGrantIntervalSeconds = 0,
    this.extraProjectiles = 0,
    this.telegraphExtraSeconds = 0,
  });

  final String id;
  final double moveSpeedMultiplier;
  final int shieldGrantAmount;
  final double shieldGrantIntervalSeconds;
  final int extraProjectiles;
  final double telegraphExtraSeconds;

  static EliteAffix fromConfig(Map<String, Object?> config) => EliteAffix(
    id: config['id'] as String? ?? 'AFFIX-UNKNOWN',
    moveSpeedMultiplier:
        (config['moveSpeedMultiplier'] as num?)?.toDouble() ?? 1.0,
    shieldGrantAmount: (config['shieldGrantAmount'] as num?)?.toInt() ?? 0,
    shieldGrantIntervalSeconds:
        (config['shieldGrantIntervalSeconds'] as num?)?.toDouble() ?? 0,
    extraProjectiles: (config['extraProjectiles'] as num?)?.toInt() ?? 0,
    telegraphExtraSeconds:
        (config['telegraphExtraSeconds'] as num?)?.toDouble() ?? 0,
  );
}

/// 精英倍率（产品基线 §5）。
class EliteRules {
  const EliteRules({
    this.hpMultiplier = 6,
    this.xpMultiplier = 3,
    this.scoreMultiplier = 8,
    this.coreShieldRestore = 10,
    this.coreXpIfShieldFull = 15,
  });

  final int hpMultiplier;
  final int xpMultiplier;
  final int scoreMultiplier;
  final int coreShieldRestore;
  final int coreXpIfShieldFull;
}

/// 敌人运行时状态。
class EnemyState {
  EnemyState({
    required this.id,
    required this.tuning,
    required this.position,
    required this.spawnX,
    this.isElite = false,
    this.affix,
  }) : health = Health(max: _initialHp(tuning, isElite)),
       _shieldTimer = affix?.shieldGrantIntervalSeconds ?? 0;

  static int _initialHp(EnemyTuning tuning, bool isElite) =>
      tuning.hp * (isElite ? const EliteRules().hpMultiplier : 1);

  final EntityId id;
  final EnemyTuning tuning;
  final bool isElite;
  final EliteAffix? affix;
  final Health health;

  Vec2 position;

  /// 出生时的 x（Scout 的正弦横摆以它为中心）。
  final double spawnX;

  /// 已存活时间（秒）。
  double age = 0;

  /// 攻击冷却剩余（秒）；null 表示尚未开始计时。
  double? attackCooldown;

  /// 是否已完全进入逻辑世界（中心 y ≥ 0）。
  bool hasEntered = false;

  /// 是否已发出逃逸预警（y=920 只触发一次）。
  bool warnedBreach = false;

  /// 当前护盾（精英"护体"词缀）。
  int shield = 0;

  double _shieldTimer;

  bool get isDead => health.isDead;
  bool get isRanged => tuning.attack != null;

  CircleHitbox get hitbox => CircleHitbox(position, tuning.radius);

  /// 有效移动速度（含"加速"词缀）。
  double get effectiveSpeed =>
      tuning.move.speed * (affix?.moveSpeedMultiplier ?? 1.0);

  /// 有效预警时长（含"弹幕"词缀的延长）。
  double get effectiveTelegraphSeconds =>
      (tuning.attack?.telegraphSeconds ?? 0) +
      (affix?.telegraphExtraSeconds ?? 0);

  /// 有效投射物数量（含"弹幕"词缀）。
  int get effectiveProjectileCount =>
      (tuning.attack?.burstCount ?? 1) + (affix?.extraProjectiles ?? 0);

  /// 是否为移动受限（Sniper 停驻后不再下行）。
  bool get isHolding {
    final holdY = tuning.move.holdY;
    return holdY != null && position.y >= holdY;
  }
}

/// 一步的敌人系统输出。
class EnemyStepEvent {
  const EnemyStepEvent({
    this.attackRequests = const <EnemyAttackRequest>[],
    this.breached,
    this.breachWarning,
    this.shieldGranted = 0,
    this.telegraphStarted = false,
  });

  final List<EnemyAttackRequest> attackRequests;
  final EnemyState? breached;
  final EnemyState? breachWarning;
  final int shieldGranted;
  final bool telegraphStarted;
}

/// 一次攻击请求（由表现层与本步的投射物生成消费）。
class EnemyAttackRequest {
  const EnemyAttackRequest({
    required this.sourceId,
    required this.enemyId,
    required this.attackId,
    required this.origin,
    required this.aimTarget,
    required this.projectileCount,
    required this.angleOffsetsDegrees,
    required this.telegraphSeconds,
    this.projectile,
    this.hazard,
    this.dropAt,
  });

  final EntityId sourceId;
  final String enemyId;
  final String attackId;
  final Vec2 origin;
  final Vec2 aimTarget;
  final int projectileCount;
  final List<double> angleOffsetsDegrees;
  final double telegraphSeconds;
  final ProjectileSpec? projectile;
  final HazardSpec? hazard;
  final String? dropAt;
}

/// 敌人系统：移动、攻击计时与越界。
class EnemySystem {
  EnemySystem({required this.breachWarningY, required this.breachRemoveY});

  /// 逃逸预警线（产品基线 §5：y=920）。
  final double breachWarningY;

  /// 移除线（产品基线 §5：y=1140）。
  final double breachRemoveY;

  /// 生成一个敌人。[formationOffset] 用于 Wing 的 V 队形。
  EnemyState spawn({
    required EntityId id,
    required EnemyTuning tuning,
    required double spawnX,
    double spawnY = -80,
    Vec2 formationOffset = Vec2.zero,
    bool isElite = false,
    EliteAffix? affix,
    double ageOffset = 0,
  }) => EnemyState(
    id: id,
    tuning: tuning,
    position: Vec2(spawnX + formationOffset.x, spawnY + formationOffset.y),
    spawnX: spawnX,
    isElite: isElite,
    affix: affix,
  )..age = ageOffset;

  /// 推进一个敌人一个逻辑步。
  EnemyStepEvent step({
    required EnemyState enemy,
    required double dt,
    required Vec2 playerPosition,
  }) {
    if (enemy.isDead) {
      return const EnemyStepEvent();
    }
    enemy.age += dt;

    // ---- 1. 移动 ----
    final profile = enemy.tuning.move;
    switch (profile.kind) {
      case 'sineDescent':
        // 以自身初始 x 为中心作正弦横摆并向下移动。
        enemy.position = Vec2(
          enemy.spawnX +
              profile.amplitude *
                  _sin(2 * math.pi * enemy.age / profile.periodSeconds),
          enemy.position.y + enemy.effectiveSpeed * dt,
        );
      case 'descentThenHold':
        final holdY = profile.holdY ?? enemy.position.y;
        if (enemy.position.y < holdY) {
          final next = enemy.position.y + enemy.effectiveSpeed * dt;
          enemy.position = Vec2(
            enemy.position.x,
            next > holdY ? holdY : next,
          );
        }
      case 'formationDescent':
      case 'straightDescent':
      default:
        enemy.position = Vec2(
          enemy.position.x,
          enemy.position.y + enemy.effectiveSpeed * dt,
        );
    }

    // ---- 2. 完全进入后才开始攻击冷却 ----
    if (!enemy.hasEntered && enemy.position.y >= 0) {
      enemy.hasEntered = true;
    }
    // 冷却的初始化**不能**只挂在上面那个分支上：`hasEntered` 是公开可变
    // 状态，任何其它路径把它置为 true（例如测试夹具、将来的对象池复用）
    // 都会让 attackCooldown 永远停在 null，敌人从此不再攻击。
    // 因此这里补齐不变量：已进入世界、是远程、且尚未开始计时 → 在这里开始。
    if (enemy.hasEntered &&
        enemy.isRanged &&
        enemy.attackCooldown == null &&
        enemy.position.y >= 0) {
      enemy.attackCooldown = enemy.tuning.attack!.intervalSeconds;
    }

    // ---- 3. 越界预警（y=920，只发一次）----
    EnemyState? warning;
    if (!enemy.warnedBreach && enemy.position.y >= breachWarningY) {
      enemy.warnedBreach = true;
      warning = enemy;
    }

    // ---- 4. 越界移除（y=1140）----
    if (enemy.position.y > breachRemoveY) {
      return EnemyStepEvent(breachWarning: warning, breached: enemy);
    }

    var shieldGranted = 0;

    // ---- 5. 精英"护体"词缀：每 8 秒获得 20 护盾 ----
    final affix = enemy.affix;
    if (affix != null &&
        affix.shieldGrantAmount > 0 &&
        affix.shieldGrantIntervalSeconds > 0) {
      enemy._shieldTimer -= dt;
      while (enemy._shieldTimer <= 0) {
        enemy._shieldTimer += affix.shieldGrantIntervalSeconds;
        enemy.shield += affix.shieldGrantAmount;
        shieldGranted += affix.shieldGrantAmount;
      }
    }

    // ---- 6. 攻击计时（屏幕外不攻击）----
    final requests = <EnemyAttackRequest>[];
    final attack = enemy.tuning.attack;
    if (attack != null && enemy.hasEntered && enemy.position.y >= 0) {
      final cooldown = enemy.attackCooldown;
      if (cooldown != null) {
        final next = cooldown - dt;
        if (next <= 0) {
          enemy.attackCooldown = attack.intervalSeconds;
          requests.add(
            EnemyAttackRequest(
              sourceId: enemy.id,
              enemyId: enemy.tuning.id,
              attackId: attack.attackId,
              origin: enemy.position,
              aimTarget: playerPosition,
              projectileCount: enemy.effectiveProjectileCount,
              angleOffsetsDegrees: attack.burstAngleOffsetsDegrees,
              telegraphSeconds: enemy.effectiveTelegraphSeconds,
              projectile: attack.projectile,
              hazard: attack.hazard,
              dropAt: attack.dropAt,
            ),
          );
        } else {
          enemy.attackCooldown = next;
        }
      }
    }

    return EnemyStepEvent(
      attackRequests: requests,
      breachWarning: warning,
      shieldGranted: shieldGranted,
    );
  }

  /// 计算 Shield 的正面减伤后伤害。
  ///
  /// 产品基线 §3.4：仅落在正面锥内的我方伤害减免 75%。
  /// [playerPosition] 为伤害来源方向；锥角 120°（半角 60°）。
  int applyFrontShield(
    EnemyTuning tuning,
    Vec2 enemyPosition,
    Vec2 playerPosition,
    int rawDamage,
  ) {
    if (!tuning.hasFrontShield) {
      return rawDamage;
    }
    final toPlayer = (playerPosition - enemyPosition).normalized;
    final facing = tuning.frontShieldFacing.normalized;
    final dot = toPlayer.x * facing.x + toPlayer.y * facing.y;
    // 半角 60° 对应 cos = 0.5。
    if (dot < 0.5) {
      return rawDamage;
    }
    final reduced = (rawDamage * (1 - tuning.frontShieldReduction)).floor();
    return reduced < 1 ? 1 : reduced;
  }

  double _sin(double radians) => math.sin(radians);
}
