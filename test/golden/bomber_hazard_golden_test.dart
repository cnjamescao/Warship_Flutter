// ================================================================
// test/golden/bomber_hazard_golden_test.dart —— F-37 视觉验收
// ================================================================
// 负责人批复（F-37 已裁定的执行动作）：
//   「研发……执行 Bomber 的 **F-36 回归和截图/Golden 验收**。」
//
// 本文件把对局**驱动到 `bomber_drop` 的预警/危险区真实出现的那一帧**，
// 再截基线 —— 静态的 `playing_hud` 基线覆盖不到这个状态
//（预警是瞬时的，普通截图必然错过）。
//
// ⚠️ 流程与既有 golden 一致（F-06/F-16）：
//   * CI 排除 `golden` tag，不作为阻断项；
//   * 基线在 macOS 本机生成，发布前由 QA 对照基线**人工复核**；
//   * **真实设备 Release 截图仍是发布阻断证据**，本文件不能替代。
// ================================================================

@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
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

  testWidgets('Golden：Bomber 圆形落点预警 + ACTIVE 危险区', (tester) async {
    await mountV2App(tester, catalog);
    await tapText(tester, '开始战斗');
    await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

    final screen = tester.widget<V2RunScreen>(find.byType(V2RunScreen));

    // Bomber 的刷出窗口是 70–150 秒。逐秒推进，捕捉**预警或危险区出现**
    // 的第一帧 —— 预警只持续 0.4 秒，因此必须精确停在它生效的那一帧。
    var captured = false;
    String capturedWhat = '';
    for (var second = 0; second < 170 && !captured; second++) {
      for (var frame = 0; frame < 60; frame++) {
        // ⚠️ 选卡必须在**内层**处理：否则一旦进入草案状态，整个内层循环
        // 都停在草案上（游戏不推进逻辑），永远等不到 Bomber。
        if (screen.runtime.currentOffer != null) {
          screen.runtime.selectDraftCard(0);
        }
        // ⚠️ 必须保持存活：空闲输入下玩家会在 70 秒（Bomber 出场）之前死亡，
        // 对局随即结束，于是永远等不到 bomber_drop —— 基线也就无从覆盖。
        screen.runtime.player.health.current =
            screen.runtime.player.health.max;
        await pumpV2(tester, frames: 1);
        final snap = screen.runtime.snapshot();
        if (snap.telegraphs.any((t) => t.attackId == 'bomber_drop')) {
          captured = true;
          capturedWhat = 'telegraph(bomber_drop)';
          break;
        }
        if (snap.hazards.isNotEmpty) {
          captured = true;
          capturedWhat = 'hazard(ACTIVE)';
          break;
        }
      }
    }

    expect(
      captured,
      isTrue,
      reason: '应在 170 秒内捕捉到 bomber_drop 的预警或 ACTIVE 危险区 —— '
          '否则本基线没有覆盖 F-37 要验收的视觉',
    );
    // ignore: avoid_print
    print('F-37 Golden 捕捉到：$capturedWhat');

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('baselines/bomber_hazard.png'),
    );
    await unmountV2App(tester);
  });
}
