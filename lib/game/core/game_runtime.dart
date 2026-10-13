// ================================================================
// lib/game/core/game_runtime.dart —— 单帧运行时
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §4（固定步进与单帧顺序）
//
// 每个逻辑步严格按以下顺序：
//   1. 锁定本步 InputFrame；处理边沿命令
//   2. 非 Playing → 只生成快照后结束本步
//   3. 推进计时器（冲刺/护盾恢复/连击衰减/Director/Boss）
//   4. 依锁定输入算玩家移动意图并夹紧边界
//   5. 更新敌人/Boss/投射物/危险区/无人机；只产生"待生成命令"
//   6. 目标选择与武器发射；新实体入待提交队列
//   7. 收集碰撞对；按层与事件序号排序；生成伤害意图
//   8. 合并伤害、应用无敌/护盾/HP、死亡、经验、掉落、分数、状态转移
//   9. 提交实体增删、发出不可变 DomainEvent、生成 RenderSnapshot
//
// 契约：**仅 Playing 推进逻辑**；不可重入。
// ================================================================

import 'dart:math' as math;

import '../domain/collision.dart';
import '../domain/damage.dart';
import '../domain/director_system.dart';
import '../domain/enemy_system.dart';
import '../domain/player_system.dart';
import '../domain/values.dart';
import '../domain/weapon_system.dart';
import 'domain_event.dart';
import 'event_bus.dart';
import 'game_clock.dart';
import 'game_phase.dart';
import 'input_frame.dart';
import 'phase_controller.dart';
import 'random_source.dart';
import 'render_snapshot.dart';
import 'run_context.dart';

/// 投射物归属方。
enum ProjectileFaction { player, enemy }

/// 一个投射物。
class Projectile {
  Projectile({
    required this.id,
    required this.faction,
    required this.position,
    required this.direction,
    required this.speed,
    required this.radius,
    required this.damage,
    required this.lifetimeSeconds,
    required this.weaponId,
    this.ownerId,
    this.isCritical = false,
    this.attackId,
    this.assetId,
  });

  final EntityId id;
  final ProjectileFaction faction;
  Vec2 position;
  Vec2 direction;
  final double speed;
  final double radius;
  final int damage;
  final double lifetimeSeconds;
  final String weaponId;
  final EntityId? ownerId;
  final bool isCritical;
  final String? attackId;
  final String? assetId;

  double age = 0;
  bool consumed = false;

  bool get isExpired => age >= lifetimeSeconds;

  CircleHitbox get hitbox => CircleHitbox(position, radius);
}

/// 危险区（Bomber）。
class HazardZone {
  HazardZone({
    required this.id,
    required this.position,
    required this.radius,
    required this.warningSeconds,
    required this.activeSeconds,
    required this.tickSeconds,
    required this.damagePerTick,
    required this.sourceId,
  });

  final EntityId id;
  final Vec2 position;
  final double radius;
  final double warningSeconds;
  final double activeSeconds;
  final double tickSeconds;
  final int damagePerTick;
  final EntityId sourceId;

  double age = 0;
  double _tickAccumulator = 0;

  bool get isWarning => age < warningSeconds;
  bool get isExpired => age >= warningSeconds + activeSeconds;

  double get remainingRatio {
    final total = warningSeconds + activeSeconds;
    return total <= 0 ? 0 : (1 - age / total).clamp(0.0, 1.0);
  }

  /// 推进；返回本次是否应结算一次伤害。
  bool tick(double dt) {
    final wasWarning = isWarning;
    age += dt;
    if (wasWarning || isWarning) {
      return false;
    }
    _tickAccumulator += dt;
    if (_tickAccumulator >= tickSeconds) {
      _tickAccumulator -= tickSeconds;
      return true;
    }
    return false;
  }

  CircleHitbox get hitbox => CircleHitbox(position, radius);
}

/// 一局的运行时。持有全部实体注册表并驱动九步顺序。
class GameRuntime {
  GameRuntime({
    required this.catalogPlayer,
    required this.enemyTunings,
    required this.runtime,
    required this.random,
    required this.bus,
    required this.clock,
    required this.phases,
    required this.director,
    required this.enemySystem,
    required this.pulse,
    this.tuning,
    this.breachNormalHpDamage = 8,
    this.breachEliteHpDamage = 15,
  })  : player = PlayerState(
          tuning: tuning ?? PlayerTuning.fromConfig(catalogPlayer),
        );

  final Map<String, Object?> catalogPlayer;
  final Map<String, EnemyTuning> enemyTunings;
  final RunContext runtime;
  final RandomSource random;
  final EventBus bus;
  final GameClock clock;
  final PhaseController phases;
  final DirectorSystem director;
  final EnemySystem enemySystem;
  final PulseWeapon pulse;
  final PlayerTuning? tuning;

  /// 突破伤害（穿透护盾）：普通 8、精英 15。
  final int breachNormalHpDamage;
  final int breachEliteHpDamage;

  late final PlayerState player;
  final PlayerSystem playerSystem = PlayerSystem();
  final DamageSystem damageSystem = DamageSystem();
  final CollisionSystem collisionSystem = CollisionSystem();
  final EntityIdAllocator ids = EntityIdAllocator();

  final List<EnemyState> enemies = <EnemyState>[];
  final List<Projectile> projectiles = <Projectile>[];
  final List<HazardZone> hazards = <HazardZone>[];

  int score = 0;
  int xp = 0;
  int comboCount = 0;
  double comboMultiplier = 1.0;
  double _comboTimer = 0;

  /// 当前锁定的输入（技术架构 §4 第 1 步）。
  InputFrame _lockedInput = InputFrame.idle;

  /// 本步待提交的新实体（第 5/6 步只入队，第 9 步提交）。
  final List<EnemyState> _pendingEnemies = <EnemyState>[];
  final List<Projectile> _pendingProjectiles = <Projectile>[];
  final List<HazardZone> _pendingHazards = <HazardZone>[];

  /// 是否推进过逻辑（用于测试断言"冻结"）。
  int logicSteps = 0;

  bool _inStep = false;

  /// 有效战斗时间（秒），由逻辑步累计。
  double get combatSeconds => clock.elapsedSeconds;

  // ------------------------------------------------------------
  // 帧推进
  // ------------------------------------------------------------

  /// 推进一个**渲染帧**。
  ///
  /// 返回本帧执行的逻辑步数。非 Playing 状态返回 0 —— 逻辑完全冻结。
  int advance(double renderDeltaSeconds, InputFrame input) {
    if (_inStep) {
      throw StateError('GameRuntime.advance 不可重入');
    }
    _lockedInput = input;

    // 边沿命令即使不推进逻辑也要处理（例如暂停请求）。
    final pauseEvent = _lockedInput.pauseRequested
        ? phases.requestPause(PauseSource.userRequest)
        : null;
    if (pauseEvent != null) {
      bus.emit(pauseEvent, runtime);
    }

    if (!phases.phase.advancesLogic) {
      return 0;
    }

    final steps = clock.advanceAndRun(renderDeltaSeconds, (frameIndex) {
      _inStep = true;
      try {
        runtime.setFrameIndex(frameIndex);
        _stepOnce();
        logicSteps++;
      } finally {
        _inStep = false;
      }
    });
    return steps;
  }

  /// 单个逻辑步（严格九步顺序）。
  void _stepOnce() {
    // 1. 输入已在本帧开头锁定；边沿命令已在 advance 处理。

    // 2. 相位门禁（此处必为 Playing，保留二次确认）。
    if (!phases.phase.advancesLogic) {
      return;
    }

    final dt = GameClock.fixedStepSeconds;

    // 3. 计时器：冲刺/护盾恢复/连击衰减。
    player.dash.tick(dt);
    if (player.dash.endLockRemaining > 0) {
      player.dash.endLockRemaining -= dt;
      if (player.dash.endLockRemaining < 0) {
        player.dash.endLockRemaining = 0;
      }
    }
    if (_comboTimer > 0) {
      _comboTimer -= dt;
      if (_comboTimer <= 0) {
        _comboTimer = 0;
        comboCount = 0;
        comboMultiplier = 1.0;
      }
    }

    // 4. 玩家移动与冲刺（使用锁定输入）。
    playerSystem.step(
      state: player,
      input: _lockedInput,
      dt: dt,
      elapsedSeconds: combatSeconds,
    );
    final shieldRestored = player.shieldRegen.tick(dt, player.shield);
    if (shieldRestored > 0) {
      bus.emit(
        PlayerVitalStateChanged(
          hp: player.health.current,
          hpMax: player.health.max,
          shield: player.shield.current,
          shieldMax: player.shield.max,
          cause: 'shieldRegen',
        ),
        runtime,
      );
    }

    // 5. Director 与敌人更新（只产生待生成命令）。
    _updateDirector(dt);
    _updateEnemies(dt);
    _updateHazards(dt);

    // 6. 目标选择与武器发射。
    _fireWeapons(dt);
    _updateProjectiles(dt);

    // 7. 碰撞收集 + 8. 伤害结算。
    _resolveCollisions();

    // 9. 提交实体增删。
    _commitPending();
  }

  // ------------------------------------------------------------
  // 第 5 步：Director 与敌人
  // ------------------------------------------------------------

  void _updateDirector(double dt) {
    final triggers = director.step(
      combatSeconds: combatSeconds,
      playerPosition: player.position,
      playerHp: player.health.current,
      hpDamageInLast15s: 0,
      upgradeCount: 0,
      activeEnemyCount: enemies.length,
    );

    for (final trigger in triggers) {
      if (trigger.isDeferred) {
        continue;
      }
      final centerX = trigger.centerX ?? 960;
      for (final spawn in trigger.spawns) {
        final tuning = enemyTunings[spawn.enemyId];
        if (tuning == null) {
          continue;
        }
        // 预算门禁：同屏敌人上限 45。
        if (enemies.length + _pendingEnemies.length >= 45) {
          break;
        }
        final offsets = tuning.move.formationOffsets.isEmpty
            ? const <Vec2>[Vec2.zero]
            : tuning.move.formationOffsets;
        for (var i = 0; i < spawn.count; i++) {
          final offset = offsets.length == 1
              ? Vec2.zero
              : offsets[i % offsets.length];
          final enemy = enemySystem.spawn(
            id: ids.next(EntityKind.enemy),
            tuning: tuning,
            spawnX: centerX + (i ~/ offsets.length) * 120,
            formationOffset: offset,
            isElite: spawn.isElite,
          );
          _pendingEnemies.add(enemy);
          bus.emit(
            EnemySpawned(
              entityId: enemy.id,
              enemyId: tuning.id,
              position: enemy.position,
              isElite: spawn.isElite,
            ),
            runtime,
          );
        }
      }
    }
  }

  void _updateEnemies(double dt) {
    for (final enemy in enemies) {
      if (enemy.isDead) {
        continue;
      }
      final event = enemySystem.step(
        enemy: enemy,
        dt: dt,
        playerPosition: player.position,
      );

      if (event.breachWarning != null) {
        bus.emit(
          EnemyBreached(
            entityId: enemy.id,
            enemyId: enemy.tuning.id,
            isElite: enemy.isElite,
            breachHpDamage: 0,
            position: enemy.position,
            isWarningOnly: true,
          ),
          runtime,
        );
      }

      // 越界：移除 + 穿透护盾的 HP 伤害 + **不给任何奖励**。
      if (event.breached != null) {
        _applyBreach(enemy);
        continue;
      }

      for (final request in event.attackRequests) {
        bus.emit(
          EnemyAttackFired(
            entityId: request.sourceId,
            enemyId: request.enemyId,
            attackId: request.attackId,
            position: request.origin,
            telegraphSeconds: request.telegraphSeconds,
          ),
          runtime,
        );
        // 有预警的招式先发预警事件，再生成投射物。
        if (request.telegraphSeconds > 0) {
          bus.emit(
            EnemyAttackTelegraphed(
              entityId: request.sourceId,
              enemyId: request.enemyId,
              attackId: request.attackId,
              position: request.origin,
              telegraphSeconds: request.telegraphSeconds,
            ),
            runtime,
          );
        }
        _spawnEnemyAttack(request);
      }
    }
  }

  void _applyBreach(EnemyState enemy) {
    // 产品基线 §5：普通敌人 8、精英敌人 15（穿透护盾）。
    final damage = enemy.isElite
        ? breachEliteHpDamage
        : breachNormalHpDamage;
    final result = damageSystem.applyToPlayer(
      intent: DamageIntent(
        sourceId: enemy.id,
        targetId: const EntityId(EntityKind.player, 0),
        damageType: DamageType.breach,
        rawDamage: damage,
        frameIndex: runtime.frameIndex,
        hitKey: 'breach|${enemy.id}',
        sourceType: 'breach',
      ),
      health: player.health,
      shield: player.shield,
      invulnerable: player.isInvulnerable,
      nowSeconds: combatSeconds,
    );

    bus.emit(
      EnemyBreached(
        entityId: enemy.id,
        enemyId: enemy.tuning.id,
        isElite: enemy.isElite,
        breachHpDamage: result.hpDamage,
        position: enemy.position,
      ),
      runtime,
    );
    _markForRemoval(enemy);
    // 突破**不给**经验、分数、掉落与连击。
    if (result.hpDamage > 0) {
      _onPlayerTookHpDamage(result.hpDamage);
    }
    _checkPlayerDeath();
  }

  void _spawnEnemyAttack(EnemyAttackRequest request) {
    final spec = request.projectile;
    if (spec == null) {
      return;
    }
    final baseAngle = _angleOf(
      (request.aimTarget - request.origin).normalized,
    );
    final count = request.projectileCount;
    final offsets = request.angleOffsetsDegrees.isEmpty
        ? <double>[
            for (var i = 0; i < count; i++)
              count == 1 ? 0 : -10.0 + (20.0 / (count - 1)) * i,
          ]
        : request.angleOffsetsDegrees;

    for (var i = 0; i < count; i++) {
      final offset = i < offsets.length ? offsets[i] : 0.0;
      final angle = baseAngle + offset * math.pi / 180;
      _pendingProjectiles.add(
        Projectile(
          id: ids.next(EntityKind.enemyProjectile),
          faction: ProjectileFaction.enemy,
          position: request.origin,
          direction: Vec2(math.cos(angle), math.sin(angle)),
          speed: spec.speed,
          radius: spec.radius,
          damage: spec.damage,
          lifetimeSeconds: spec.lifetimeSeconds,
          weaponId: request.attackId,
          ownerId: request.sourceId,
          attackId: request.attackId,
          assetId: spec.assetId,
        ),
      );
    }
  }

  void _updateHazards(double dt) {
    for (final hazard in hazards) {
      final shouldDamage = hazard.tick(dt);
      if (shouldDamage && !player.isInvulnerable) {
        damageSystem.applyToPlayer(
          intent: DamageIntent(
            sourceId: hazard.sourceId,
            targetId: const EntityId(EntityKind.player, 0),
            damageType: DamageType.standard,
            rawDamage: hazard.damagePerTick,
            frameIndex: runtime.frameIndex,
            hitKey: 'hazard|${hazard.id}',
            sourceType: 'hazard',
          ),
          health: player.health,
          shield: player.shield,
          invulnerable: false,
          nowSeconds: combatSeconds,
        );
      }
    }
  }

  // ------------------------------------------------------------
  // 第 6 步：武器
  // ------------------------------------------------------------

  void _fireWeapons(double dt) {
    final targets = _targetViews();
    final requests = pulse.step(
      playerPosition: player.position,
      targets: targets,
      dt: dt,
      rng: random,
    );

    for (final request in requests) {
      final projectile = Projectile(
        id: ids.next(EntityKind.playerProjectile),
        faction: ProjectileFaction.player,
        position: request.origin,
        direction: request.direction,
        speed: request.speed,
        radius: request.radius,
        damage: request.damage,
        lifetimeSeconds: request.lifetimeSeconds,
        weaponId: request.weaponId,
        isCritical: request.isCritical,
      );
      _pendingProjectiles.add(projectile);

      bus.emit(
        WeaponFired(
          weaponId: request.weaponId,
          sourceId: const EntityId(EntityKind.player, 0),
          position: request.origin,
          direction: request.direction,
        ),
        runtime,
      );
    }
  }

  void _updateProjectiles(double dt) {
    for (final projectile in projectiles) {
      if (projectile.consumed) {
        continue;
      }
      projectile.age += dt;
      if (projectile.isExpired) {
        projectile.consumed = true;
        continue;
      }
      projectile.position =
          projectile.position + projectile.direction * (projectile.speed * dt);
      // 出界即失效。
      if (projectile.position.y < -200 ||
          projectile.position.y > 1300 ||
          projectile.position.x < -200 ||
          projectile.position.x > 2100) {
        projectile.consumed = true;
      }
    }
  }

  List<TargetView> _targetViews() => <TargetView>[
    for (final enemy in enemies)
      if (!enemy.isDead)
        TargetView(
          id: enemy.id,
          position: enemy.position,
          radius: enemy.tuning.radius,
          isElite: enemy.isElite,
        ),
  ];

  // ------------------------------------------------------------
  // 第 7/8 步：碰撞与伤害
  // ------------------------------------------------------------

  void _resolveCollisions() {
    final bodies = <CollisionBody>[
      CollisionBody(
        id: const EntityId(EntityKind.player, 0),
        layer: CollisionLayer.playerBody,
        center: player.position,
        radius: player.tuning.bodyRadius,
      ),
      for (final enemy in enemies)
        if (!enemy.isDead)
          CollisionBody(
            id: enemy.id,
            layer: CollisionLayer.enemyBody,
            center: enemy.position,
            radius: enemy.tuning.radius,
            isElite: enemy.isElite,
            enemyId: enemy.tuning.id,
          ),
      for (final projectile in projectiles)
        if (!projectile.consumed)
          CollisionBody(
            id: projectile.id,
            layer: projectile.faction == ProjectileFaction.player
                ? CollisionLayer.playerProjectile
                : CollisionLayer.enemyProjectile,
            center: projectile.position,
            radius: projectile.radius,
            attackId: projectile.attackId,
          ),
      for (final hazard in hazards)
        if (!hazard.isExpired && !hazard.isWarning)
          CollisionBody(
            id: hazard.id,
            layer: CollisionLayer.hazard,
            center: hazard.position,
            radius: hazard.radius,
          ),
    ];

    final pairs = collisionSystem.collect(
      bodies,
      isPlayerInvulnerable: player.isInvulnerable,
    );

    final intents = <DamageIntent>[];
    for (final pair in pairs) {
      final a = pair.a;
      final b = pair.b;
      final playerSide = a.layer == CollisionLayer.playerBody ? a : b;
      final otherSide = identical(playerSide, a) ? b : a;

      if (playerSide.layer == CollisionLayer.playerBody &&
          otherSide.layer != CollisionLayer.playerBody) {
        intents.add(
          DamageIntent(
            sourceId: otherSide.id,
            targetId: playerSide.id,
            damageType: DamageType.standard,
            rawDamage: _playerDamageFrom(otherSide),
            frameIndex: runtime.frameIndex,
            hitKey: '${otherSide.id}|player',
            attackId: otherSide.attackId,
            sourceType: otherSide.layer.name,
          ),
        );
      }
    }

    // 合并同帧伤害后逐条结算（伤害顺序由 DamageSystem 保证）。
    for (final intent in DamageSystem.mergeSameFrame(intents)) {
      final result = damageSystem.applyToPlayer(
        intent: intent,
        health: player.health,
        shield: player.shield,
        invulnerable: player.isInvulnerable,
        nowSeconds: combatSeconds,
      );
      if (result.dealtAnyDamage) {
        player.shieldRegen.notifyDamaged();
        if (result.hpDamage > 0) {
          _onPlayerTookHpDamage(result.hpDamage);
        }
        bus.emit(
          PlayerDamaged(
            sourceType: intent.sourceType ?? 'unknown',
            shieldDamage: result.shieldDamage,
            hpDamage: result.hpDamage,
            hpAfter: result.hpAfter,
            shieldAfter: result.shieldAfter,
          ),
          runtime,
        );
        _checkPlayerDeath();
      }
    }

    _resolvePlayerProjectileHits();
  }

  int _playerDamageFrom(CollisionBody body) {
    if (body.layer == CollisionLayer.enemyBody) {
      final tuning = enemyTunings[body.enemyId];
      return tuning?.contactDamage ?? 10;
    }
    if (body.layer == CollisionLayer.hazard) {
      return 8;
    }
    // 敌方投射物：从投射物表里取真实伤害。
    for (final projectile in projectiles) {
      if (projectile.id == body.id) {
        return projectile.damage;
      }
    }
    return 0;
  }

  void _resolvePlayerProjectileHits() {
    for (final projectile in projectiles) {
      if (projectile.consumed || projectile.faction != ProjectileFaction.player) {
        continue;
      }
      for (final enemy in enemies) {
        if (enemy.isDead) {
          continue;
        }
        if (!projectile.hitbox.intersects(enemy.hitbox)) {
          continue;
        }
        final reduced = enemySystem.applyFrontShield(
          enemy.tuning,
          enemy.position,
          player.position,
          projectile.damage,
        );
        final applied = enemy.health.applyDamage(reduced);
        projectile.consumed = true;

        bus.emit(
          WeaponHit(
            weaponId: projectile.weaponId,
            sourceId: const EntityId(EntityKind.player, 0),
            targetId: enemy.id,
            critical: projectile.isCritical,
            damage: applied,
            targetEnemyId: enemy.tuning.id,
          ),
          runtime,
        );
        bus.emit(
          EnemyDamaged(
            entityId: enemy.id,
            enemyId: enemy.tuning.id,
            damage: applied,
            hpAfter: enemy.health.current,
            hpMax: enemy.health.max,
          ),
          runtime,
        );

        if (enemy.isDead) {
          _onEnemyKilled(enemy);
        }
        break; // 单体命中后销毁
      }
    }
  }

  void _onEnemyKilled(EnemyState enemy) {
    // 分数 = 基础分 × 连击倍率，向下取整。
    final base = enemy.isElite
        ? enemy.tuning.score * 8
        : enemy.tuning.score;
    score += (base * comboMultiplier).floor();

    // 连击：4 秒内再次击杀 +1；每 10 连击倍率 +0.1，最高 2.0。
    comboCount += 1;
    _comboTimer = 4.0;
    comboMultiplier = (1.0 + (comboCount ~/ 10) * 0.1).clamp(1.0, 2.0);

    xp += enemy.isElite ? enemy.tuning.xp * 3 : enemy.tuning.xp;

    bus.emit(
      EnemyDestroyed(
        entityId: enemy.id,
        enemyId: enemy.tuning.id,
        position: enemy.position,
        isElite: enemy.isElite,
      ),
      runtime,
    );
    _markForRemoval(enemy);
  }

  void _onPlayerTookHpDamage(int amount) {
    // 连击倍率 -0.2（最低 1.0），**不清空层数**。
    comboMultiplier = (comboMultiplier - 0.2).clamp(1.0, 2.0);
  }

  void _checkPlayerDeath() {
    if (player.health.isDead) {
      bus.emit(
        RunEnded(
          result: 'defeat',
          durationSeconds: combatSeconds,
          score: score,
          seed: runtime.seed,
          bossHpRatio: 0,
          resultTier: 'none',
        ),
        runtime,
      );
    }
  }

  // ------------------------------------------------------------
  // 第 9 步：提交
  // ------------------------------------------------------------

  final List<EnemyState> _removals = <EnemyState>[];

  void _markForRemoval(EnemyState enemy) => _removals.add(enemy);

  void _commitPending() {
    if (_pendingEnemies.isNotEmpty) {
      enemies.addAll(_pendingEnemies);
      _pendingEnemies.clear();
    }
    if (_pendingProjectiles.isNotEmpty) {
      projectiles.addAll(_pendingProjectiles);
      _pendingProjectiles.clear();
    }
    if (_pendingHazards.isNotEmpty) {
      hazards.addAll(_pendingHazards);
      _pendingHazards.clear();
    }
    if (_removals.isNotEmpty) {
      enemies.removeWhere(_removals.contains);
      _removals.clear();
    }
    projectiles.removeWhere((p) => p.consumed || p.isExpired);
    hazards.removeWhere((h) => h.isExpired);
  }

  // ------------------------------------------------------------
  // 快照
  // ------------------------------------------------------------

  /// 生成当前帧的只读快照。可在任意相位调用。
  RenderSnapshot snapshot({
    String? playerAssetId = 'GFX-PLAYER-BASE',
    String? playerState,
  }) {
    final enemyViews = <EntityView>[
      for (final enemy in enemies)
        EntityView(
          id: enemy.id,
          position: enemy.position,
          radius: enemy.tuning.radius,
          enemyId: enemy.tuning.id,
          hpRatio: enemy.health.ratio,
          isElite: enemy.isElite,
          assetId: enemy.tuning.bodyAssetId,
          visualState: enemy.health.ratio <= 0.25 ? 'critical' : 'idle',
        ),
    ];

    final projectileViews = <EntityView>[
      for (final projectile in projectiles)
        EntityView(
          id: projectile.id,
          position: projectile.position,
          radius: projectile.radius,
          isPlayerProjectile: projectile.faction == ProjectileFaction.player,
          rotationRadians: _angleOf(projectile.direction),
          assetId: projectile.assetId,
        ),
    ];

    final hazardViews = <HazardView>[
      for (final hazard in hazards)
        HazardView(
          id: hazard.id,
          position: hazard.position,
          radius: hazard.radius,
          isWarning: hazard.isWarning,
          remainingRatio: hazard.remainingRatio,
        ),
    ];

    return RenderSnapshot(
      frameIndex: runtime.frameIndex,
      phase: phases.phase.name,
      player: EntityView(
        id: const EntityId(EntityKind.player, 0),
        position: player.position,
        radius: player.tuning.bodyRadius,
        hpRatio: player.health.ratio,
        rotationRadians: 0,
        assetId: playerAssetId,
        visualState: playerState,
      ),
      enemies: List<EntityView>.unmodifiable(enemyViews),
      projectiles: List<EntityView>.unmodifiable(projectileViews),
      hazards: List<HazardView>.unmodifiable(hazardViews),
      hud: HudView(
        hp: player.health.current,
        hpMax: player.health.max,
        shield: player.shield.current,
        shieldMax: player.shield.max,
        xp: xp,
        upgradeLevel: 0,
        score: score,
        comboMultiplier: comboMultiplier,
        comboCount: comboCount,
        combatSeconds: combatSeconds,
        dashCharges: player.dash.charges,
        dashMaxCharges: player.dash.maxCharges,
        objectiveWarning: enemies.any((e) => e.warnedBreach),
      ),
      isPlayerInvulnerable: player.isInvulnerable,
      activeEnemyCount: enemies.length,
      isBossActive: false,
    );
  }

  /// 释放本局（新局前必须调用）。
  void dispose() {
    enemies.clear();
    projectiles.clear();
    hazards.clear();
    _pendingEnemies.clear();
    _pendingProjectiles.clear();
    _pendingHazards.clear();
    _removals.clear();
    damageSystem.reset();
    collisionSystem.reset();
    ids.reset();
    bus.clear();
  }
}

double _angleOf(Vec2 direction) => math.atan2(direction.y, direction.x);
