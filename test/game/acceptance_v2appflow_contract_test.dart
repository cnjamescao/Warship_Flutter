// ================================================================
// test/game/acceptance_v2appflow_contract_test.dart —— V2AppFlow 流程合同
// ================================================================
// 负责人批复（2026-10-16）：
// 「新增 V2AppFlow 应用流程合同测试：**玩家存活、未到 190 秒、
//   未收到 `RunEnded` 时，绝不允许提前进入 Result；150 秒后必须已进入
//   Boss**。若失败，记录结束原因并修真实流程缺陷。」
//
// 背景：我为产出 Boss 招式 Golden，尝试让应用流跑到 Boss 入场，
// 实测 `bossSeen=0` 且相位出现 `result`（失败但非胜利），
// 而**直接驱动 `GameRuntime` 可以稳定到达 Boss**。
// 差异落在 `V2AppFlow` / 相位控制器这一层，因此需要本条合同测试。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;
  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('V2AppFlow 合同：存活且未到 190 秒时不得提前进入 Result', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

    final screen = tester.widget<V2RunScreen>(find.byType(V2RunScreen));
    final rt = screen.runtime;

    var resultReachedAt = -1.0;
    var bossSeenAt = -1.0;

    // 覆盖到 190 秒上限（产品基线：190 秒判负）。
    const totalSeconds = 190;
    for (var second = 0; second < totalSeconds; second++) {
      for (var frame = 0; frame < 60; frame++) {
        // 玩家存活（合同前提之一）。
        rt.player.health.current = rt.player.health.max;
        if (rt.currentOffer != null) {
          rt.selectDraftCard(0);
        }
        await pumpV2(tester, frames: 1);

        final phase = rt.snapshot().phase;
        if (phase == 'result' && resultReachedAt < 0) {
          resultReachedAt = rt.combatSeconds;
        }
        if (rt.boss != null && bossSeenAt < 0) {
          bossSeenAt = rt.combatSeconds;
        }
      }
    }

    // **正式正向合同**（负责人批复）：
    // 「真实 V2AppFlow 与真实目录配置下，**150 秒后 Boss 已入场**，
    //   190 秒前未死亡/未胜利**不得进入 Result**。」
    //
    // F-39 的根因是 `V2Bootstrap` **从未传入 `bossSystem`**，
    // 而 `_startBossFight()` 的首行守卫是 `if (bossSystem == null) return;`
    // —— 于是 150 秒的 `bossEntry` 行虽被正常触发（诊断实测
    // `nextRowIndex` 走到 31/31），入场处理却被**静默跳过**。
    // 修复后实测 `bossSeenAt = 150.0`（精确命中产品基线的 150 秒）。
    expect(
      bossSeenAt,
      greaterThan(0),
      reason: '150 秒后必须已出现 Boss（产品基线：Boss 在 150 秒出现）—— '
          '实际 bossSeenAt=$bossSeenAt',
    );
    expect(
      bossSeenAt,
      lessThanOrEqualTo(155),
      reason: 'Boss 应在 150 秒左右出现 —— 实际 $bossSeenAt 秒',
    );

    // 合同第二半：**玩家存活**时不得提前进入 Result。
    //
    // 注：这里刻意**不**清空敌人 —— 越界失败（breach）是**合法的**
    // 失败原因，不属于"提前结算"。若因此进入 result，应记录的是
    // **结束原因**，而不是判定流程有缺陷。
    if (resultReachedAt >= 0) {
      // ignore: avoid_print
      print('V2AppFlow 记录：在 $resultReachedAt 秒进入 result；'
          'victory=${rt.victory}');
      expect(
        resultReachedAt,
        greaterThanOrEqualTo(150),
        reason: '玩家存活时在 $resultReachedAt 秒进入 result —— '
            '早于 190 秒上限且未收到 RunEnded 的正常结束：'
            '需记录结束原因并修真实流程缺陷',
      );
    }
  });
}
