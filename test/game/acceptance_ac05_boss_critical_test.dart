// ================================================================
// test/game/acceptance_ac05_boss_critical_test.dart —— AC-05 精确用例（2/2）
// ================================================================
// 负责人批复（2026-10-16）：
// 「Boss 濒毁：在 0 < HP ≤ 10% 期间，critical 音画**至多一次**；
//   不得出现胜利音、`BossDefeated` 或 `RunEnded(victory)`；
//   **仅 HP=0 才允许胜利结算**。
//   '不加速到不可躲避' 继续由 AC-04 覆盖，无需在本用例重复。」
//
// 产品来源：`Warship现代化产品设计文档.md` §7.5 状态表「Boss 濒毁」行 ——
// 「`sfx.boss.critical` 最多一次；**不加速到不可躲避；0% 前不得播放胜利音**」。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/domain_event.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/core/game_clock.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/boss_system.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

Map<String, Object?> _read(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime _build() {
  final enemies = _read('enemies.json');
  final waves = _read('waves_normal.json');
  return GameRuntime(
    catalogPlayer: _read('player.json'),
    enemyTunings: <String, EnemyTuning>{
      for (final raw in (enemies['enemies'] as List).cast<Map>())
        (raw['id'] as String):
            EnemyTuning.fromConfig(raw.cast<String, Object?>()),
    },
    eliteAffixes: <String, EliteAffix>{
      for (final raw in (enemies['affixes'] as List? ?? const []).cast<Map>())
        (raw['id'] as String):
            EliteAffix.fromConfig(raw.cast<String, Object?>()),
    },
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'ac05-boss-critical',
        seed: 0x4E454F4E0001,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.1.0-neon-flow',
        contentManifestSha256: '',
      ),
      random: Pcg32(0x4E454F4E0001),
    ),
    random: Pcg32(0x4E454F4E0001),
    bus: EventBus(),
    clock: GameClock(),
    phases: PhaseController(initialPhase: GamePhase.playing),
    director: DirectorSystem(
      rows: (waves['waves'] as List)
          .cast<Map>()
          .map((m) => WaveRow.fromConfig(m.cast<String, Object?>()))
          .toList(),
      minimumUpgradeWindows: const <MinimumUpgradeWindow>[],
      eliteRules: const <String, int>{},
    ),
    enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
    pulse: PulseWeapon(),
    bossSystem: BossSystem(),
  );
}

void main() {
  // ⚠️ **两条测试构造上的自我更正**（记录以免后人重踩）：
  //
  // 第一版我「每步把 HP 夹回 (0,10%]」并断言"期间不得出现胜利"、
  // "critical 至多一次" —— 两条都失败，但**都是我的构造问题**：
  //   * 反复把 HP 抬回濒毁区会**反复穿越阈值**，critical 重触发是预期的；
  //   * 直接给 HP 赋值 0 绕过了**伤害路径**，死亡判定不在那条路径上。
  // 规范要求的是「**一次正常战斗中**：濒毁音画至多一次；
  // 仅 HP=0 才允许胜利结算」。因此改为**自然战斗**下观测。

  test('AC-05 Boss 濒毁：自然战斗下 critical 至多一次，且胜利仅发生在 HP=0', () {
    final rt = _build();
    const step = GameClock.fixedStepSeconds;

    var criticalCount = 0;
    final victoriesWithNonZeroHp = <String>[];
    var sawBoss = false;

    // 自然推进：只保持玩家存活与选卡，**不干预 Boss 血量**。
    for (var i = 0; i < 420 * 60; i++) {
      rt.player.health.current = rt.player.health.max;
      if (rt.currentOffer != null) {
        rt.selectDraftCard(0);
      }
      if (rt.boss != null) {
        sawBoss = true;
      }
      rt.advance(step, InputFrame.idle);

      var victoryThisStep = false;
      for (final stamped in rt.lastFrameEvents) {
        final e = stamped.event;
        if (e is BossCriticalReached) {
          criticalCount++;
        }
        if (e is BossDefeated) {
          victoryThisStep = true;
        }
        if (e is RunEnded && e.result == 'victory') {
          victoryThisStep = true;
        }
      }
      final boss = rt.boss;
      if (victoryThisStep && boss != null && boss.health.current > 0) {
        victoriesWithNonZeroHp.add('第 $i 步：HP=${boss.health.current}');
      }
      if (rt.victory) {
        break;
      }
    }

    expect(sawBoss, isTrue, reason: '本局应至少出现过 Boss');
    expect(
      criticalCount,
      lessThanOrEqualTo(1),
      reason: '「Boss 濒毁」音画**至多一次**（§7.5）—— 自然战斗中实际'
          ' $criticalCount 次',
    );
    expect(
      victoriesWithNonZeroHp,
      isEmpty,
      reason: '§7.5 与批复明确「**仅 HP=0 才允许胜利结算**」'
          '「0% 前不得播放胜利音」—— 但胜利在 HP 不为 0 时出现了：\n'
          '${victoriesWithNonZeroHp.join("\n")}',
    );
  });
}
