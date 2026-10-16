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
import 'package:warship_flutter/game/core/domain_event.dart';
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
    var victorySeen = false;
    final earlyResults = <String>[];

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
        // **复核补正**：`combatSeconds < 190.0` 的**每一步**都不得进入
        // Result —— 除非有明确的 `RunEnded(victory)`。
        // 旧断言只要求 `>= 150`，会错误放行 150.0–189.999 秒进入 Result，
        // 与「190 秒判负」冲突。
        if (phase == 'result' && rt.combatSeconds < 190.0 && !victorySeen) {
          earlyResults.add(
            '${rt.combatSeconds.toStringAsFixed(1)}s（'
            'victory=${rt.victory}）',
          );
        }
        if (rt.boss != null && bossSeenAt < 0) {
          bossSeenAt = rt.combatSeconds;
        }
        if (rt.victory) {
          victorySeen = true;
        }
        for (final stamped in rt.lastFrameEvents) {
          if (stamped.event is RunEnded &&
              (stamped.event as RunEnded).result == 'victory') {
            victorySeen = true;
          }
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

    // **合同第二半（复核补正后）**：
    // 「在测试驱动保持玩家存活的前提下，`combatSeconds < 190.0` 的每个
    //   逻辑/渲染步中 `phase != result`；若发生 Result，必须是
    //   `combatSeconds >= 190.0`，或有明确的 `RunEnded(victory)`。
    //   **不得以 `>=150` 代替 190 秒上限。**」
    expect(
      earlyResults,
      isEmpty,
      reason: '玩家存活且未胜利时，在 190 秒前进入了 Result —— '
          '与产品「190 秒判负」冲突（复核补正前的旧断言只要求 >=150，'
          '会错误放行 150.0–189.999 秒）：\n${earlyResults.join("\n")}',
    );
    // 若确实进入了 result，必须要么已胜利、要么已达 190 秒上限。
    if (resultReachedAt >= 0) {
      // ignore: avoid_print
      print('V2AppFlow 记录：在 $resultReachedAt 秒进入 result；'
          'victory=${rt.victory}');
      expect(
        victorySeen || resultReachedAt >= 190.0,
        isTrue,
        reason: '在 $resultReachedAt 秒进入 result，但既非胜利、'
            '也未到 190 秒上限',
      );
    }
  });
}
