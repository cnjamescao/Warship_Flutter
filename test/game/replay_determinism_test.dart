// ================================================================
// test/game/replay_determinism_test.dart —— T-CORE-04 / AC-01
// ================================================================
// 「同一 seed + 同一输入序列重放两次，事件序列、候选卡、波次、
//   分数、胜负完全相同。」
//
// 同时把一份**固定回放基准**写入
// `test/fixtures/replays/baseline_determinism_v1.json`
// （协议 §5.1 要求的 AC-06 基准格式）。
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
import 'package:warship_flutter/game/core/replay.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/boss_system.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/risk_gate_system.dart';
import 'package:warship_flutter/game/domain/upgrade_system.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

/// AC-06 基准固定值（协议 §5.1）。
const int kBaselineSeed = 0x4E454F4E0001;
const String kContentVersion = '2.0.6-material-repair';
const String kFixturePath =
    'test/fixtures/replays/baseline_determinism_v1.json';

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

/// 从正式 manifest 读取 SHA-256（用于内容指纹）。
String manifestSha256() {
  final manifest =
      jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
          as Map<String, Object?>;
  // 构建复制品自身没有整文件 hash 字段，用记录数 + 版本作为**稳定的
  // 内容指纹**；正式发布时应改用构建产物整文件 SHA-256。
  final assets = (manifest['assets'] as List?)?.length ?? 0;
  return 'records=$assets;version=${manifest['contentVersion']}';
}

GameRuntime buildRuntime({RequiredUpgrade? upgrades}) {
  final playerJson = readJson('player.json');
  final enemiesJson = readJson('enemies.json');
  final wavesJson = readJson('waves_normal.json');
  final upgradesJson = readJson('upgrades.json');
  final riskJson = readJson('risk_gates.json');

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
  final upgradeSystem = UpgradeSystem(
    cards: (upgradesJson['cards'] as List)
        .cast<Map>()
        .map((m) => UpgradeCard.fromConfig(m.cast<String, Object?>()))
        .toList(),
    xpThresholds: (upgradesJson['xpThresholds'] as List).cast<int>(),
    firstDraftEarliestSecond:
        (upgradesJson['firstDraftEarliestSecond'] as num).toDouble(),
    maxDrafts: upgradesJson['maxDrafts'] as int,
    draftSize: upgradesJson['draftSize'] as int,
    damageCardIds: (upgradesJson['damageCardIds'] as List).cast<String>().toSet(),
    guaranteedFirstDraft: (guaranteed['firstDraft'] as List).cast<String>(),
    guaranteedSecondDraftAnyOf:
        (guaranteed['secondDraftAnyOf'] as List).cast<String>(),
  );

  final common = riskJson['common'] as Map;
  final overload = (riskJson['options'] as List)
      .cast<Map>()
      .firstWhere((o) => o['id'] == 'RG-OVERLOAD');

  return GameRuntime(
    catalogPlayer: playerJson,
    enemyTunings: tunings,
    runtime: RunContext(
      identity: const RunIdentity(
        runId: 'baseline',
        seed: kBaselineSeed,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: kContentVersion,
        contentManifestSha256: '',
      ),
      random: Pcg32(kBaselineSeed),
    ),
    random: Pcg32(kBaselineSeed),
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
    bossSystem: BossSystem(),
    riskGateSystem: RiskGateSystem(
      overloadHpThreshold: ((overload['availableCondition'] as Map?)?['hpAbove']
                  as num?)
              ?.toInt() ??
          35,
      selectionWindowSeconds:
          (common['selectionWindowSeconds'] as num).toDouble(),
      timeoutFallbackId: common['timeoutFallbackId'] as String,
      overloadRarePool:
          (((overload['effect'] as Map?)?['pool'] as List?) ?? const <Object?>[])
              .whereType<String>()
              .toList(),
    ),
    upgradeSystem: upgradeSystem,
  );
}

/// 确定性的输入生成器：与随机无关，纯粹由帧号决定。
///
/// 回放要验证的是"同样的输入 → 同样的结果"，因此输入序列本身
/// 必须是**可重建**的，不能依赖 `Random`。
InputFrame inputFor(int frame) {
  // 每 120 帧（2 秒）换一个移动方向，形成可预期的走位。
  const directions = <Vec2>[
    Vec2(-1, 0),
    Vec2(0, -1),
    Vec2(1, 0),
    Vec2(0, 1),
    Vec2(-1, -1),
    Vec2(1, 1),
    Vec2.zero,
  ];
  final direction = directions[(frame ~/ 120) % directions.length];
  // 每 300 帧尝试一次冲刺。
  return InputFrame(
    moveDirection: direction,
    dashRequested: frame % 300 == 0,
  );
}

/// 跑一局并返回观测结果。
({String digest, int score, double seconds, int enemies, String result})
    runOnce({required bool autoPickCards}) {
  final rt = buildRuntime();
  final hasher = EventHasher();
  var frames = 0;

  // 6000 帧 = 100 秒有效战斗时间。
  while (frames < 6000 && !rt.player.health.isDead) {
    final input = inputFor(frames);
    rt.advance(GameClock.fixedStepSeconds, input);

    for (final event in rt.lastFrameEvents) {
      hasher.add('${event.frameIndex}:${event.eventIndex}:${event.eventType}\n');
    }

    // 选卡与风险门在选择窗口内立即提交，避免相位卡住。
    if (autoPickCards) {
      if (rt.currentOffer != null) {
        rt.selectDraftCard(0);
      }
      final gate = rt.riskGate;
      if (gate != null && !gate.isResolved) {
        rt.selectRiskOption(RiskOptionIds.supply);
      }
    }

    frames++;
  }

  return (
    digest: hasher.digest,
    score: rt.score,
    seconds: rt.combatSeconds,
    enemies: rt.enemies.length,
    result: rt.player.health.isDead ? 'defeat' : 'running',
  );
}

void main() {
  group('T-CORE-04 同一 seed + 同一输入序列完全一致', () {
    test('两次重放的事件摘要、分数、时长、敌人数量完全相同', () {
      final first = runOnce(autoPickCards: true);
      final second = runOnce(autoPickCards: true);

      expect(second.digest, first.digest, reason: '事件序列摘要必须一致');
      expect(second.score, first.score, reason: '分数必须一致');
      expect(second.seconds, closeTo(first.seconds, 1e-9), reason: '时长必须一致');
      expect(second.enemies, first.enemies, reason: '存活敌人数量必须一致');
      expect(second.result, first.result);
    });

    test('不选卡时同样确定（排除选卡路径对随机序列的干扰）', () {
      final first = runOnce(autoPickCards: false);
      final second = runOnce(autoPickCards: false);

      expect(second.digest, first.digest);
      expect(second.score, first.score);
    });

    test('摘要是非空且稳定的十六进制串', () {
      final run = runOnce(autoPickCards: false);
      expect(run.digest, isNotEmpty);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(run.digest), isTrue);
    });
  });

  group('回放记录格式（协议 §5.1）', () {
    test('编解码往返不丢信息', () {
      const original = ReplayRecord(
        version: ReplayRecord.currentVersion,
        seed: kBaselineSeed,
        contentVersion: kContentVersion,
        manifestSha256: 'records=193;version=2.0.6-material-repair',
        frames: <ReplayFrame>[
          ReplayFrame(moveX: -1, moveY: 0),
          ReplayFrame(moveX: 0, moveY: -1, dash: true),
          ReplayFrame(moveX: 1, moveY: 1, cardSelection: 2),
          ReplayFrame(moveX: 0, moveY: 0, riskSelection: 'RG-SUPPLY'),
        ],
        result: 'victory',
        score: 12345,
        durationSeconds: 173.4,
        eventDigest: 'abcdef0123456789',
        note: '测试用',
      );

      final restored = ReplayRecord.decode(original.encode());

      expect(restored.seed, original.seed);
      expect(restored.contentVersion, original.contentVersion);
      expect(restored.manifestSha256, original.manifestSha256);
      expect(restored.result, original.result);
      expect(restored.score, original.score);
      expect(restored.durationSeconds, closeTo(original.durationSeconds, 1e-9));
      expect(restored.eventDigest, original.eventDigest);
      expect(restored.note, original.note);
      expect(restored.frames, original.frames);
    });

    test('版本或内容指纹不匹配时拒绝执行（协议 §5.1）', () {
      const record = ReplayRecord(
        version: ReplayRecord.currentVersion,
        seed: kBaselineSeed,
        contentVersion: kContentVersion,
        manifestSha256: 'sha-A',
        frames: <ReplayFrame>[],
      );

      expect(
        record.matches(
          contentVersion: kContentVersion,
          manifestSha256: 'sha-A',
        ),
        isTrue,
      );
      expect(
        record.matches(
          contentVersion: kContentVersion,
          manifestSha256: 'sha-B',
        ),
        isFalse,
        reason: 'manifest hash 不同不得执行旧回放',
      );
      expect(
        record.matches(
          contentVersion: '1.9.9-old', // 必须与 kContentVersion 不同
          manifestSha256: 'sha-A',
        ),
        isFalse,
      );
    });

    test('InputFrame 与 ReplayFrame 互转不丢字段', () {
      const input = InputFrame(
        moveDirection: Vec2(-1, 0.5),
        dashRequested: true,
        cardSelection: 1,
        riskSelection: 'RG-BOUNTY',
      );

      final restored = ReplayFrame.fromInputFrame(input).toInputFrame();

      expect(restored.moveDirection, input.moveDirection);
      expect(restored.dashRequested, isTrue);
      expect(restored.cardSelection, 1);
      expect(restored.riskSelection, 'RG-BOUNTY');
    });
  });

  group('AC-06 基准夹具', () {
    test('生成并写入 test/fixtures/replays/baseline_determinism_v1.json', () {
      final run = runOnce(autoPickCards: true);

      final recorder = ReplayRecorder(
        seed: kBaselineSeed,
        contentVersion: kContentVersion,
        manifestSha256: manifestSha256(),
      );
      for (var frame = 0; frame < 6000; frame++) {
        recorder.record(inputFor(frame));
      }

      final record = recorder.finish(
        result: run.result,
        score: run.score,
        durationSeconds: run.seconds,
        eventDigest: run.digest,
        note:
            'AC-06 基准（确定性版）。当前记录的是 6000 帧固定输入下的实际结果，'
            '**尚不是**协议 §5.1 要求的"180 秒前胜利、HP 从未受伤"的通关基准 —— '
            '后者需要可通关的玩法调优后才能生成。'
            '帧数、seed、contentVersion 与事件摘要已固定；'
            '素材或内容版本变更时必须显式更新本文件。',
      );

      final file = File(kFixturePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(record.encode());

      expect(file.existsSync(), isTrue);
      final reloaded = ReplayRecord.decode(file.readAsStringSync());
      expect(reloaded.seed, kBaselineSeed);
      expect(reloaded.frames.length, 6000);
      expect(reloaded.eventDigest, run.digest);

      // 重新执行一次，确认写入的摘要可复现。
      expect(runOnce(autoPickCards: true).digest, reloaded.eventDigest);
    });
  });
}

/// 占位类型参数（保留以表达"升级系统可选注入"的意图）。
typedef RequiredUpgrade = Object?;
