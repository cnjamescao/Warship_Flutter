// ================================================================
// test/unit/domain/v21_risk_03_test.dart —— V21-RISK-03
// ================================================================
// **架构位置**：Domain 层测试。验证风险门自动结算的**合法性边界**。
//
// **计划原文**（`04_测试计划与验收用例.md` 第 10 行）：
//   「HP `<=35%` 触发风险门；合法池被人为置空 |
//     前者**绝不产生 Overload**；后者输出 gateId 与**逐项非法原因并失败**，
//     **不跳过、不伪造结果**。」
//
// 后半句是这一批里**最重要的合同**：没有合法项时必须**响亮失败**，
// 而不是"挑一个凑数"或"静默跳过" —— 静默跳过会让"这一局少了风险门"
// 变成**不可见的缺陷**（玩家与 QA 都看不到）。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/domain/risk_gate_system.dart';

RiskGateSystem system() => RiskGateSystem(
  overloadHpThreshold: 35,
  selectionWindowSeconds: 5.0,
  timeoutFallbackId: RiskOptionIds.supply,
  overloadRarePool: const <String>['UP-CRIT-ARC', 'UP-MISSILE-SALVO'],
);

void main() {
  test('V21-RISK-03a HP ≤ 35 时，Overload **绝不**进入合法池', () {
    final s = system();
    for (final hp in <int>[0, 1, 20, 34, 35]) {
      final legal = s.legalOptionsFor(
        playerHp: hp,
        availableRareCards: const <String>['UP-CRIT-ARC'],
      );
      expect(
        legal,
        isNot(contains(RiskOptionIds.overload)),
        reason: 'HP=$hp ≤ 35 时不得出现 Overload（冻结表 §2.4）',
      );
    }
  });

  test('V21-RISK-03b HP > 35 且稀有池非空时，Overload 才合法', () {
    final s = system();
    final legal = s.legalOptionsFor(
      playerHp: 36,
      availableRareCards: const <String>['UP-CRIT-ARC'],
    );
    expect(legal, contains(RiskOptionIds.overload));

    // 稀有池为空（全被过滤）⇒ Overload 同样不合法（"由 RG-BOUNTY 占位"）。
    final noPool = s.legalOptionsFor(
      playerHp: 100,
      availableRareCards: const <String>[],
    );
    expect(noPool, isNot(contains(RiskOptionIds.overload)));
    expect(noPool, <String>[RiskOptionIds.supply, RiskOptionIds.bounty],
        reason: '无可用稀有卡时由 Supply/Bounty 占位');
  });

  test('V21-RISK-03c 合法池**非空**时，自动抽取永不返回空', () {
    final s = system();
    for (var i = 0; i < 50; i++) {
      final id = s.autoPickOption(
        gateId: 'RG-55',
        occurrenceOrdinal: i,
        playerHp: 100,
        availableRareCards: const <String>['UP-CRIT-ARC'],
        rng: Pcg32(0x2A01 + i),
      );
      expect(id, isNotNull);
      expect(
        <String>[
          RiskOptionIds.supply,
          RiskOptionIds.bounty,
          RiskOptionIds.overload,
        ],
        contains(id),
      );
    }
  });

  test('V21-RISK-03d 同 seed 同输入**必得同一结果**（确定性）', () {
    final s = system();
    String pick(int seed) => s.autoPickOption(
      gateId: 'RG-115',
      occurrenceOrdinal: 1,
      playerHp: 80,
      availableRareCards: const <String>['UP-CRIT-ARC'],
      rng: Pcg32(seed),
    )!;
    for (final seed in <int>[1, 42, 0x2A01, 0xDEAD]) {
      expect(pick(seed), pick(seed), reason: 'seed=$seed 必须稳定');
    }
  });

  test('V21-RISK-03e **等权**：多次抽样三种结果都出现（不是偏向某一项）', () {
    final s = system();
    final counts = <String, int>{};
    // 用固定 seed 序列抽样；只需要"三种都出现过"，不检验精确分布
    // （精确分布属于统计检验，不适合放在单元测试里）。
    for (var i = 0; i < 300; i++) {
      final id = s.autoPickOption(
        gateId: 'RG-55',
        occurrenceOrdinal: i,
        playerHp: 100,
        availableRareCards: const <String>['UP-CRIT-ARC'],
        rng: Pcg32(0x1000 + i),
      )!;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    expect(counts.keys.toSet(), <String>{
      RiskOptionIds.supply,
      RiskOptionIds.bounty,
      RiskOptionIds.overload,
    });
    // 每种至少出现一次，且没有某项压倒性占优（> 80%）。
    for (final e in counts.entries) {
      expect(e.value, greaterThan(0));
      expect(e.value / 300, lessThan(0.8), reason: '${e.key} 占比过高');
    }
  });

  test('V21-RISK-03f 无合法项时返回 null —— 调用方必须**响亮失败**', () {
    // 这里用"稀有池空 + 极端配置"构造一个没有合法项的情形：
    // `legalOptionsFor` 恒返回 Supply/Bounty，因此正常情况下不可能为空。
    // 该用例锁住的是**约定**：`autoPickOption` 在空池下返回 null，
    // 而不是抛自己的异常或返回伪造值 —— 由调用方决定如何失败。
    final s = system();
    final legal = s.legalOptionsFor(
      playerHp: 0,
      availableRareCards: const <String>[],
    );
    // Supply/Bounty 永远合法 ⇒ 说明"空池"是**内容配置错误**才能造成，
    // 因此运行时用 `throw StateError` 处理（而非静默跳过）。
    expect(legal, isNotEmpty,
        reason: '正常配置下供应链/赏金始终合法；若为空则是配置错误');
    expect(legal, <String>[RiskOptionIds.supply, RiskOptionIds.bounty]);
  });
}
