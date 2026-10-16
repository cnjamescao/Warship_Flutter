// ================================================================
// test/game/acceptance_f38_boss_telegraph_test.dart —— F-38
// ================================================================
// 负责人批复（2026-10-16）：批准 F-38「按 F-36 同构方案实施」，
// 并要求「补四条 Golden 和**取消/暂停回归**」。
//
// 本文件覆盖**取消/暂停回归**，并给出 Boss 预警存在的**直接运行时证据**
// （不依赖应用长跑，因此不受 golden 驱动问题影响）。
//
// 合同来源：协议 §3.2「预警期间源敌机被移除、风险门开启、胜利锁定、
// 重开或非 Playing 状态，待执行攻击必须取消/冻结且不得残留」，
// 以及 F-38 批复要求预警几何在 **t=0 锁定**。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/core/game_clock.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/render_snapshot.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/boss_system.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

Map<String, Object?> _read(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

/// 与 `V2Bootstrap` 同一口径：Boss 逐招的预警规格。
Map<String, BossTelegraphSpec> _bossSpecs() {
  final boss = _read('boss_aegis.json');
  final out = <String, BossTelegraphSpec>{};
  const assets = <String, String>{
    'boss_fan': 'GFX-WARN-CONE',
    'boss_charge': 'GFX-WARN-CHARGE',
    'boss_ring': 'GFX-WARN-CIRCLE',
    'boss_laser': 'GFX-WARN-LASER',
  };
  for (final raw in ((boss['attacks'] as List?) ?? const []).cast<Map>()) {
    final id = raw['attackId'] as String?;
    final seconds = (raw['telegraphSeconds'] as num?)?.toDouble() ?? 0;
    final asset = assets[id];
    if (id == null || asset == null || seconds <= 0) {
      continue;
    }
    out[id] = BossTelegraphSpec(
      assetId: asset,
      shape: (raw['telegraphShape'] as String?) ?? 'circle',
      totalSeconds: seconds,
    );
  }
  return out;
}

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
    bossTelegraphs: _bossSpecs(),
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'f38-boss-telegraph',
        seed: 0x4E454F4E0001,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: '2.0.6-material-repair',
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

/// 推进直到出现 Boss 预警；返回该预警（找不到则 null）。
TelegraphView? _advanceToBossTelegraph(GameRuntime rt) {
  const step = GameClock.fixedStepSeconds;
  for (var i = 0; i < 300 * 60; i++) {
    rt.player.health.current = rt.player.health.max;
    // 清空普通敌人：杜绝越界失败，让对局稳定推进到 Boss。
    rt.enemies.clear();
    if (rt.currentOffer != null) {
      rt.selectDraftCard(0);
    }
    rt.advance(step, InputFrame.idle);
    for (final t in rt.snapshot().telegraphs) {
      if (t.attackId.startsWith('boss_')) {
        return t;
      }
    }
  }
  return null;
}

void main() {
  test('F-38 Boss 预警进入独立 TelegraphView，且几何在 t=0 锁定', () {
    final rt = _build();
    final first = _advanceToBossTelegraph(rt);
    expect(
      first,
      isNotNull,
      reason: 'Boss 四招应有预警进入 snapshot.telegraphs —— '
          '修复前 Boss 预警从不进入快照（F-38）',
    );
    expect(first!.totalSeconds, greaterThan(0), reason: '预警应有总时长');

    // **t=0 锁定**：预警期间强制移动玩家，几何不得跟随。
    final ox = first.origin.x;
    final oy = first.origin.y;
    final ax = first.aimTarget.x;
    final ay = first.aimTarget.y;

    const step = GameClock.fixedStepSeconds;
    var checked = 0;
    while (checked < 20) {
      rt.player.position = Vec2(100 + checked * 10, 200 + checked * 10);
      rt.player.health.current = rt.player.health.max;
      rt.enemies.clear();
      rt.advance(step, InputFrame.idle);
      final same = rt
          .snapshot()
          .telegraphs
          .where((t) => t.attackId == first.attackId)
          .toList();
      if (same.isEmpty) {
        break;
      }
      expect(
        same.first.origin.x,
        ox,
        reason: 'Boss 预警的 origin 应锁定于 t=0，不随玩家移动',
      );
      expect(same.first.origin.y, oy);
      expect(same.first.aimTarget.x, ax, reason: 'aimTarget 应锁定于 t=0');
      expect(same.first.aimTarget.y, ay);
      checked++;
    }
    expect(checked, greaterThan(0), reason: '应至少校验到一帧锁定几何');
  });

  test('F-38 Boss 预警在非 Playing（暂停）时冻结，不推进到期', () {
    final rt = _build();
    final first = _advanceToBossTelegraph(rt);
    expect(first, isNotNull);

    // 进入暂停（非 Playing）。
    rt.phases.transitionTo(GamePhase.paused, reason: 'testPause');
    final before = rt
        .snapshot()
        .telegraphs
        .where((t) => t.attackId == first!.attackId)
        .toList();
    expect(before, isNotEmpty, reason: '暂停瞬间预警应仍存在（冻结而非清除）');

    const step = GameClock.fixedStepSeconds;
    for (var i = 0; i < 120; i++) {
      rt.advance(step, InputFrame.idle);
    }

    final after = rt
        .snapshot()
        .telegraphs
        .where((t) => t.attackId == first!.attackId)
        .toList();
    expect(
      after,
      isNotEmpty,
      reason: '暂停期间预警不得到期消失 —— 逻辑时钟不前进即"冻结"',
    );
    expect(
      after.first.remainingSeconds,
      closeTo(before.first.remainingSeconds, 1e-6),
      reason: '暂停期间剩余预警时间不得推进',
    );
  });
}
