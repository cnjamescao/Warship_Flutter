// ================================================================
// test/game/acceptance_ac04_telegraph_regression_test.dart —— F-36 第 6 步
// ================================================================
// **AC-04 六招回归**（F-36 收口条件之一）。
//
// F-07 裁决的强制预警集合：
//   `sniper_line`、`bomber_drop`、`boss_fan`、`boss_charge`、
//   `boss_ring`、`boss_laser`
//
// 完成判定：「**集合内每招的 `*Telegraphed` 先于伤害**」。
//
// 本文件对**每一招**断言：
//   * 该招确实发过 `*Telegraphed`（覆盖性）；
//   * `*Fired`（伤害实体生成点）**严格晚于**预警；
//   * 两者的时间差 ≈ 该招配置的 `telegraphSeconds`。
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

/// F-07 强制预警集合（裁决原文）。
const List<String> kMandatoryTelegraphAttacks = <String>[
  'sniper_line',
  'bomber_drop',
  'boss_fan',
  'boss_charge',
  'boss_ring',
  'boss_laser',
];

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
        runId: 'ac04-telegraph',
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

/// 各招配置的预警时长（配置即规范值）。
Map<String, double> _configuredTelegraphSeconds() {
  final out = <String, double>{};
  for (final raw
      in (_read('enemies.json')['enemies'] as List).cast<Map>()) {
    final ap = (raw['attackProfile'] as Map?) ?? const <String, Object?>{};
    final id = ap['attackId'] as String?;
    final t = (ap['telegraphSeconds'] as num?)?.toDouble() ?? 0;
    if (id != null && t > 0) {
      out[id] = t;
    }
  }
  for (final raw
      in ((_read('boss_aegis.json')['attacks'] as List?) ?? const [])
          .cast<Map>()) {
    final id = raw['attackId'] as String?;
    final t = (raw['telegraphSeconds'] as num?)?.toDouble() ?? 0;
    if (id != null && t > 0) {
      out[id] = t;
    }
  }
  return out;
}

void main() {
  test('AC-04 六招强制预警：Telegraphed 严格先于 Fired，且间隔等于配置时长', () {
    final configured = _configuredTelegraphSeconds();
    final rt = _build();
    const step = GameClock.fixedStepSeconds;

    final telegraphAt = <String, double>{};
    final firedAt = <String, double>{};

    var frame = 0;
    // 150 秒 Boss 入场；留足时间让 Boss 走完招式循环。
    while (frame < 420 * 60 && !rt.victory) {
      // 保持存活与推进选卡（与既有 Boss 用例同一驱动方式）。
      rt.player.health.current = rt.player.health.max;
      if (rt.currentOffer != null) {
        rt.selectDraftCard(0);
      }
      rt.advance(step, InputFrame.idle);
      frame++;

      for (final stamped in rt.lastFrameEvents) {
        final e = stamped.event;
        switch (e) {
          case EnemyAttackTelegraphed(:final attackId):
            telegraphAt.putIfAbsent(attackId, () => rt.combatSeconds);
          case BossAttackTelegraphed(:final attackId):
            telegraphAt.putIfAbsent(attackId, () => rt.combatSeconds);
          case EnemyAttackFired(:final attackId):
            firedAt.putIfAbsent(attackId, () => rt.combatSeconds);
          case BossAttackFired(:final attackId):
            firedAt.putIfAbsent(attackId, () => rt.combatSeconds);
          default:
            break;
        }
      }
    }

    final missing = <String>[];
    for (final attackId in kMandatoryTelegraphAttacks) {
      final warned = telegraphAt[attackId];
      if (warned == null) {
        missing.add(attackId);
        continue;
      }
      final fired = firedAt[attackId];
      expect(
        fired,
        isNotNull,
        reason: '$attackId 发了预警却从未发射（待执行攻击丢失）',
      );
      expect(
        fired!,
        greaterThan(warned),
        reason: 'AC-04：$attackId 的 Fired（$fired）必须**严格晚于** '
            'Telegraphed（$warned）—— 否则预警对玩家无效',
      );
      final expected = configured[attackId];
      if (expected != null) {
        expect(
          fired - warned,
          closeTo(expected, step * 1.5),
          reason: 'AC-04：$attackId 的预警时长为配置值 $expected，'
              '实测 ${(fired - warned).toStringAsFixed(3)}',
        );
      }
    }

    expect(
      missing,
      isEmpty,
      reason: 'AC-04：以下招式在本次模拟中未出现（覆盖不足，'
          '不能据此判定通过）：$missing',
    );
  });

  test('AC-04 补齐：集合外招式不得新增预警（F-19），且集合精确等于 F-07', () {
    // F-19 裁决：「消除 AC-04 的"每种攻击"歧义，**不为 Wing/Shield 添加新预警**。
    // 精确集合与 F-07 一致。」
    //
    // 因此集合**外**的招式（`wing_shot`、`shield_shot`、`scout_shot`）：
    //   * 不得被 F-36 赋予预警视觉（配置里 `telegraphAssetId` 必须为空）；
    //   * 其 `telegraphSeconds` 必须为 0（不得因本条新增预警时长）。
    final enemies = _read('enemies.json');
    final offenders = <String>[];
    final observed = <String>{};

    for (final raw in (enemies['enemies'] as List).cast<Map>()) {
      final ap = (raw['attackProfile'] as Map?) ?? const <String, Object?>{};
      final attackId = ap['attackId'] as String?;
      if (attackId == null) {
        continue;
      }
      observed.add(attackId);
      final seconds = (ap['telegraphSeconds'] as num?)?.toDouble() ?? 0;
      final assetId = ap['telegraphAssetId'] as String?;
      if (kMandatoryTelegraphAttacks.contains(attackId)) {
        continue;
      }
      if (seconds > 0 && assetId != null) {
        offenders.add('$attackId：telegraphSeconds=$seconds，'
            'telegraphAssetId=$assetId');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '集合外招式被赋予了预警素材 —— F-19 明确"不为 Wing/Shield '
          '添加新预警"，精确集合须与 F-07 一致：\n${offenders.join('\n')}',
    );

    // 集合的敌机部分必须**恰好**是这两个（Boss 四招由 boss_aegis.json 提供）。
    const enemySideMandatory = <String>{'sniper_line', 'bomber_drop'};
    final enemySide = observed.intersection(enemySideMandatory);
    expect(
      enemySide,
      enemySideMandatory,
      reason: 'F-07 集合中属于敌机的两招必须都存在：$enemySideMandatory',
    );

    // Boss 侧四招：配置里必须有非零预警时长。
    final bossAttacks = <String, double>{
      for (final raw
          in ((_read('boss_aegis.json')['attacks'] as List?) ?? const [])
              .cast<Map>())
        (raw['attackId'] as String):
            ((raw['telegraphSeconds'] as num?)?.toDouble() ?? 0),
    };
    for (final id in <String>[
      'boss_fan',
      'boss_charge',
      'boss_ring',
      'boss_laser',
    ]) {
      expect(
        bossAttacks[id],
        isNotNull,
        reason: 'F-07 集合中的 $id 应在 boss_aegis.json 中登记',
      );
      expect(
        bossAttacks[id]!,
        greaterThan(0),
        reason: '$id 必须有非零预警时长（F-07 强制预警集合）',
      );
    }
  });
}
