// ================================================================
// test/unit/domain/weapon_system_test.dart —— 目标选择与武器运行合同
// ================================================================
// 覆盖 P0：T-WEAPON-01 / T-WEAPON-02（产品基线 §4.1、§4.3）
// ================================================================

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

const double kStep = 1 / 60;

TargetView enemy(int seq, double x, double y, {bool elite = false}) =>
    TargetView(
      id: EntityId(EntityKind.enemy, seq),
      position: Vec2(x, y),
      radius: 30,
      isElite: elite,
    );

void main() {
  group('T-WEAPON-01 目标优先级', () {
    const targeting = TargetingSystem();
    const origin = Vec2(960, 900);

    test('Boss 弱点优先于更近的精英与普通敌人', () {
      final selected = targeting.select(
        targets: <TargetView>[
          enemy(1, 960, 100), // 最近的普通敌人
          enemy(2, 960, 200, elite: true), // 精英
          const TargetView(
            id: EntityId(EntityKind.bossWeakpoint, 3),
            position: Vec2(400, 100), // 最远
            radius: 52,
            isWeakpoint: true,
            weakpointActive: true,
          ),
        ],
        origin: origin,
        range: 980,
      );

      expect(selected!.id.kind, EntityKind.bossWeakpoint);
    });

    test('弱点未暴露时不可选，降级到最近精英', () {
      final selected = targeting.select(
        targets: <TargetView>[
          enemy(1, 960, 100),
          enemy(2, 960, 200, elite: true),
          const TargetView(
            id: EntityId(EntityKind.bossWeakpoint, 3),
            position: Vec2(960, 300),
            radius: 52,
            isWeakpoint: true,
            weakpointActive: false, // 未暴露
          ),
        ],
        origin: origin,
        range: 980,
      );

      expect(selected!.isElite, isTrue);
    });

    test('精英优先于更近的普通敌人', () {
      final selected = targeting.select(
        targets: <TargetView>[
          enemy(1, 960, 800), // 很近
          enemy(2, 960, 700, elite: true), // 稍远但是精英
        ],
        origin: origin,
        range: 980,
      );

      expect(selected!.id.sequence, 2);
    });

    test('超出射程的目标不可选', () {
      final selected = targeting.select(
        targets: <TargetView>[enemy(1, 960, -500)], // 距离 1400 > 980
        origin: origin,
        range: 980,
      );

      expect(selected, isNull);
    });

    test('同档内距离相等时按 EntityId 排序（回放确定性）', () {
      final selected = targeting.select(
        targets: <TargetView>[
          enemy(9, 700, 500),
          enemy(3, 700, 500), // 完全相同的位置
        ],
        origin: origin,
        range: 980,
      );

      expect(selected!.id.sequence, 3);
    });

    test('链式候选按距离再按 EntityId 排序，并排除已命中目标', () {
      final from = const Vec2(500, 500);
      final candidates = targeting.chainCandidates(
        targets: <TargetView>[
          enemy(1, 600, 500), // 距离 100
          enemy(2, 550, 500), // 距离 50
          enemy(3, 550, 500), // 距离 50，与 2 相同 → 序号更小者在先
          enemy(4, 1000, 500), // 距离 500 > 360，超范围
        ],
        from: from,
        radius: 360,
        exclude: const <EntityId>{},
      );

      expect(candidates.map((c) => c.id.sequence).toList(), <int>[2, 3, 1]);
    });
  });

  group('脉冲炮（§4.1）', () {
    test('冷却 0.24 秒、伤害 9、单发弹速与寿命符合产品表', () {
      final pulse = PulseWeapon();
      expect(pulse.effectiveCadence, 0.24);
      expect(pulse.effectiveDamage, 9);
      expect(pulse.speed, 1250);
      expect(pulse.lifetimeSeconds, 1.2);
      expect(pulse.range, 980);
    });

    test('无目标时向正前方（向上）射击', () {
      final pulse = PulseWeapon();
      final requests = pulse.step(
        playerPosition: const Vec2(960, 900),
        targets: const <TargetView>[],
        dt: kStep,
        rng: Pcg32(1),
      );

      expect(requests.length, 1);
      expect(requests.first.direction, const Vec2(0, -1));
      expect(requests.first.targetId, isNull);
    });

    test('有目标时初始方向指向目标', () {
      final pulse = PulseWeapon();
      final requests = pulse.step(
        playerPosition: const Vec2(960, 900),
        targets: <TargetView>[enemy(1, 960, 500)],
        dt: kStep,
        rng: Pcg32(1),
      );

      expect(requests.first.direction.x, closeTo(0, 1e-9));
      expect(requests.first.direction.y, closeTo(-1, 1e-9));
    });

    test('按 0.24 秒节奏发射', () {
      final pulse = PulseWeapon();
      final rng = Pcg32(1);
      var shots = 0;

      // 1 秒 = 60 步，按 0.24 秒节奏应发射 5 次（t=0,0.24,...,0.96）。
      for (var i = 0; i < 60; i++) {
        shots += pulse.step(
          playerPosition: const Vec2(960, 900),
          targets: const <TargetView>[],
          dt: kStep,
          rng: rng,
        ).length;
      }

      expect(shots, 5);
    });

    test('暴击伤害为 x1.8；暴击率为 0 时永不暴击', () {
      final noCrit = PulseWeapon();
      final plain = noCrit.step(
        playerPosition: const Vec2(960, 900),
        targets: const <TargetView>[],
        dt: kStep,
        rng: Pcg32(1),
      );
      expect(plain.first.isCritical, isFalse);
      expect(plain.first.damage, 9);

      final alwaysCrit = PulseWeapon()..criticalChance = 1.0;
      final crit = alwaysCrit.step(
        playerPosition: const Vec2(960, 900),
        targets: const <TargetView>[],
        dt: kStep,
        rng: Pcg32(1),
      );
      expect(crit.first.isCritical, isTrue);
      expect(crit.first.damage, (9 * 1.8).round());
    });

    test('升级：发射间隔 ×0.85、伤害 +3', () {
      final pulse = PulseWeapon()
        ..cadenceMultiplier = 0.85
        ..bonusDamage = 3;

      expect(pulse.effectiveCadence, closeTo(0.24 * 0.85, 1e-12));
      expect(pulse.effectiveDamage, 12);
    });

    test('双联分束：2 条弹道、±6°；第二级 0°（并行）', () {
      final pulse = PulseWeapon()
        ..projectileCount = 2
        ..spreadAngleDegrees = 6;
      final requests = pulse.step(
        playerPosition: const Vec2(960, 900),
        targets: const <TargetView>[],
        dt: kStep,
        rng: Pcg32(1),
      );

      expect(requests.length, 2);
      // 基准方向 (0,-1)；绕其旋转 ±6° 后 x 分量应为 ∓sin(6°)。
      final expected = math.sin(6 * math.pi / 180);
      expect(requests[0].direction.x, closeTo(-expected, 1e-9));
      expect(requests[1].direction.x, closeTo(expected, 1e-9));
    });
  });

  group('追踪导弹（§4.3）', () {
    test('每 2.4 秒一发；伤害 36、弹速 820、寿命 2.0、半径 16', () {
      final missile = MissileWeapon();
      expect(missile.baseCadence, 2.4);
      expect(missile.damagePerMissile, 36);
      expect(missile.speed, 820);
      expect(missile.lifetimeSeconds, 2.0);
      expect(missile.radius, 16);
      expect(missile.explosionRadius, 70);
    });

    test('齐射等级 0/1/2 对应 1/2/3 枚与 36/32.4/29 伤害', () {
      final missile = MissileWeapon();

      expect(missile.missileCount, 1);
      expect(missile.damagePerMissile, 36);

      missile.salvoLevel = 1;
      expect(missile.missileCount, 2);
      expect(missile.damagePerMissile, closeTo(32.4, 1e-9));

      missile.salvoLevel = 2;
      expect(missile.missileCount, 3);
      expect(missile.damagePerMissile, closeTo(29, 1e-9));
    });

    test('齐射角度：1 枚 0°、2 枚 ±8°、3 枚 -8/0/+8', () {
      final missile = MissileWeapon();

      expect(missile.salvoAnglesDegrees, <double>[0]);
      missile.salvoLevel = 1;
      expect(missile.salvoAnglesDegrees, <double>[-8, 8]);
      missile.salvoLevel = 2;
      expect(missile.salvoAnglesDegrees, <double>[-8, 0, 8]);
    });

    test('扩容等级每级 +20 半径，上限 110', () {
      final missile = MissileWeapon();
      expect(missile.explosionRadius, 70);

      missile.radiusBonus = 20;
      expect(missile.explosionRadius, 90);

      missile.radiusBonus = 40;
      expect(missile.explosionRadius, 110);

      missile.radiusBonus = 100; // 越界输入
      expect(missile.explosionRadius, 110, reason: '硬上限 110');
    });

    test('无目标时向上直行', () {
      final missile = MissileWeapon();
      final requests = missile.step(
        playerPosition: const Vec2(960, 900),
        targets: const <TargetView>[],
        dt: kStep,
      );

      expect(requests.single.direction, const Vec2(0, -1));
      expect(requests.single.targetId, isNull);
    });

    test('最大转向率 300°/s：单步最多转 5°', () {
      final missile = MissileWeapon();
      // 导弹朝上，目标在正右方 → 需要转 90°。
      final steered = missile.steer(
        currentDirection: const Vec2(0, -1),
        missilePosition: const Vec2(0, 0),
        target: enemy(1, 1000, 0),
        dt: kStep,
      );

      final angle = math.atan2(steered.y, steered.x);
      // 当前角 -90°，单步最多 +5° → -85°。
      expect(angle * 180 / math.pi, closeTo(-85, 0.5));
    });

    test('达到目标方向后不再过度转向', () {
      final missile = MissileWeapon();
      // 目标就在正上方，方向已经是正上方 → 不应改变。
      final steered = missile.steer(
        currentDirection: const Vec2(0, -1),
        missilePosition: const Vec2(0, 0),
        target: enemy(1, 0, -1000),
        dt: kStep,
      );

      expect(steered.x, closeTo(0, 1e-9));
      expect(steered.y, closeTo(-1, 1e-9));
    });
  });

  group('持续激光（§4.3）', () {
    test('周期 5.0 秒、持续 1.2 秒、0.1 秒 tick、每 tick 6 伤害、宽 28', () {
      final laser = LaserWeapon();
      expect(laser.periodSeconds, 5.0);
      expect(laser.activeSeconds, 1.2);
      expect(laser.tickSeconds, 0.1);
      expect(laser.damagePerTick, 6);
      expect(laser.width, 28);
      expect(laser.range, 900);
    });

    test('无目标时不激活、不结算伤害', () {
      final laser = LaserWeapon();
      for (var i = 0; i < 120; i++) {
        final result = laser.step(
          playerPosition: const Vec2(960, 900),
          targets: const <TargetView>[],
          dt: kStep,
        );
        expect(result, isNull);
      }
      expect(laser.isActive, isFalse);
    });

    test('有目标时激活，并按 0.1 秒 tick 结算 6 伤害', () {
      final laser = LaserWeapon();
      final targets = <TargetView>[enemy(1, 960, 300)];

      // 激活瞬间不结算伤害。
      expect(
        laser.step(
          playerPosition: const Vec2(960, 900),
          targets: targets,
          dt: kStep,
        ),
        isNull,
      );
      expect(laser.isActive, isTrue);

      var ticks = 0;
      for (var i = 0; i < 72; i++) {
        final result = laser.step(
          playerPosition: const Vec2(960, 900),
          targets: targets,
          dt: kStep,
        );
        if (result != null && result.primary != null) {
          ticks++;
          expect(result.primary!.damage, 6);
        }
      }

      // 1.2 秒 / 0.1 秒 = 12 次 tick。
      expect(ticks, 12);
    });

    test('目标死亡后同一步按同一优先级重锁', () {
      final laser = LaserWeapon();
      final player = const Vec2(960, 900);

      // 激活并锁定目标 1。
      laser.step(
        playerPosition: player,
        targets: <TargetView>[enemy(1, 960, 300)],
        dt: kStep,
      );
      // 推进到第一次 tick。
      for (var i = 0; i < 7; i++) {
        laser.step(
          playerPosition: player,
          targets: <TargetView>[enemy(1, 960, 300)],
          dt: kStep,
        );
      }

      // 目标 1 消失，只剩目标 2。
      LaserTickResult? relocked;
      for (var i = 0; i < 12; i++) {
        relocked = laser.step(
          playerPosition: player,
          targets: <TargetView>[enemy(2, 500, 300)],
          dt: kStep,
        );
        if (relocked?.primary != null) {
          break;
        }
      }

      expect(relocked?.primary?.targetId.sequence, 2);
    });

    test('棱镜折射：等级 1/2 对应 1/2 跳，每跳伤害 ×0.60', () {
      final laser = LaserWeapon()..prismHops = 2;
      final player = const Vec2(960, 900);
      final targets = <TargetView>[
        enemy(1, 960, 300),
        enemy(2, 1060, 300), // 距主目标 100
        enemy(3, 1160, 300), // 距第二个 100
      ];

      laser.step(playerPosition: player, targets: targets, dt: kStep);
      LaserTickResult? tick;
      for (var i = 0; i < 12; i++) {
        tick = laser.step(
          playerPosition: player,
          targets: targets,
          dt: kStep,
        );
        if (tick?.primary != null) {
          break;
        }
      }

      expect(tick!.primary!.damage, 6);
      expect(tick.refracts.length, 2);
      expect(tick.refracts[0].damage, (6 * 0.60).round());
      expect(
        tick.refracts[1].damage,
        ((6 * 0.60).round() * 0.60).round(),
      );
      expect(tick.refracts.every((h) => h.isRefraction), isTrue);
    });

    test('折射候选半径 360，超出则不跳', () {
      final laser = LaserWeapon()..prismHops = 1;
      final player = const Vec2(960, 900);
      final targets = <TargetView>[
        enemy(1, 960, 300),
        enemy(2, 960, 800), // 距主目标 500 > 360
      ];

      laser.step(playerPosition: player, targets: targets, dt: kStep);
      LaserTickResult? tick;
      for (var i = 0; i < 12; i++) {
        tick = laser.step(
          playerPosition: player,
          targets: targets,
          dt: kStep,
        );
        if (tick?.primary != null) {
          break;
        }
      }

      expect(tick!.refracts, isEmpty);
    });
  });

  group('电弧暴击（§4.3）', () {
    const arc = ArcWeapon();

    test('伤害为触发脉冲最终结算伤害的 50%', () {
      final hit = arc.resolve(
        hitTarget: const EntityId(EntityKind.enemy, 1),
        hitPosition: const Vec2(500, 500),
        finalPulseDamage: 16, // 9 × 1.8 取整后的"最终结算伤害"
        targets: <TargetView>[enemy(1, 500, 500), enemy(2, 600, 500)],
      );

      expect(hit, isNotNull);
      expect(hit!.damage, 8);
      expect(hit.targetId.sequence, 2);
    });

    test('无候选时只保留暴击本身（返回 null）', () {
      final hit = arc.resolve(
        hitTarget: const EntityId(EntityKind.enemy, 1),
        hitPosition: const Vec2(500, 500),
        finalPulseDamage: 16,
        targets: <TargetView>[enemy(1, 500, 500)],
      );

      expect(hit, isNull);
    });

    test('候选半径 360，且排除已命中的目标', () {
      final hit = arc.resolve(
        hitTarget: const EntityId(EntityKind.enemy, 1),
        hitPosition: const Vec2(500, 500),
        finalPulseDamage: 16,
        targets: <TargetView>[
          enemy(1, 500, 500), // 已命中，须排除
          enemy(2, 900, 500), // 距离 400 > 360
        ],
      );

      expect(hit, isNull);
    });
  });

  group('轨道无人机（§4.3）', () {
    test('半径 120、角速度 120°/s、每 0.8 秒 12 伤害', () {
      final drone = DroneWeapon();
      expect(drone.orbitRadius, 120);
      expect(drone.angularSpeedDegreesPerSecond, 120);
      expect(drone.cadence, 0.8);
      expect(drone.damage, 12);
      expect(drone.range, 600);
    });

    test('新增无人机与已有机体均匀分布', () {
      final drone = DroneWeapon();
      const player = Vec2(960, 900);

      drone.setCount(1);
      expect(drone.positionOf(0, player).x, closeTo(1080, 1e-9));

      drone.setCount(2);
      final a = drone.positionOf(0, player);
      final b = drone.positionOf(1, player);
      // 两架相隔 180°。
      expect((a - b).length, closeTo(240, 1e-6));
    });

    test('无目标不发射', () {
      final drone = DroneWeapon()..setCount(2);
      final requests = drone.step(
        playerPosition: const Vec2(960, 900),
        targets: const <TargetView>[],
        dt: kStep,
      );

      expect(requests, isEmpty);
    });

    test('有目标时按 0.8 秒节奏发射，每架独立计时', () {
      final drone = DroneWeapon()..setCount(1);
      final targets = <TargetView>[enemy(1, 960, 300)];
      const player = Vec2(960, 900);

      var shots = 0;
      // 2 秒 = 120 步，按 0.8 秒节奏应发射 2 次（t=0.8, 1.6）。
      for (var i = 0; i < 120; i++) {
        shots += drone.step(
          playerPosition: player,
          targets: targets,
          dt: kStep,
        ).length;
      }

      expect(shots, 2);
    });

    test('数量为 0 时不产生任何请求', () {
      final drone = DroneWeapon();
      expect(
        drone.step(
          playerPosition: const Vec2(960, 900),
          targets: <TargetView>[enemy(1, 960, 300)],
          dt: kStep,
        ),
        isEmpty,
      );
    });
  });
}
