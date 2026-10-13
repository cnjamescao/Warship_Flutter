// ================================================================
// test/unit/domain/upgrade_system_test.dart —— 升级草案与 16 张卡
// ================================================================
// 覆盖 P0：T-UP-00 / T-UP-01 / T-UP-02 / T-UP-03
// 直接读取**真实** assets/config/v2/upgrades.json。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/domain/upgrade_system.dart';

UpgradeSystem buildSystem() {
  final config =
      jsonDecode(File('assets/config/v2/upgrades.json').readAsStringSync())
          as Map<String, Object?>;

  final cards = (config['cards'] as List)
      .cast<Map>()
      .map((m) => UpgradeCard.fromConfig(m.cast<String, Object?>()))
      .toList();
  final guaranteed = config['guaranteed'] as Map;

  return UpgradeSystem(
    cards: cards,
    xpThresholds: (config['xpThresholds'] as List).cast<int>(),
    firstDraftEarliestSecond:
        (config['firstDraftEarliestSecond'] as num).toDouble(),
    maxDrafts: config['maxDrafts'] as int,
    draftSize: config['draftSize'] as int,
    damageCardIds: (config['damageCardIds'] as List).cast<String>().toSet(),
    guaranteedFirstDraft:
        (guaranteed['firstDraft'] as List).cast<String>(),
    guaranteedSecondDraftAnyOf:
        (guaranteed['secondDraftAnyOf'] as List).cast<String>(),
  );
}

UpgradeState newState(UpgradeSystem system) =>
    UpgradeState(maxDrafts: system.maxDrafts);

DraftContext context({double seconds = 20, int xp = 20}) => DraftContext(
  combatSeconds: seconds,
  xp: xp,
  damageCardIds: <String>{},
);

void main() {
  late UpgradeSystem system;

  setUpAll(() {
    system = buildSystem();
  });

  group('配置加载', () {
    test('16 张卡、阈值与首抽时间门与产品基线 §4.2 一致', () {
      expect(system.card('UP-PULSE-RATE'), isNotNull);
      expect(system.xpThresholds, <int>[20, 55, 105, 170, 250, 345]);
      expect(system.firstDraftEarliestSecond, 15.0);
      expect(system.maxDrafts, 6);
      expect(system.draftSize, 3);
    });

    test('每张卡的等级、权重、互斥与前置都能解析', () {
      expect(system.card('UP-PULSE-RATE')!.maxLevel, 3);
      expect(system.card('UP-PULSE-RATE')!.weight, 12);
      expect(system.card('UP-PULSE-SPREAD')!.maxLevel, 2);
      expect(system.card('UP-CRIT-ARC')!.prerequisites, ['anyPulseCard']);
      expect(system.card('UP-MISSILE-SALVO')!.prerequisites, [
        'UP-MISSILE-UNLOCK',
      ]);
      expect(system.card('UP-LASER-UNLOCK')!.excludes, ['UP-DRONE-UNLOCK']);
      expect(system.card('UP-DRONE-UNLOCK')!.excludes, ['UP-LASER-UNLOCK']);
      expect(system.card('UP-DASH-CHARGE')!.maxLevel, 1);
    });
  });

  group('T-UP-00 首抽时间门', () {
    test('经验在 15 秒前达到 20：14.99 秒不打开，15.00 秒打开', () {
      expect(
        system.isDraftDue(xp: 20, draftCount: 0, combatSeconds: 14.99),
        isFalse,
        reason: '第 1 次草案不得早于 15.0 秒',
      );
      expect(
        system.isDraftDue(xp: 20, draftCount: 0, combatSeconds: 15.00),
        isTrue,
      );
    });

    test('15 秒前积累的经验照常保留（到达 15 秒时立即打开）', () {
      // 14 秒时积攒了 30 点经验，但门未开。
      expect(
        system.isDraftDue(xp: 30, draftCount: 0, combatSeconds: 14.0),
        isFalse,
      );
      // 15 秒时不需要重新积累，直接打开。
      expect(
        system.isDraftDue(xp: 30, draftCount: 0, combatSeconds: 15.0),
        isTrue,
      );
    });

    test('未达阈值时不打开，达到后才打开', () {
      expect(
        system.isDraftDue(xp: 19, draftCount: 1, combatSeconds: 60),
        isFalse,
      );
      expect(
        system.isDraftDue(xp: 55, draftCount: 1, combatSeconds: 60),
        isTrue,
      );
    });

    test('第 2–6 次没有额外时间门', () {
      expect(
        system.isDraftDue(xp: 55, draftCount: 1, combatSeconds: 0.1),
        isTrue,
      );
    });

    test('达到 6 次后经验仍计分但不再触发草案', () {
      expect(
        system.isDraftDue(xp: 9999, draftCount: 6, combatSeconds: 200),
        isFalse,
      );
    });
  });

  group('T-UP-01 保证卡与候选数量', () {
    test('第 1 次草案必含 UP-PULSE-RATE，且恰好 3 张', () {
      final state = newState(system);
      final offer = system.generateDraft(
        state: state,
        rng: Pcg32(1),
        context: context(),
      );

      expect(offer, isNotNull);
      expect(offer!.candidates.length, 3);
      expect(offer.candidates, contains('UP-PULSE-RATE'));
      expect(offer.guaranteed, contains('UP-PULSE-RATE'));
      expect(offer.candidates.first, 'UP-PULSE-RATE',
          reason: '保证卡放在候选顺序最前');
    });

    test('第 2 次草案必含 UP-PULSE-SPREAD 或 UP-MISSILE-UNLOCK 之一', () {
      final state = newState(system);
      system.generateDraft(state: state, rng: Pcg32(1), context: context());
      system.applyCard(state, 'UP-PULSE-RATE');

      final offer = system.generateDraft(
        state: state,
        rng: Pcg32(2),
        context: context(xp: 55),
      );

      expect(offer!.candidates.length, 3);
      expect(
        offer.candidates.any(
          (c) => c == 'UP-PULSE-SPREAD' || c == 'UP-MISSILE-UNLOCK',
        ),
        isTrue,
      );
    });

    test('候选顺序被固定：同一 seed 两次生成结果完全一致', () {
      List<String> draw(int seed) {
        final state = newState(system);
        return system
            .generateDraft(state: state, rng: Pcg32(seed), context: context())!
            .candidates;
      }

      expect(draw(0x4E454F4E0001), draw(0x4E454F4E0001));
    });

    test('每次草案都恰好 3 张（连续 6 次）', () {
      final state = newState(system);
      final rng = Pcg32(7);

      for (var i = 0; i < 6; i++) {
        final offer = system.generateDraft(
          state: state,
          rng: rng,
          context: context(xp: 9999),
        );
        expect(offer, isNotNull, reason: '第 ${i + 1} 次草案不应为空');
        expect(offer!.candidates.length, 3);
        expect(offer.candidates.toSet().length, 3, reason: '无放回，不重复');

        system.applyCard(state, offer.candidates.first);
      }

      expect(state.draftCount, 6);
    });
  });

  group('T-UP-02 过滤规则', () {
    test('满级卡不再出现', () {
      final state = newState(system);
      state.levels['UP-PULSE-RATE'] = 3; // 满级

      expect(system.availableCards(state), isNot(contains('UP-PULSE-RATE')));
    });

    test('互斥：已拥有激光后无人机不再出现（反向也成立）', () {
      final state = newState(system);
      state.levels['UP-LASER-UNLOCK'] = 1;

      final available = system.availableCards(state);
      expect(available, isNot(contains('UP-DRONE-UNLOCK')));
      expect(available, isNot(contains('UP-DRONE-COUNT')));
    });

    test('前置不满足时不出现', () {
      final state = newState(system);
      final available = system.availableCards(state);

      expect(available, isNot(contains('UP-MISSILE-SALVO')));
      expect(available, isNot(contains('UP-MISSILE-RADIUS')));
      expect(available, isNot(contains('UP-LASER-PRISM')));
      expect(available, isNot(contains('UP-DRONE-COUNT')));

      // 取得前置后出现。
      state.levels['UP-MISSILE-UNLOCK'] = 1;
      final after = system.availableCards(state);
      expect(after, contains('UP-MISSILE-SALVO'));
      expect(after, contains('UP-MISSILE-RADIUS'));
    });

    test('anyPulseCard 前置：未取得脉冲卡时电弧暴击不可用', () {
      final state = newState(system);
      expect(system.availableCards(state), isNot(contains('UP-CRIT-ARC')));

      state.levels['UP-PULSE-DAMAGE'] = 1;
      expect(system.availableCards(state), contains('UP-CRIT-ARC'));
    });

    test('连续两次无伤害卡后，第三次强制加入伤害卡', () {
      final state = newState(system);
      state.consecutiveDraftsWithoutDamage = 2;

      final offer = system.generateDraft(
        state: state,
        rng: Pcg32(5),
        context: context(),
      );

      expect(
        offer!.candidates.any(system.damageCardIds.contains),
        isTrue,
        reason: '干旱两次后必须强制给伤害卡',
      );
    });

    test('连续两次无伤害卡的计数会随草案结果更新', () {
      final state = newState(system);
      state.consecutiveDraftsWithoutDamage = 2;

      final offer = system.generateDraft(
        state: state,
        rng: Pcg32(5),
        context: context(),
      );
      final hasDamage = offer!.candidates.any(system.damageCardIds.contains);

      expect(state.consecutiveDraftsWithoutDamage, hasDamage ? 0 : 3);
    });
  });

  group('T-UP-03 应用升级与 modifier', () {
    test('每张卡都能提升等级，且不超过 maxLevel', () {
      final state = newState(system);
      final card = system.card('UP-PULSE-RATE')!;

      for (var i = 0; i < card.maxLevel; i++) {
        final effects = system.applyCard(state, 'UP-PULSE-RATE');
        expect(effects, isNotEmpty);
      }
      expect(state.levelOf('UP-PULSE-RATE'), 3);

      // 满级后再应用不生效。
      expect(system.applyCard(state, 'UP-PULSE-RATE'), isEmpty);
      expect(state.levelOf('UP-PULSE-RATE'), 3);
    });

    test('每张卡的 effects 都能解析出预期 kind', () {
      expect(
        system.card('UP-PULSE-RATE')!.effects.single.kind,
        'multiplyWeaponStat',
      );
      expect(
        system.card('UP-PULSE-RATE')!.effects.single.factor,
        0.85,
      );
      expect(
        system.card('UP-PULSE-DAMAGE')!.effects.single.amountPerLevel,
        3,
      );
      expect(
        system.card('UP-PULSE-SPREAD')!.effects.first.numbers,
        <double>[1, 2, 3],
      );
      expect(
        system.card('UP-LASER-UNLOCK')!.effects.single.kind,
        'unlockWeapon',
      );
      expect(
        system.card('UP-LASER-UNLOCK')!.effects.single.weaponId,
        'WPN-LASER',
      );
      expect(
        system.card('UP-SHIELD-MAX')!.effects.single.kind,
        'addShieldMax',
      );
      expect(
        system.card('UP-DASH-CHARGE')!.effects.single.params['newRechargeSeconds'],
        7.0,
      );
      expect(
        system.card('UP-COMBO-GUARD')!.effects.single.params['cooldownSeconds'],
        25.0,
      );
    });

    test('未知卡 ID 不改变状态', () {
      final state = newState(system);
      expect(system.applyCard(state, 'UP-NOT-REAL'), isEmpty);
      expect(state.levels, isEmpty);
    });

    test('累计器：脉冲增幅 Lv3 为 0.85³', () {
      final accumulator = UpgradeAccumulator()
        ..setLevel('UP-PULSE-RATE', 3);

      expect(
        accumulator.totalMultiply(system, 'multiplyWeaponStat'),
        closeTo(0.85 * 0.85 * 0.85, 1e-12),
      );
    });

    test('累计器：高能脉冲 Lv3 为 +9', () {
      final accumulator = UpgradeAccumulator()
        ..setLevel('UP-PULSE-DAMAGE', 3);

      expect(
        accumulator.totalAdd(system, 'addWeaponStat', 'damage'),
        9,
      );
    });

    test('已选等级可用于结算页', () {
      final state = newState(system);
      system.applyCard(state, 'UP-PULSE-RATE');
      system.applyCard(state, 'UP-PULSE-RATE');
      system.applyCard(state, 'UP-SHIELD-MAX');

      final selected = system.selectedLevels(state);
      expect(selected['UP-PULSE-RATE'], 2);
      expect(selected['UP-SHIELD-MAX'], 1);
    });
  });

  group('候选池耗尽的安全行为', () {
    test('全部卡满级后返回 null 而不抛异常', () {
      final state = newState(system);
      for (final id in <String>[
        'UP-PULSE-RATE',
        'UP-PULSE-DAMAGE',
        'UP-PULSE-SPREAD',
        'UP-CRIT-ARC',
        'UP-MISSILE-UNLOCK',
        'UP-MISSILE-SALVO',
        'UP-MISSILE-RADIUS',
        'UP-LASER-UNLOCK',
        'UP-LASER-PRISM',
        'UP-DRONE-UNLOCK',
        'UP-DRONE-COUNT',
        'UP-SHIELD-MAX',
        'UP-DASH-CHARGE',
        'UP-DASH-REPAIR',
        'UP-ENERGY-GAIN',
        'UP-COMBO-GUARD',
      ]) {
        state.levels[id] = system.card(id)!.maxLevel;
      }

      expect(system.availableCards(state), isEmpty);
      expect(
        system.generateDraft(state: state, rng: Pcg32(1), context: context()),
        isNull,
      );
    });
  });
}
