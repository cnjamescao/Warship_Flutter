// ================================================================
// test/widget/briefing_objective_test.dart —— F-25-02
// ================================================================
// 实测现象：作战简报把「**3 秒展示倒计时**」误写成游戏目标 ——
// 玩家看到「坚持 **3** 秒，击败守门者 Aegis」。
//
// 根因：简报目标传入的 seconds 是 `kBriefingCountdown`（=3，
// 即简报界面的 3→1 展示倒计时），而权威值是**战斗时长上限**。
//
// 权威来源：`Spec/01_产品/Warship_v2.0研发交付基线.md`
//   「一局有效战斗时间**上限为 190 秒**…Boss 在 150 秒出现；
//     180 秒未击败时进入狂暴，但仍允许到 190 秒，190 秒判负。」
//
// 本文件同时确认：3→1 倒计时是**独立**的可见元素，两者不可混用。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_app_flow.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;
  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  testWidgets('F-25-02 简报目标用战斗时长上限，不是 3 秒展示倒计时', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 1);

    // ① 目标必须使用**权威时长**（190 秒），而不是 kBriefingCountdown。
    final expected = catalog.text('briefing.objective', <String, Object?>{
      'seconds': kRunObjectiveSeconds,
    });
    expect(
      find.text(expected),
      findsOneWidget,
      reason: '简报目标应为「$expected」',
    );

    // ② 明确的反例：不得出现「坚持 3 秒…」这种把展示倒计时当目标的结果。
    final wrong = catalog.text('briefing.objective', <String, Object?>{
      'seconds': kBriefingCountdown,
    });
    expect(
      find.text(wrong),
      findsNothing,
      reason: '简报目标不得使用 kBriefingCountdown（$kBriefingCountdown 秒）—— '
          '那是界面展示倒计时，不是游戏目标（F-25-02 的实测现象）',
    );

    // ③ 两者是不同数值，断言常量本身不被误当成同一个。
    expect(
      kRunObjectiveSeconds,
      isNot(kBriefingCountdown),
      reason: '目标时长与展示倒计时必须是不同的数值',
    );
    expect(kRunObjectiveSeconds, 190, reason: '产品基线：战斗时长上限 190 秒');
  });

  testWidgets('F-25-02 简报的 3→1 展示倒计时是独立可见元素', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 1);

    // 逐个逻辑秒推进，倒计时应依次显示 3 → 2 → 1。
    final seen = <String>[];
    for (var i = 0; i < 4; i++) {
      for (final n in <String>['3', '2', '1']) {
        if (find.text(n).evaluate().isNotEmpty && !seen.contains(n)) {
          seen.add(n);
        }
      }
      await pumpV2(tester, frames: 60);
    }

    expect(
      seen,
      containsAll(<String>['3', '2', '1']),
      reason: '简报应显示独立的 3→1 展示倒计时（实际看到：$seen）—— '
          '它存在，正说明它与游戏目标是两个不同的东西',
    );
  });
}
