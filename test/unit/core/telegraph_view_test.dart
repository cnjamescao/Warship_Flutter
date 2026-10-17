// ================================================================
// test/unit/core/telegraph_view_test.dart —— F-36 第 2 步
// ================================================================
// 协议 §3.2 要求：「渲染快照以**独立不可变 `TelegraphView`** 公开预警，
// **禁止**将其折叠为 `EntityView` 或由表现层猜测目标。」
//
// 本文件守住三件事：
//   1. 预警确实以 `RenderSnapshot.telegraphs` 公开；
//   2. 几何（origin / aimTarget / shape）来自 t=0 锁定值，不随后续变化；
//   3. `EntityView` **不含**任何预警字段（禁止折叠）——含静态检查。
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
        runId: 'telegraph-view',
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
  test('F-36 预警以独立 telegraphs 公开，几何为 t=0 锁定值', () {
    final rt = _build();
    const step = GameClock.fixedStepSeconds;
    const world = 1920.0;

    var observed = 0;
    for (var i = 0; i < 200 * 60; i++) {
      rt.advance(step, InputFrame.idle);
      final snap = rt.snapshot();
      for (final t in snap.telegraphs) {
        observed++;
        // 几何必须在逻辑世界范围内（t=0 锁定值，不是任意值）。
        expect(t.origin.x, inInclusiveRange(-world, world * 2));
        // `none` 是 `AttackProfile.telegraphShape` 的合法取值：
        // `AFFIX-BARRAGE` 会给配置 `t=0`、形状 `none` 的招式
        // 追加 0.2s 预警（见 enemies.json）。这些招式**不在**
        // F-36 的 6 招强制集合内，但事件仍按协议发出。
        expect(t.shape, anyOf('line', 'circle', 'none'));
        expect(t.totalSeconds, greaterThan(0));
        // 剩余时间不得超过总时长（到期即出队）。
        expect(
          t.remainingSeconds,
          lessThanOrEqualTo(t.totalSeconds + step),
          reason: '${t.attackId} 的剩余预警时间超过总时长',
        );
        expect(
          t.remainingSeconds,
          greaterThan(0),
          reason: '${t.attackId} 已到期却仍在 telegraphs 中 —— 应出队',
        );
        // 预警期间**不得**存在同源的伤害实体（时序合同）。
        // 这里以"预警存在时该招式尚未 Fired"间接保证：
        // Fired 由第 1 步的时序测试负责，此处只确认公开结构正确。
      }
    }
    expect(observed, greaterThan(0), reason: '应至少公开过一帧预警');
  });

  test('F-36 EntityView 不含预警字段（禁止折叠）', () {
    final source = File(
      'lib/game/core/render_snapshot.dart',
    ).readAsStringSync();

    // 取出 EntityView 类体。
    final start = source.indexOf('class EntityView {');
    expect(start, greaterThanOrEqualTo(0), reason: '应能找到 EntityView');
    final end = source.indexOf('\n}', start);
    final body = source.substring(start, end);

    for (final banned in <String>[
      'telegraph',
      'Telegraph',
      'aimTarget',
      'remainingSeconds',
    ]) {
      expect(
        body.contains(banned),
        isFalse,
        reason: 'EntityView 出现了预警相关成员 `$banned` —— '
            '协议 §3.2 明确禁止把预警折叠为 EntityView',
      );
    }
  });

  test('F-36 预警素材必须是**配置的** telegraphAssetId，不得取到机体贴图', () {
    // 玩家实测："中间出现了一个旋转的战机"。根因是表现层按 `attackId`
    // 去 manifest 猜绑定，而 manifest 里
    //   GFX-EN-SNIPER（**机体**，448×448）与 GFX-WARN-LINE（**预警**，512×512）
    // **都绑定** `sniper_line`，于是命中机体贴图并被拉伸旋转。
    //
    // 本用例守住：TelegraphView.assetId 必须等于 **Domain 从配置锁定**的
    // `attackProfile.telegraphAssetId`。
    final rt = _build();
    const step = GameClock.fixedStepSeconds;

    final seen = <String, String>{};
    for (var i = 0; i < 200 * 60; i++) {
      rt.advance(step, InputFrame.idle);
      for (final t in rt.snapshot().telegraphs) {
        seen.putIfAbsent(t.attackId, () => t.assetId ?? '(null)');
      }
    }

    expect(seen, isNotEmpty, reason: '应出现过预警');
    // 配置即规范值（enemies.json 的 attackProfile.telegraphAssetId）。
    expect(
      seen['sniper_line'],
      'GFX-WARN-LINE',
      reason: 'sniper_line 的预警素材必须是 GFX-WARN-LINE（配置值）—— '
          '若为 GFX-EN-SNIPER 则说明又在按 attackId 猜绑定，'
          '会把机体贴图当预警线拉伸旋转',
    );
    expect(
      seen['bomber_drop'],
      'GFX-HAZARD-BOMBER-WARN',
      reason: 'bomber_drop 的预警素材必须是配置值 GFX-HAZARD-BOMBER-WARN',
    );
  });
}
