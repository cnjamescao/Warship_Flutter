// ================================================================
// test/unit/domain/v21_auto_grant_test.dart —— V21-AU-01/03/04
// ================================================================
// **架构位置**：Domain 层测试。验证 v2.1 的**自动强化单张授予**规则
// （冻结表 §2.2）。
//
// **为什么必须测**：v2.1 把"三选一草案"换成"达标即单张授予"。
// 逐序号的强制规则（0→Pulse Rate、1→两张保证卡、2→五形态池、3–5→常规）
// 一旦写错，玩家会**安静地拿到不对的强化** —— 不会报错、不会崩溃。
//
// **每条断言都能失败**（R6.2）：改错序号分支、改错池、或静默跳过空池，
// 本文件即失败。
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
    guaranteedFirstDraft: (guaranteed['firstDraft'] as List).cast<String>(),
    guaranteedSecondDraftAnyOf:
        (guaranteed['secondDraftAnyOf'] as List).cast<String>(),
  );
}

/// 应用一次授予（生产路径同样由调用方 applyCard 一次）。
void apply(UpgradeSystem system, UpgradeState state, AutoUpgradeGrant g) {
  state.levels[g.cardId] = g.level;
  state.grantCount++;
  final card = system.card(g.cardId)!;
  if (card.countsAsDamage || _damageIds.contains(g.cardId)) {
    state.consecutiveGrantsWithoutDamage = 0;
  } else {
    state.consecutiveGrantsWithoutDamage++;
  }
  if (g.styleId != null) {
    state.mainWeaponStyleId = g.styleId;
  }
}

/// 伤害类卡的 ID 名单来自配置（测试侧复制一份，避免依赖私有字段）。
Set<String> _damageIds = const <String>{};

void main() {
  late UpgradeSystem system;
  setUpAll(() {
    system = buildSystem();
    final config =
        jsonDecode(File('assets/config/v2/upgrades.json').readAsStringSync())
            as Map<String, Object?>;
    _damageIds = (config['damageCardIds'] as List).cast<String>().toSet();
  });

  test('V21-AU-01 六个序号的固定规则（冻结表 §2.2）', () {
    final state = UpgradeState(maxDrafts: system.maxDrafts);
    final rng = Pcg32(20261017);
    const styleIds = <String>[
      'UP-WSTYLE-PRISM',
      'UP-WSTYLE-ARC',
      'UP-WSTYLE-PLASMA',
      'UP-WSTYLE-NEEDLE',
      'UP-WSTYLE-MISSILE',
    ];

    for (var ordinal = 0; ordinal < 6; ordinal++) {
      final g = system.grantAutomatic(state: state, rng: rng);
      expect(g.grantOrdinal, ordinal, reason: 'grantOrdinal 必须递增且等于当前次数');

      switch (ordinal) {
        case 0:
          expect(g.cardId, 'UP-PULSE-RATE', reason: '第 0 次必须强制 Pulse Rate');
        case 1:
          expect(
            <String>['UP-PULSE-SPREAD', 'UP-MISSILE-UNLOCK'],
            contains(g.cardId),
            reason: '第 1 次只能来自两张保证卡',
          );
        case 2:
          expect(
            styleIds,
            contains(g.cardId),
            reason: '第 2 次必须强制进入五形态池',
          );
          expect(g.styleId, isNotNull, reason: '形态卡必须带 styleId');
        default:
          expect(g.level, greaterThanOrEqualTo(1));
      }
      apply(system, state, g);
    }

    expect(state.grantCount, 6, reason: '一局最多 6 次自动强化');
    expect(state.mainWeaponStyleId, isNotNull, reason: '第 3 张应确立主弹道形态');
  });

  test('V21-AU-03 达到上限后不再授予（且必须响亮失败）', () {
    final state = UpgradeState(maxDrafts: system.maxDrafts);
    final rng = Pcg32(1);
    for (var i = 0; i < 6; i++) {
      apply(system, state, system.grantAutomatic(state: state, rng: rng));
    }
    expect(state.isMaxed, isTrue);
    // 不得静默返回 null —— 调用方本就不该再问；问了就是缺陷。
    expect(
      () => system.grantAutomatic(state: state, rng: rng),
      throwsA(isA<StateError>()),
    );
  });

  test('V21-AU-04 空池必须抛 StateError 且信息含 grantOrdinal 与可用 ID', () {
    final state = UpgradeState(maxDrafts: system.maxDrafts);
    final rng = Pcg32(2);
    // 把所有卡拉满 → 可用池为空。
    for (final id in system.allCardIds) {
      state.levels[id] = system.card(id)!.maxLevel;
    }
    expect(system.availableCards(state), isEmpty);

    late StateError err;
    try {
      system.grantAutomatic(state: state, rng: rng);
      fail('空池必须抛 StateError，不得静默跳过或"安全回退"');
    } on StateError catch (e) {
      err = e;
    }
    expect(err.message, contains('grantOrdinal'));
    expect(err.message, contains('可用 ID'));
  });

  test('V21-AU-04b 第 1 次的两张保证卡都不可用时同样响亮失败', () {
    final state = UpgradeState(maxDrafts: system.maxDrafts);
    final rng = Pcg32(3);
    // 先正常拿第 0 张（Pulse Rate）。
    apply(system, state, system.grantAutomatic(state: state, rng: rng));
    // 人为把两张保证卡拉满 → 第 1 次无候选。
    for (final id in <String>['UP-PULSE-SPREAD', 'UP-MISSILE-UNLOCK']) {
      state.levels[id] = system.card(id)!.maxLevel;
    }
    expect(
      () => system.grantAutomatic(state: state, rng: rng),
      throwsA(isA<StateError>()),
      reason: '两张保证卡都不可用属配置/状态异常，必须响亮失败',
    );
  });

  test('V21-AU-02 全程不产生任何 DraftOffer（v2.1 禁止三选一）', () {
    // 结构性保证：grantAutomatic 的返回类型里没有候选列表，
    // 因此编译器层面就无法"顺手"产出草案。
    final state = UpgradeState(maxDrafts: system.maxDrafts);
    final rng = Pcg32(4);
    final g = system.grantAutomatic(state: state, rng: rng);
    expect(g, isA<AutoUpgradeGrant>());
    expect(g.cardId, isA<String>());
    // 授予后 state 未变 —— 由调用方负责 applyCard 一次。
    expect(state.grantCount, 0);
  });
}
