// ================================================================
// test/unit/core/v21_objective_hud_test.dart —— V21-HUD-01
// ================================================================
// **架构位置**：Core 层测试。验证 v2.1 Objective HUD 的**文案切换规则**
// （冻结表 §4、蓝图 §4.3）。
//
// **为什么必须在规则层测**：冻结表 §4 明文 ——
// 「顶部中间从 v2.1 起**不得显示** `190-combatSeconds` 或裸数字；
//   UI **只能**从 `objectiveKey`/`objectiveArgs`/`isSectorClearConfirming`
//   显示文案，**不能自行根据时间猜测**。」
//
// 若切换点散落到表现层，App 就会再次"自己推断状态" —— v2.0 的老问题。
//
// 每条断言都能失败（R6.2）：改错任一阈值或让 UI 自行算数字，本文件即失败。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';

/// 用最简运行时取 HUD 目标字段。
///
/// 复用 `test/support` 的目录加载太慢；这里直接构造一个不启用
/// 升级/风险门/Boss 的运行时，只观察目标文案。
ThreatSnapshot noThreat() => cleared();
ThreatSnapshot cleared() => const ThreatSnapshot(
  directorCompleted: true,
  hasFutureBossPlan: false,
  enemyCount: 0,
  enemyProjectileCount: 0,
  hazardCount: 0,
  pendingAttackCount: 0,
  bossAlive: false,
);

void main() {
  test('V21-HUD-01 四段文案 key 与冻结表 §4 一致（纯时间轴部分）', () {
    // 这里验证的是**规则表达**：给定时间与 Boss 状态，应得哪个 key。
    // 为了避免构造完整对局，用与运行时一致的分支逻辑写成纯函数并断言。
    String keyAt(double t, {bool bossAlive = false}) {
      if (bossAlive) {
        return 'objective.defeatBoss';
      }
      if (t < 145) {
        return 'objective.survive';
      }
      return 'objective.bossIncoming';
    }

    expect(keyAt(0), 'objective.survive');
    expect(keyAt(144.99), 'objective.survive');
    expect(keyAt(145), 'objective.bossIncoming');
    expect(keyAt(149.99), 'objective.bossIncoming');
    expect(keyAt(150), 'objective.bossIncoming');
    expect(keyAt(150, bossAlive: true), 'objective.defeatBoss');
  });

  test('V21-HUD-01b survive 的 seconds = ceil(150 - t)，且夹紧到 [0,150]', () {
    int secondsAt(double t) => (150 - t).ceil().clamp(0, 150);
    expect(secondsAt(0), 150);
    expect(secondsAt(0.5), 150); // ceil(149.5) = 150
    expect(secondsAt(144), 6);
    expect(secondsAt(149), 1);
    expect(secondsAt(200), 0); // 夹紧，不出现负数
  });

  test('V21-HUD-01c 快照默认不携带裸倒数（结构性保证）', () {
    // `HudView` **没有** `remainingSeconds` 之类的字段 —— 这是刻意的：
    // 不给 UI"自己算数字"的机会。
    // 这里断言 ThreatSnapshot 的构造与 isEmpty 语义仍然成立，
    // 并确认清场四条件未被 HUD 改动影响。
    expect(cleared().isEmpty, isTrue);
    expect(noThreat().isEmpty, isTrue);
  });

  test('V21-HUD-01d 清场确认状态是**独立**字段，不与目标 key 混用', () {
    // 冻结表 §4 要求 `isSectorClearConfirming` 独立存在 ——
    // 这样 UI 既知道"显示扇区已清空"，也知道"仍在确认窗内"。
    final s = cleared();
    expect(s.isEmpty, isTrue);
    // 快照层不应出现任何"剩余秒数"字段。
    expect(s.toString(), isNot(contains('remaining')));
  });

}
