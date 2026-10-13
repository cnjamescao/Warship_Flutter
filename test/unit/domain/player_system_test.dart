// ================================================================
// test/unit/domain/player_system_test.dart —— 玩家移动、冲刺与碰撞
// ================================================================
// 覆盖 P0：T-DASH-01 / T-DASH-02 / T-GEOMETRY-01 的剩余部分
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/domain/collision.dart';
import 'package:warship_flutter/game/domain/player_system.dart';
import 'package:warship_flutter/game/domain/values.dart';

const double kStep = 1 / 60;

PlayerTuning tuning() => PlayerTuning(
  spawnPosition: const Vec2(960, 900),
  moveSpeed: 340,
  bodyRadius: 30,
  bounds: WorldBounds.playerDefault,
  hpMax: 100,
  shieldMax: 30,
  shieldRegenDelaySeconds: 8.0,
  shieldRegenPerSecond: 3,
  dashMaxCharges: 2,
  dashRechargeSeconds: 6.0,
  dashDurationSeconds: 0.22,
  dashDistance: 360,
  dashInvulnerableSeconds: 0.22,
  dashEndLockSeconds: 0.12,
  dashDirectionFallbackWindowSeconds: 0.5,
);

/// 按固定步长推进若干步，返回累计结果。
PlayerStepResult run(
  PlayerSystem system,
  PlayerState state,
  int steps, {
  InputFrame input = InputFrame.idle,
  double startAt = 0,
}) {
  var last = const PlayerStepResult();
  for (var i = 0; i < steps; i++) {
    last = system.step(
      state: state,
      input: input,
      dt: kStep,
      elapsedSeconds: startAt + i * kStep,
    );
  }
  return last;
}

void main() {
  group('T-GEOMETRY-01 玩家移动', () {
    test('出生点与判定半径来自配置', () {
      final state = PlayerState(tuning: tuning());
      expect(state.position, const Vec2(960, 900));
      expect(state.hitbox.radius, 30);
    });

    test('最大移速 340 px/s：1 秒后恰好位移 340', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      run(system, state, 60, input: const InputFrame(moveDirection: Vec2(1, 0)));

      expect(state.position.x - 960, closeTo(340, 0.5));
      expect(state.position.y, closeTo(900, 1e-9));
    });

    test('不使用惯性：输入归零立即停止', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      run(system, state, 30, input: const InputFrame(moveDirection: Vec2(1, 0)));
      final movedTo = state.position.x;
      expect(movedTo, greaterThan(960));

      // 归零后继续推进 30 步：不应再移动分毫。
      run(system, state, 30);
      expect(state.position.x, movedTo, reason: '无惯性，立即停止');
    });

    test('斜向输入被单位化，不会比直线更快', () {
      final system = PlayerSystem();
      final straight = PlayerState(tuning: tuning());
      final diagonal = PlayerState(tuning: tuning());

      run(system, straight, 60,
          input: const InputFrame(moveDirection: Vec2(1, 0)));
      // 用左上方向：从 (960,900) 出发，x 有 930、y 有 870 的余量，
      // 不会像右下方向那样在 y=1050 处被边界夹断。
      run(system, diagonal, 60,
          input: const InputFrame(moveDirection: Vec2(-1, -1)));

      final straightDistance =
          (straight.position - const Vec2(960, 900)).length;
      final diagonalDistance =
          (diagonal.position - const Vec2(960, 900)).length;

      expect(diagonalDistance, closeTo(straightDistance, 0.5));
      expect(diagonalDistance, closeTo(340, 0.5));
    });

    test('中心被夹紧在 x=30..1890 / y=30..1050', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      run(system, state, 600,
          input: const InputFrame(moveDirection: Vec2(-1, 0)));
      expect(state.position.x, 30, reason: '不能穿出左边界');

      run(system, state, 600,
          input: const InputFrame(moveDirection: Vec2(1, 0)));
      expect(state.position.x, 1890);

      run(system, state, 600,
          input: const InputFrame(moveDirection: Vec2(0, 1)));
      expect(state.position.y, 1050);
    });
  });

  group('T-DASH-01 冲刺方向与距离', () {
    test('有移动输入时按输入方向冲刺', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      final result = system.step(
        state: state,
        input: const InputFrame(
          moveDirection: Vec2(-1, 0),
          dashRequested: true,
        ),
        dt: kStep,
        elapsedSeconds: 0,
      );

      expect(result.dashStarted, isTrue);
      expect(result.dashDirection, const Vec2(-1, 0));
      expect(state.dash.direction, const Vec2(-1, 0));
    });

    test('无输入但 0.5 秒内有移动 → 沿最后方向冲刺', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      // 先向左移动 0.2 秒。
      run(system, state, 12, input: const InputFrame(moveDirection: Vec2(-1, 0)));

      final result = system.step(
        state: state,
        input: const InputFrame(dashRequested: true),
        dt: kStep,
        elapsedSeconds: 0.2,
      );

      expect(result.dashDirection, const Vec2(-1, 0));
    });

    test('无输入且从未移动 → 向上冲刺', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      final result = system.step(
        state: state,
        input: const InputFrame(dashRequested: true),
        dt: kStep,
        elapsedSeconds: 0,
      );

      expect(result.dashDirection, const Vec2(0, -1));
    });

    test('超过 0.5 秒回退窗口后不再使用旧方向，改为向上', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      run(system, state, 12, input: const InputFrame(moveDirection: Vec2(-1, 0)));

      final result = system.step(
        state: state,
        input: const InputFrame(dashRequested: true),
        dt: kStep,
        elapsedSeconds: 2.0, // 远超 0.5 秒窗口
      );

      expect(result.dashDirection, const Vec2(0, -1));
    });

    test('全程位移不超过 360 px', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());
      final start = state.position;

      system.step(
        state: state,
        input: const InputFrame(moveDirection: Vec2(1, 0), dashRequested: true),
        dt: kStep,
        elapsedSeconds: 0,
      );

      // 推进整个冲刺时长再额外若干步。
      for (var i = 1; i < 30; i++) {
        system.step(
          state: state,
          input: InputFrame.idle,
          dt: kStep,
          elapsedSeconds: i * kStep,
        );
      }

      final travelled = (state.position - start).length;
      expect(travelled, lessThanOrEqualTo(360.0 + 1e-6));
      expect(travelled, greaterThan(330), reason: '应当走完整段距离');
    });

    test('冲刺路径被边界截断，不可穿出战场', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());
      // 移到贴近左边界处：距离边界仅 30 px，远小于 360 px 的冲刺距离。
      state.position = const Vec2(60, 900);

      var truncated = false;
      system.step(
        state: state,
        input: const InputFrame(moveDirection: Vec2(-1, 0), dashRequested: true),
        dt: kStep,
        elapsedSeconds: 0,
      );

      // 单步位移约 27 px，因此需要几步才撞到边界。
      for (var i = 1; i < 20; i++) {
        final result = system.step(
          state: state,
          input: InputFrame.idle,
          dt: kStep,
          elapsedSeconds: i * kStep,
        );
        truncated = truncated || result.truncatedByBounds;
      }

      expect(truncated, isTrue, reason: '撞到边界时必须报告截断');
      expect(state.position.x, 30, reason: '被夹在左边界');
      expect(state.position.y, closeTo(900, 1e-9));
    });

    test('消耗一层并进入无敌；结束时解除并进入 0.12 秒锁定', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      system.step(
        state: state,
        input: const InputFrame(moveDirection: Vec2(0, -1), dashRequested: true),
        dt: kStep,
        elapsedSeconds: 0,
      );
      expect(state.dash.charges, 1);
      expect(state.isInvulnerable, isTrue);

      // 推进到冲刺结束（0.22 s ≈ 13.2 步，因此用 14 步覆盖并累计）。
      var ended = false;
      for (var i = 1; i <= 14; i++) {
        final result = system.step(
          state: state,
          input: InputFrame.idle,
          dt: kStep,
          elapsedSeconds: i * kStep,
        );
        ended = ended || result.dashEnded;
      }

      expect(ended, isTrue);
      expect(state.isInvulnerable, isFalse);
      expect(state.dash.endLockRemaining, greaterThan(0));
    });

    test('结束锁定期内无法立刻再次冲刺', () {
      final system = PlayerSystem();
      final state = PlayerState(tuning: tuning());

      // 连按两次：第二次发生在锁定期内，应被拒绝。
      system.step(
        state: state,
        input: const InputFrame(moveDirection: Vec2(0, -1), dashRequested: true),
        dt: kStep,
        elapsedSeconds: 0,
      );
      for (var i = 1; i <= 14; i++) {
        system.step(
          state: state,
          input: InputFrame.idle,
          dt: kStep,
          elapsedSeconds: i * kStep,
        );
      }

      final chargesBefore = state.dash.charges;
      final blocked = system.step(
        state: state,
        input: const InputFrame(moveDirection: Vec2(0, -1), dashRequested: true),
        dt: kStep,
        elapsedSeconds: 0.24,
      );

      expect(blocked.dashStarted, isFalse);
      expect(state.dash.charges, chargesBefore);
    });
  });

  group('T-DASH-02 冲刺期间的碰撞豁免', () {
    const player = EntityId(EntityKind.player, 1);
    const enemy = EntityId(EntityKind.enemy, 2);
    const bullet = EntityId(EntityKind.enemyProjectile, 3);
    const hazard = EntityId(EntityKind.hazard, 4);

    List<CollisionBody> overlappingBodies() => <CollisionBody>[
      const CollisionBody(
        id: player,
        layer: CollisionLayer.playerBody,
        center: Vec2(960, 900),
        radius: 30,
      ),
      const CollisionBody(
        id: enemy,
        layer: CollisionLayer.enemyBody,
        center: Vec2(970, 900),
        radius: 28,
      ),
      const CollisionBody(
        id: bullet,
        layer: CollisionLayer.enemyProjectile,
        center: Vec2(965, 900),
        radius: 14,
      ),
      const CollisionBody(
        id: hazard,
        layer: CollisionLayer.hazard,
        center: Vec2(955, 900),
        radius: 90,
      ),
    ];

    test('常规状态下玩家与敌人/敌弹/危险区都产生配对', () {
      final system = CollisionSystem();
      final pairs = system.collect(overlappingBodies());

      final partners = pairs
          .expand((p) => <CollisionBody>[p.a, p.b])
          .map((b) => b.id)
          .toSet();

      expect(partners, contains(enemy));
      expect(partners, contains(bullet));
      expect(partners, contains(hazard));
    });

    test('冲刺无敌期间玩家与敌方层的配对全部消失', () {
      final system = CollisionSystem();
      final pairs = system.collect(
        overlappingBodies(),
        isPlayerInvulnerable: true,
      );

      expect(
        pairs,
        isEmpty,
        reason: '产品基线 §3.3：冲刺期间忽略 EnemyBody/EnemyProjectile/Hazard',
      );
    });

    test('冲刺结束后立即恢复常规碰撞', () {
      final system = CollisionSystem();

      expect(
        system.collect(overlappingBodies(), isPlayerInvulnerable: true),
        isEmpty,
      );
      expect(
        system.collect(overlappingBodies(), isPlayerInvulnerable: false),
        isNotEmpty,
      );
    });
  });

  group('碰撞层与宽相位', () {
    test('未在层表中的组合永不配对（敌人 × 敌人、我方弹 × 玩家）', () {
      final system = CollisionSystem();
      // 两个簇相距很远，确保只有"簇内"的组合有机会配对：
      //   A 簇（左）：两个敌人互相重叠 —— enemyBody × enemyBody 不在层表中；
      //   B 簇（右）：玩家与我方投射物重叠 —— playerBody × playerProjectile 不在层表中。
      final pairs = system.collect(<CollisionBody>[
        const CollisionBody(
          id: EntityId(EntityKind.enemy, 1),
          layer: CollisionLayer.enemyBody,
          center: Vec2(500, 500),
          radius: 28,
        ),
        const CollisionBody(
          id: EntityId(EntityKind.enemy, 2),
          layer: CollisionLayer.enemyBody,
          center: Vec2(505, 500),
          radius: 28,
        ),
        const CollisionBody(
          id: EntityId(EntityKind.player, 3),
          layer: CollisionLayer.playerBody,
          center: Vec2(1600, 500),
          radius: 30,
        ),
        const CollisionBody(
          id: EntityId(EntityKind.playerProjectile, 4),
          layer: CollisionLayer.playerProjectile,
          center: Vec2(1602, 500),
          radius: 6,
        ),
      ]);

      expect(
        pairs,
        isEmpty,
        reason: '敌对实体之间、以及玩家与自己的投射物之间都不应产生配对',
      );
    });

    test('我方投射物可以命中敌人与 Boss 弱点', () {
      final system = CollisionSystem();
      final pairs = system.collect(<CollisionBody>[
        const CollisionBody(
          id: EntityId(EntityKind.playerProjectile, 1),
          layer: CollisionLayer.playerProjectile,
          center: Vec2(500, 500),
          radius: 6,
        ),
        const CollisionBody(
          id: EntityId(EntityKind.enemy, 2),
          layer: CollisionLayer.enemyBody,
          center: Vec2(510, 500),
          radius: 28,
        ),
        const CollisionBody(
          id: EntityId(EntityKind.bossWeakpoint, 3),
          layer: CollisionLayer.bossWeakpoint,
          center: Vec2(500, 520),
          radius: 52,
        ),
      ]);

      expect(pairs.length, 2);
    });

    test('相切算相交；略微分开则不相交', () {
      final system = CollisionSystem();
      final touching = system.collect(<CollisionBody>[
        const CollisionBody(
          id: EntityId(EntityKind.player, 1),
          layer: CollisionLayer.playerBody,
          center: Vec2(0, 0),
          radius: 30,
        ),
        const CollisionBody(
          id: EntityId(EntityKind.enemy, 2),
          layer: CollisionLayer.enemyBody,
          center: Vec2(58, 0),
          radius: 28,
        ),
      ]);
      expect(touching.length, 1);

      final apart = system.collect(<CollisionBody>[
        const CollisionBody(
          id: EntityId(EntityKind.player, 1),
          layer: CollisionLayer.playerBody,
          center: Vec2(0, 0),
          radius: 30,
        ),
        const CollisionBody(
          id: EntityId(EntityKind.enemy, 2),
          layer: CollisionLayer.enemyBody,
          center: Vec2(58.5, 0),
          radius: 28,
        ),
      ]);
      expect(apart, isEmpty);
    });

    test('配对顺序稳定（同一输入两次收集结果一致）', () {
      final bodies = <CollisionBody>[
        const CollisionBody(
          id: EntityId(EntityKind.player, 1),
          layer: CollisionLayer.playerBody,
          center: Vec2(960, 900),
          radius: 30,
        ),
        for (var i = 2; i < 12; i++)
          CollisionBody(
            id: EntityId(EntityKind.enemy, i),
            layer: CollisionLayer.enemyBody,
            center: Vec2(940.0 + i, 900),
            radius: 28,
          ),
      ];

      final first = CollisionSystem().collect(bodies);
      final second = CollisionSystem().collect(bodies);

      expect(
        first.map((p) => '${p.a.id}|${p.b.id}').toList(),
        second.map((p) => '${p.a.id}|${p.b.id}').toList(),
      );
    });

    test('宽相位：远离的实体不会互相配对，网格限制候选规模', () {
      final system = CollisionSystem();
      final bodies = <CollisionBody>[
        const CollisionBody(
          id: EntityId(EntityKind.player, 1),
          layer: CollisionLayer.playerBody,
          center: Vec2(100, 100),
          radius: 30,
        ),
        // 散布在远处的敌人。
        for (var i = 0; i < 40; i++)
          CollisionBody(
            id: EntityId(EntityKind.enemy, 100 + i),
            layer: CollisionLayer.enemyBody,
            center: Vec2(1800.0 - i * 40, 1000),
            radius: 28,
          ),
      ];

      final pairs = system.collect(bodies);

      expect(pairs, isEmpty, reason: '距离远大于半径和，不应有任何配对');
      expect(system.grid.occupiedCellCount, greaterThan(1));
    });

    test('禁用（enabled=false）的实体不参与配对', () {
      final system = CollisionSystem();
      final pairs = system.collect(<CollisionBody>[
        const CollisionBody(
          id: EntityId(EntityKind.player, 1),
          layer: CollisionLayer.playerBody,
          center: Vec2(0, 0),
          radius: 30,
        ),
        const CollisionBody(
          id: EntityId(EntityKind.enemy, 2),
          layer: CollisionLayer.enemyBody,
          center: Vec2(10, 0),
          radius: 28,
          enabled: false,
        ),
      ]);

      expect(pairs, isEmpty);
    });
  });
}
