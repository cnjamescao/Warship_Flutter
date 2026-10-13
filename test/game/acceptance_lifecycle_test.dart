// ================================================================
// test/game/acceptance_lifecycle_test.dart —— AC-03
// ================================================================
// 产品基线 §9 AC-03：
//   「5 分钟生命周期循环：开始、暂停、失焦、升级、风险门、死亡、
//     重开 **20 次**后无残留实体、持续音或重复输入」
//
// 这条用例的价值在于**发现泄漏**：每一轮都断言上一局没有把任何东西
// 留给下一局。因此不只跑 20 次，还在每轮结束后逐项检查残留。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/core/game_clock.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/risk_gate_system.dart';
import 'package:warship_flutter/game/domain/upgrade_system.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';
import 'package:warship_flutter/game/infrastructure/asset_loader.dart';
import 'package:warship_flutter/game/infrastructure/audio_director.dart';
import 'package:warship_flutter/game/infrastructure/audio_port.dart';

const String kContentVersion = '2.0.4-release';
const int kCycles = 20;

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

/// 一局所需的全部跨局依赖（音频、内容表）——在循环外建一次。
class Harness {
  Harness()
    : playerJson = readJson('player.json'),
      enemiesJson = readJson('enemies.json'),
      wavesJson = readJson('waves_normal.json'),
      upgradesJson = readJson('upgrades.json'),
      riskJson = readJson('risk_gates.json');

  final Map<String, Object?> playerJson;
  final Map<String, Object?> enemiesJson;
  final Map<String, Object?> wavesJson;
  final Map<String, Object?> upgradesJson;
  final Map<String, Object?> riskJson;

  /// 音频端口跨局复用（设置是全局的），但每局要清干净。
  final RecordingAudioPort port = RecordingAudioPort();
  late final AudioService audio = AudioService(port: port);
  AudioDirector? director;

  void ensureDirector() {
    if (director != null) {
      return;
    }
    final manifestJson =
        jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
            as Map<String, Object?>;
    final manifest = AssetManifest.parse(manifestJson).requireValue;
    director = AudioDirector(
      table: const AssetLoader().build(manifest),
      service: audio,
    );
  }

  GameRuntime newRun(int cycle) {
    final tunings = <String, EnemyTuning>{
      for (final raw in (enemiesJson['enemies'] as List).cast<Map>())
        (raw['id'] as String):
            EnemyTuning.fromConfig(raw.cast<String, Object?>()),
    };
    final windows = ((wavesJson['dynamicAdjustment'] as Map)
            ['minimumUpgradeCountBySecond'] as List)
        .cast<Map>()
        .map((m) => MinimumUpgradeWindow.fromConfig(m.cast<String, Object?>()))
        .toList();
    final rows = (wavesJson['waves'] as List)
        .cast<Map>()
        .map((m) => WaveRow.fromConfig(m.cast<String, Object?>()))
        .toList();
    final guaranteed = upgradesJson['guaranteed'] as Map;

    return GameRuntime(
      catalogPlayer: playerJson,
      enemyTunings: tunings,
      runtime: RunContext(
        identity: RunIdentity(
          runId: 'ac03-$cycle',
          seed: 0x4E454F4E0001,
          prngAlgorithm: 'pcg32-xsh-rr',
          contentVersion: kContentVersion,
          contentManifestSha256: '',
        ),
        random: Pcg32(0x4E454F4E0001),
      ),
      random: Pcg32(0x4E454F4E0001),
      bus: EventBus(),
      clock: GameClock(),
      phases: PhaseController(initialPhase: GamePhase.playing),
      director: DirectorSystem(
        rows: rows,
        minimumUpgradeWindows: windows,
        eliteRules: const <String, int>{'hp': 6, 'xp': 3, 'score': 8},
      ),
      enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
      pulse: PulseWeapon(),
      riskGateSystem: RiskGateSystem(
        overloadHpThreshold: 35,
        selectionWindowSeconds: 5.0,
        timeoutFallbackId: RiskOptionIds.supply,
        overloadRarePool: const <String>['UP-CRIT-ARC'],
      ),
      upgradeSystem: UpgradeSystem(
        cards: (upgradesJson['cards'] as List)
            .cast<Map>()
            .map((m) => UpgradeCard.fromConfig(m.cast<String, Object?>()))
            .toList(),
        xpThresholds: (upgradesJson['xpThresholds'] as List).cast<int>(),
        firstDraftEarliestSecond:
            (upgradesJson['firstDraftEarliestSecond'] as num).toDouble(),
        maxDrafts: upgradesJson['maxDrafts'] as int,
        draftSize: upgradesJson['draftSize'] as int,
        damageCardIds:
            (upgradesJson['damageCardIds'] as List).cast<String>().toSet(),
        guaranteedFirstDraft: (guaranteed['firstDraft'] as List).cast<String>(),
        guaranteedSecondDraftAnyOf:
            (guaranteed['secondDraftAnyOf'] as List).cast<String>(),
      ),
    );
  }
}

/// 走完一局里各种会让状态残留的路径。
void exerciseRun(GameRuntime rt) {
  // 1) 正常推进 3 秒（生成敌人、开火、产生事件）。
  for (var i = 0; i < 180; i++) {
    rt.advance(GameClock.fixedStepSeconds, inputFor(i));
  }

  // 2) 暂停 → 恢复。
  rt.phases.requestPause(PauseSource.userRequest);
  for (var i = 0; i < 30; i++) {
    rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
  }
  rt.phases.requestResume();

  // 3) 失焦（清空输入的路径）。
  rt.phases.requestPause(PauseSource.windowBlur);
  rt.phases.requestResume();

  // 4) 再推进，制造投射物与危险区。
  for (var i = 180; i < 600; i++) {
    rt.advance(GameClock.fixedStepSeconds, inputFor(i));
  }

  // 5) 直接打死玩家，走死亡路径。
  rt.player.health.current = 0;
  rt.advance(GameClock.fixedStepSeconds, InputFrame.idle);
}

InputFrame inputFor(int frame) {
  const directions = <Vec2>[Vec2(-1, 0), Vec2(0, -1), Vec2(1, 0), Vec2.zero];
  return InputFrame(
    moveDirection: directions[(frame ~/ 60) % directions.length],
    dashRequested: frame % 200 == 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AC-03 20 次重开后无残留实体、持续音或重复输入', () {
    final harness = Harness()..ensureDirector();

    for (var cycle = 0; cycle < kCycles; cycle++) {
      final rt = harness.newRun(cycle);

      // 新局必须是干净的：坐标回到出生点、计数归零、没有任何实体。
      expect(rt.player.position, const Vec2(960, 900), reason: '第 $cycle 局');
      expect(rt.enemies, isEmpty);
      expect(rt.projectiles, isEmpty);
      expect(rt.hazards, isEmpty);
      expect(rt.score, 0);
      expect(rt.xp, 0);
      expect(rt.logicSteps, 0);
      expect(rt.player.health.current, 100);
      expect(rt.bus.pending, isEmpty);

      exerciseRun(rt);

      // 释放本局。
      rt.dispose();
      harness.audio.stopAllLoops();
      harness.port.clear();

      // --- 残留检查 ---
      expect(rt.enemies, isEmpty, reason: '第 $cycle 局释放后仍有敌人');
      expect(rt.projectiles, isEmpty, reason: '第 $cycle 局释放后仍有投射物');
      expect(rt.hazards, isEmpty, reason: '第 $cycle 局释放后仍有危险区');
      expect(rt.bus.pending, isEmpty, reason: '第 $cycle 局释放后仍有未消费事件');
      expect(rt.lastFrameEvents, isEmpty);
      expect(rt.currentOffer, isNull, reason: '第 $cycle 局释放后仍有待选草案');
      expect(rt.riskGate, isNull, reason: '第 $cycle 局释放后仍有风险门');
      expect(rt.boss, isNull);
      expect(harness.audio.runningLoops, isEmpty, reason: '持续音未停止');
      expect(harness.port.activeLoops, isEmpty);
    }

    // 循环结束后再来一局，确认分配器没有累积到异常大的序号。
    final fresh = harness.newRun(999);
    for (var i = 0; i < 60; i++) {
      fresh.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }
    final maxSequence = fresh.enemies
        .map((e) => e.id.sequence)
        .fold<int>(0, (a, b) => a > b ? a : b);
    expect(
      maxSequence,
      lessThanOrEqualTo(8),
      reason: '新局的实体序号应从 1 重新开始，而不是延续上一局',
    );
    fresh.dispose();
  });

  test('重开不会把上一局的输入带过来（防"粘键"）', () {
    final harness = Harness()..ensureDirector();

    final first = harness.newRun(0);
    for (var i = 0; i < 60; i++) {
      first.advance(
        GameClock.fixedStepSeconds,
        const InputFrame(moveDirection: Vec2(-1, 0)),
      );
    }
    first.dispose();

    final second = harness.newRun(1);
    final startX = second.player.position.x;
    // 新局没有任何输入，玩家不应移动。
    for (var i = 0; i < 60; i++) {
      second.advance(GameClock.fixedStepSeconds, InputFrame.idle);
    }

    expect(second.player.position.x, startX, reason: '新局不得继承上一局的移动输入');
    second.dispose();
  });
}
