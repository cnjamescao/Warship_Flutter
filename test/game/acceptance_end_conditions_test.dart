// ================================================================
// test/game/acceptance_end_conditions_test.dart —— AC-05 结束条件（2/3）
// ================================================================
// 产品设计 §7.5 的「结束条件/验收」列。AC-05 要求「13 个状态均有正确
// 视觉、音频**和结束条件**」。核对发现下列结束条件从未被测试
// （Boss 转段「只执行一次」已在 acceptance_boss_phase_once_test.dart 覆盖）：
//
//   * 敌人击毁：「**伤害判定已关闭后才播放；掉落只生成一次**」
//   * Boss 击败：「**停止伤害和生成后再进入结算**」
//
// 设计原则（承接上一轮的教训）：**刻意制造能让缺陷暴露的条件**，
// 而不是只走一条顺利路径。
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
        runId: 'end-conditions',
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

void main() {
  test('敌人击毁：销毁只播报一次，且此后不再产生该敌人的伤害事件', () {
    final rt = _build();

    // 先跑出一批敌人。
    for (var i = 0; i < 180; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    expect(rt.enemies, isNotEmpty, reason: '应已有敌人');

    final destroyed = <String>[];
    final damagedAfterDestroy = <String>[];

    // **刻意制造重复结算的机会**：一次性把全部敌人打死，然后
    // 继续推进很久 —— 若"伤害判定未关闭"，会继续出现该实体的
    // 伤害或销毁事件。
    for (final e in rt.enemies) {
      e.health.current = 0;
    }
    for (var i = 0; i < 600; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      for (final stamped in rt.lastFrameEvents) {
        final event = stamped.event;
        if (event is EnemyDestroyed) {
          destroyed.add(event.entityId.toString());
        } else if (event is EnemyDamaged) {
          if (destroyed.contains(event.entityId.toString())) {
            damagedAfterDestroy.add(event.entityId.toString());
          }
        }
      }
    }

    expect(destroyed, isNotEmpty, reason: '应发生过敌人击毁');

    // 1) 同一实体只播报一次击毁。
    final dupes = <String>[];
    final seen = <String>{};
    for (final id in destroyed) {
      if (!seen.add(id)) dupes.add(id);
    }
    expect(dupes, isEmpty, reason: '同一敌人被播报多次击毁：$dupes');

    // 2) **伤害判定在击毁后必须关闭** —— 不得再对该实体结算伤害。
    expect(
      damagedAfterDestroy,
      isEmpty,
      reason: '击毁后仍在结算伤害：${damagedAfterDestroy.toSet()}',
    );
  });

  test('Boss 击败：胜利后停止伤害与生成，再进入结算', () {
    final rt = _build();
    var frame = 0;

    // 推进到 Boss 入场并把它打死。
    while (frame < 260 * 60 && !rt.victory) {
      rt.player.health.current = rt.player.health.max;
      final offer = rt.currentOffer;
      if (offer != null) {
        rt.selectDraftCard(0);
      }
      final boss = rt.boss;
      if (boss != null && !boss.isDefeated) {
        boss.health.current = 1; // 逼它进入可被击杀的边缘
      }
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      frame++;
    }
    expect(rt.victory, isTrue, reason: '应已击败 Boss');

    // 胜利之后继续推进：**不得再有伤害或新生成**。
    final spawnsAfter = <String>[];
    final damageAfter = <String>[];
    final enemiesBefore = rt.enemies.length;

    for (var i = 0; i < 600; i++) {
      rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
      for (final stamped in rt.lastFrameEvents) {
        final event = stamped.event;
        if (event is EnemySpawned) spawnsAfter.add(event.enemyId);
        if (event is PlayerDamaged) damageAfter.add('player');
        if (event is EnemyBreached) damageAfter.add('breach');
      }
    }

    expect(
      spawnsAfter,
      isEmpty,
      reason: '§7.5 要求击败后"停止生成"，但仍生成了：${spawnsAfter.toSet()}',
    );
    // **F-20 已裁决（选 A）**：Boss 击败后原子切换到不可受伤的
    // 胜利过渡态 —— 拒绝一切 `DamageIntent`、清除敌人/敌弹/危险区、
    // 停用碰撞与伤害 tick、禁止生成新的伤害源。
    //
    // 因此这里按裁决的**完成判定**收紧断言：
    // 「枚举敌弹、危险区、敌体接触、越界、Boss 接触等来源，
    //   在 Boss=0 后**均为 0 伤害且不再生成 `PlayerDamaged`**」。
    //
    // （此前我只能断言"投射物已清空"，因为敌人本体接触与越界仍在
    //   结算伤害 —— 实测胜利后仍有 3 次 `PlayerDamaged`。）
    expect(
      damageAfter,
      isEmpty,
      reason: 'F-20：Boss 击败后不得再产生任何 PlayerDamaged，'
          '但观察到的来源有：${damageAfter.toSet()}',
    );

    final enemyProjectilesAfter = rt.projectiles
        .where((p) => p.faction == ProjectileFaction.enemy)
        .length;
    expect(enemyProjectilesAfter, 0, reason: 'F-20：敌方投射物应已清除');
    expect(rt.hazards, isEmpty, reason: 'F-20：危险区应已清除');
    expect(rt.enemies, isEmpty, reason: 'F-20：场上敌人应已清除');

    expect(
      rt.enemies.length,
      lessThanOrEqualTo(enemiesBefore),
      reason: '击败后不应再增加场上敌人',
    );
  });
}
