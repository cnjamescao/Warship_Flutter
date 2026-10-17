// ================================================================
// test/game/acceptance_telegraph_timing_test.dart —— F-36 第 1 步
// ================================================================
// 协议 §3.2「敌机预警与轰炸危险区的时序合同」（F-36 批复）：
//
//   * `telegraphSeconds > 0` 的攻击在 t=0 只发 `EnemyAttackTelegraphed`；
//   * 在 `startedAt + telegraphSeconds` **之前**不得发
//     `EnemyAttackFired`、不得生成伤害实体；
//   * **到期同一步**才发 Fired 并生成实体；
//   * 预警期间源敌机被移除 / 风险门 / 胜利锁定 / 重开 / 非 Playing
//     必须取消且不得残留。
//
// 改动前 Fired / Telegraphed / 生成实体发生在**同一步**，
// 因此"预警时长"对玩家完全无效 —— 本文件守住这条时序。
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
        runId: 'telegraph-timing',
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

/// 配置里 `telegraphSeconds > 0` 的招式 → 预警时长。
Map<String, double> _telegraphSecondsByAttack() {
  final enemies = _read('enemies.json');
  final out = <String, double>{};
  for (final raw in (enemies['enemies'] as List).cast<Map>()) {
    final ap = (raw['attackProfile'] as Map?) ?? const <String, Object?>{};
    final t = (ap['telegraphSeconds'] as num?)?.toDouble() ?? 0;
    final id = ap['attackId'] as String?;
    if (id != null && t > 0) {
      out[id] = t;
    }
  }
  return out;
}

void main() {
  test('F-36 有预警招式：Fired 必须恰好晚于 Telegraphed 预警时长', () {
    final telegraphed = _telegraphSecondsByAttack();
    expect(
      telegraphed,
      isNotEmpty,
      reason: '配置里应有 telegraphSeconds > 0 的招式（sniper_line/bomber_drop）',
    );

    final rt = _build();
    // 预警发出时刻 / 发射时刻（按 源实体+招式 记录）。
    final telegraphAt = <String, double>{};
    final firedAt = <String, double>{};

    // 跑足够久，覆盖 Sniper(80-150s) 与 Bomber(70-150s) 的窗口。
    const step = GameClock.fixedStepSeconds;
    for (var i = 0; i < 200 * 60; i++) {
      rt.advance(step, InputFrame.idle);
      for (final stamped in rt.lastFrameEvents) {
        final e = stamped.event;
        if (e is EnemyAttackTelegraphed) {
          telegraphAt.putIfAbsent(
            '${e.entityId.kind.name}#${e.entityId.sequence}:${e.attackId}',
            () => rt.combatSeconds,
          );
        } else if (e is EnemyAttackFired) {
          firedAt.putIfAbsent(
            '${e.entityId.kind.name}#${e.entityId.sequence}:${e.attackId}',
            () => rt.combatSeconds,
          );
        }
      }
    }

    expect(telegraphAt, isNotEmpty, reason: '应至少出现过一次带预警的攻击');

    var checked = 0;
    for (final entry in telegraphAt.entries) {
      final attackId = entry.key.split(':').last;
      final expected = telegraphed[attackId];
      if (expected == null) {
        continue;
      }
      final fired = firedAt[entry.key];
      expect(
        fired,
        isNotNull,
        reason: '${entry.key} 发了预警却没有发射（待执行攻击丢失）',
      );
      final delta = fired! - entry.value;
      expect(
        delta,
        closeTo(expected, step * 1.5),
        reason: '${entry.key}：Fired 与 Telegraphed 的间隔为 '
            '${delta.toStringAsFixed(3)}s，应为预警时长 '
            '${expected}s —— 说明到期前就发射了（时序合同违规）',
      );
      checked++;
    }
    expect(checked, greaterThan(0), reason: '应至少校验到一条带预警的攻击');
  });

  test('F-36 预警期间源敌机被移除 → 待执行攻击取消，不得到期发射', () {
    final rt = _build();
    const step = GameClock.fixedStepSeconds;

    // 先跑到出现带预警的攻击，并**在预警窗口内**清空敌机。
    var firedAfterTelegraph = 0;
    var triggerAttackId = '';

    outer:
    for (var i = 0; i < 200 * 60; i++) {
      rt.advance(step, InputFrame.idle);
      for (final stamped in rt.lastFrameEvents) {
        final e = stamped.event;
        if (e is EnemyAttackTelegraphed && e.telegraphSeconds > 0) {
          triggerAttackId = e.attackId;
          // 立即移除全部敌机（模拟"源敌机被移除"）。
          rt.enemies.clear();
          // 预警窗口内不得出现该招式的 Fired。
          for (var k = 0; k < (e.telegraphSeconds / step).ceil() + 2; k++) {
            rt.advance(step, InputFrame.idle);
            for (final s2 in rt.lastFrameEvents) {
              if (s2.event is EnemyAttackFired &&
                  (s2.event as EnemyAttackFired).attackId == triggerAttackId) {
                firedAfterTelegraph++;
              }
            }
          }
          break outer;
        }
      }
    }

    expect(triggerAttackId, isNotEmpty, reason: '应捕捉到一次带预警的攻击');
    expect(
      firedAfterTelegraph,
      0,
      reason: '源敌机在预警期间被移除后，仍发射了 $triggerAttackId —— '
          '待执行攻击未被取消（F-36 取消规则违规）',
    );
  });
}
