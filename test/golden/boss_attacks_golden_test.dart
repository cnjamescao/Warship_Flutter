// ================================================================
// test/golden/boss_attacks_golden_test.dart —— F-38 四条 Boss Golden
// ================================================================
// 负责人批复：「补**四条 Golden**」。F-07 强制预警集合中的 Boss 四招：
//   `boss_fan` / `boss_charge` / `boss_ring` / `boss_laser`
//
// **F-39 修复前**：应用流中 `V2Bootstrap` 从未传入 `bossSystem`，
// Boss 永不生成，因此这四条基线**无法经真实应用流产出**。
// 修复后（`bossSeenAt = 150.0`）本文件走**真实应用流**捕捉预警帧。
//
// ⚠️ 流程与既有 golden 一致（F-06/F-16）：CI 排除 `golden` tag、
// 不作为阻断项；基线在 macOS 本机生成，发布前由 QA **人工复核**；
// **真实设备 Release 截图/录屏仍是发布阻断证据**。
// ================================================================

@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_run_screen.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';

import '../support/v2_harness.dart';

const Map<String, String> kBossAttacks = <String, String>{
  'boss_fan': 'boss_fan.png',
  'boss_charge': 'boss_charge.png',
  'boss_ring': 'boss_ring.png',
  'boss_laser': 'boss_laser.png',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ContentCatalog catalog;
  setUpAll(() async {
    catalog = await loadV2CatalogForTests();
  });

  for (final entry in kBossAttacks.entries) {
    testWidgets('Golden：Boss 招式 ${entry.key} 预警帧', (tester) async {
      await mountV2App(tester, catalog);
      await tapText(tester, '开始战斗');
      await pumpV2(tester, frames: 6, step: const Duration(seconds: 1));

      final screen = tester.widget<V2RunScreen>(find.byType(V2RunScreen));
      final rt = screen.runtime;
      var captured = false;

      // 覆盖 150（Boss 入场）之后的一段：招式按 loop 轮转。
      for (var i = 0; i < 400 * 60 && !captured; i++) {
        // 选卡 + 保持存活（不干预风险门 —— 由 timeoutFallback 自动解决）。
        if (rt.currentOffer != null) {
          rt.selectDraftCard(0);
        }
        rt.player.health.current = rt.player.health.max;
        // ⚠️ 必须**逐帧小幅削减 Boss 血量**才能进入 P2/P3 ——
        // `boss_ring` 在 P2 的招式循环、`boss_laser` 在 P3。
        // 实测：不削减时 Boss 一直停在 P1，只能捕捉到 `fan` / `charge`。
        // 保留 20% 血量下限，避免归零后进入结算、错过后续招式。
        final boss = rt.boss;
        if (boss != null && !boss.isDefeated) {
          final floor = (boss.health.max * 0.20).floor();
          if (boss.health.current > floor) {
            boss.health.current = (boss.health.current - 1).clamp(
              floor,
              boss.health.max,
            );
          }
        }
        await pumpV2(tester, frames: 1);

        if (rt.snapshot().telegraphs.any((t) => t.attackId == entry.key)) {
          captured = true;
        }
      }

      expect(
        captured,
        isTrue,
        reason: '应在 Boss 入场后捕捉到 ${entry.key} 的预警帧',
      );
      // ignore: avoid_print
      print('Boss 招式基线捕捉到：${entry.key}');

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('baselines/${entry.value}'),
      );
      await unmountV2App(tester);
    });
  }
}
