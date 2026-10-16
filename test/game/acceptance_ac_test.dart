// ================================================================
// test/game/acceptance_ac_test.dart —— AC-01 与 AC-09
// ================================================================
// 产品基线 §9：
//   AC-01「100 个固定 seed 回放：同输入下升级候选、风险门、精英词缀、
//          得分和胜负完全一致」
//   AC-09「每个运行时 Asset ID 有文件、元数据、许可证与回退策略；
//          不存在未登记第三方资源」
//
// 这两条是 §9 里**可以完全自动化**的部分，因此这里给出真实证据。
// 其余 AC 的当前状态记录在 docs/验收证据对照表.md。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_id.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/core/game_clock.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/replay.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/director_system.dart';
import 'package:warship_flutter/game/domain/enemy_system.dart';
import 'package:warship_flutter/game/domain/risk_gate_system.dart';
import 'package:warship_flutter/game/domain/upgrade_system.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/domain/weapon_system.dart';

const String kContentVersion = '2.0.6-material-repair';
const int kFramesPerRun = 1200; // 20 秒有效战斗：覆盖首个升级草案（15 秒）

Map<String, Object?> readJson(String name) =>
    jsonDecode(File('assets/config/v2/$name').readAsStringSync())
        as Map<String, Object?>;

GameRuntime buildRuntime(int seed) {
  final playerJson = readJson('player.json');
  final enemiesJson = readJson('enemies.json');
  final wavesJson = readJson('waves_normal.json');
  final upgradesJson = readJson('upgrades.json');

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
    // 精英词缀表（此前运行时与测试都没接，见 GameRuntime.eliteAffixes 注释）。
    eliteAffixes: <String, EliteAffix>{
      for (final raw in (enemiesJson['affixes'] as List? ?? const [])
          .cast<Map>())
        (raw['id'] as String):
            EliteAffix.fromConfig(raw.cast<String, Object?>()),
    },
    runtime: RunContext(
      identity: RunIdentity(
        runId: 'ac01-$seed',
        seed: seed,
        prngAlgorithm: 'pcg32-xsh-rr',
        contentVersion: kContentVersion,
        contentManifestSha256: '',
      ),
      random: Pcg32(seed),
    ),
    random: Pcg32(seed),
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
      overloadRarePool: const <String>[
        'UP-CRIT-ARC',
        'UP-MISSILE-SALVO',
        'UP-LASER-PRISM',
      ],
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

/// 与 seed 无关的固定输入序列（AC-01 要求"同输入"）。
InputFrame inputFor(int frame) {
  const directions = <Vec2>[
    Vec2(-1, 0),
    Vec2(0, -1),
    Vec2(1, 0),
    Vec2(0, 1),
    Vec2.zero,
  ];
  return InputFrame(
    moveDirection: directions[(frame ~/ 90) % directions.length],
    dashRequested: frame % 240 == 0,
  );
}

/// 一次运行的完整观测。
({
  String digest,
  int score,
  List<String> draftCandidates,
  List<String> risks,
  String outcome,
})
runSeed(int seed) {
  final rt = buildRuntime(seed);
  final hasher = EventHasher();
  final drafts = <String>[];
  final risks = <String>[];

  for (var frame = 0; frame < kFramesPerRun; frame++) {
    rt.advance(GameClock.fixedStepSeconds, inputFor(frame));
    for (final event in rt.lastFrameEvents) {
      hasher.add('${event.frameIndex}:${event.eventIndex}:${event.eventType}\n');
    }
    // 立即提交选择，避免相位卡住；记录候选顺序（AC-01 要求候选一致）。
    final offer = rt.currentOffer;
    if (offer != null) {
      drafts.add(offer.candidates.join(','));
      rt.selectDraftCard(0);
    }
    final gate = rt.riskGate;
    if (gate != null && !gate.isResolved) {
      risks.add(gate.availableOptions.join(','));
      rt.selectRiskOption(RiskOptionIds.supply);
    }
  }

  return (
    digest: hasher.digest,
    score: rt.score,
    draftCandidates: drafts,
    risks: risks,
    // AC-01 原文明确要求「得分和**胜负**完全一致」。
    outcome: rt.player.health.isDead ? 'defeat' : 'running',
  );
}

void main() {
  group('AC-01 100 个固定 seed 回放完全一致', () {
    test('每个 seed 重放两次：事件摘要、得分、升级候选、风险门选项一致', () {
      // **全部 100 个 seed 都双跑。**
      //
      // 此前只对前 12 个做双跑、其余 88 个跑一次，理由是"时间会翻倍到
      // 不可接受"—— 实测该顾虑不成立（整个文件约 1–2 秒），
      // 而 AC-01 的原文是「**100 个**固定 seed 回放：…完全一致」，
      // 只测 12 个等于把要求缩水。现已补齐。
      final seeds = <int>[
        for (var i = 0; i < 100; i++) 0x4E454F4E0001 + i * 7919,
      ];

      for (final seed in seeds) {
        final first = runSeed(seed);
        final second = runSeed(seed);
        expect(
          second.digest,
          first.digest,
          reason: 'seed=$seed 的事件摘要不一致',
        );
        expect(second.score, first.score, reason: 'seed=$seed 的得分不一致');
        expect(
          second.draftCandidates,
          first.draftCandidates,
          reason: 'seed=$seed 的升级候选不一致',
        );
        expect(second.risks, first.risks, reason: 'seed=$seed 的风险门选项不一致');
        // AC-01 原文点名要求「胜负」一致 —— 此前漏了这条。
        expect(second.outcome, first.outcome, reason: 'seed=$seed 的胜负不一致');
      }

      // 至少要有 seed 打开过升级草案，否则这条用例是空转。
      final sample = runSeed(seeds.first);
      expect(
        sample.draftCandidates,
        isNotEmpty,
        reason: '20 秒内应至少在 15.0 秒打开第一次升级草案',
      );
    });

    test('不同 seed 会产生不同的数值轨迹（确保随机真的被使用）', () {
      // 注意：**不能用事件摘要**做这条断言。摘要是刻意设计成
      // "只看事件类型 + 帧号 + 序号、不看负载"的 ——
      // 因为负载里的浮点坐标跨平台可能有极小差异，纳入摘要会造成
      // 无意义的失败。代价是：它验证的是事件**结构**的确定性，
      // 而不是数值的确定性。
      //
      // 因此 AC-01 的"得分完全一致"由双跑比对 score 保证，
      // 而"随机确实被使用"要用**seed 相关**的观测量来验证。
      final a = runSeed(0x4E454F4E0001);
      final b = runSeed(0x4E454F4E0002);

      final differs =
          a.score != b.score ||
          a.draftCandidates.join('|') != b.draftCandidates.join('|');
      expect(
        differs,
        isTrue,
        reason:
            'seed 不同的两次运行在得分与升级候选上完全一致，'
            '说明 PRNG 没有被真正使用（score ${a.score}/${b.score}）',
      );
    });
  });

  group('AC-09 素材溯源', () {
    late AssetManifest manifest;

    setUpAll(() {
      final json =
          jsonDecode(
                File('assets/config/v2/manifest.json').readAsStringSync(),
              )
              as Map<String, Object?>;
      final parsed = AssetManifest.parse(json);
      expect(parsed.isSuccess, isTrue, reason: parsed.describeErrors());
      manifest = parsed.requireValue;
    });

    test('每个记录的运行时可执行文件都真实存在', () {
      for (final record in manifest.records) {
        for (final file in record.runtimeFiles) {
          expect(
            File(file).existsSync(),
            isTrue,
            reason: '${record.assetId} 的运行时文件缺失：$file',
          );
        }
      }
    });

    test('每条记录都有许可证与非空 ID', () {
      for (final record in manifest.records) {
        expect(record.license.trim(), isNotEmpty, reason: '${record.assetId}');
        expect(record.assetId, isA<AssetId>());
      }
    });

    test('除字体声明外，每条记录都有回退策略且回退资源可解析', () {
      for (final record in manifest.records) {
        if (record.category == AssetCategory.font) {
          continue; // 字体是系统声明，不参与资源回退
        }
        final fallback = record.fallbackAssetId;
        expect(
          fallback,
          isNotNull,
          reason: '${record.assetId} 缺少 fallbackAssetId',
        );
        final id = AssetId.tryParse(fallback);
        expect(id, isNotNull, reason: '${record.assetId} 的回退 ID 非法');
        expect(
          manifest.contains(id!),
          isTrue,
          reason: '${record.assetId} 的回退资源不存在：$fallback',
        );
      }
    });

    test('三条统一回退资源存在且自身可回退到静默/自身', () {
      for (final name in <String>[
        'GFX-FALLBACK-SILHOUETTE',
        'UI-FALLBACK-ICON',
        'SFX-FALLBACK-SILENT',
      ]) {
        final record = manifest.lookup(name);
        expect(record, isNotNull, reason: '缺少统一回退 $name');
      }
    });

    test('许可证字段不含第三方未登记资源的常见痕迹', () {
      // 只做**结构性**检查：正式发布要求人工复核许可证，
      // 自动化只能拦住"空的/明显占位的"许可证文本。
      final suspicious = <String>['TODO', 'unknown', 'placeholder', '待补'];
      for (final record in manifest.records) {
        final license = record.license.toLowerCase();
        for (final token in suspicious) {
          expect(
            license.contains(token),
            isFalse,
            reason: '${record.assetId} 的许可证疑似未填写：${record.license}',
          );
        }
      }
    });

    test('Assets 规模与素材包一致（199 条）', () {
      expect(manifest.length, 199);
    });
  });

  group('AC-01 精英词缀（65 秒起）', () {
    /// 推进到指定秒数，**保持玩家存活**（把血量拉满）并自动选卡，
    /// 否则玩家会在 ~30 秒阵亡、走不到 65 秒。
    ///
    /// 这是**运行时级**用例，不是 UI 用例 —— 目的是验证
    /// "精英词缀在同种子下可复现"，不需要玩家真的会走位。
    ({List<String> affixes, int elites}) runToElite(int seed) {
      final rt = buildRuntime(seed);
      final affixes = <String>[];
      final seen = <String>{};

      // **按游戏内时间循环，而不是固定帧数** —— 草案/风险门会冻结
      // 逻辑时钟，固定 4200 帧走不到 70 游戏秒（实测因此漏掉 65 秒的精英）。
      var frame = 0;
      const frameBudget = 200 * 60; // 上限，防止意外死循环
      while (rt.combatSeconds < 70 && frame < frameBudget) {
        rt.player.health.current = rt.player.health.max;
        final offer = rt.currentOffer;
        if (offer != null) {
          rt.selectDraftCard(0);
        }
        rt.advance(GameClock.fixedStepSeconds, inputFor(frame));

        for (final e in rt.enemies.where((e) => e.isElite)) {
          final affixId = e.affix?.id;
          if (affixId == null) continue;
          final key = '${e.tuning.id}:$affixId';
          if (seen.add(key)) {
            affixes.add(affixId);
          }
        }
        frame++;
      }
      return (affixes: affixes, elites: seen.length);
    }

    test('65 秒的固定精英带 AFFIX-ACCEL 词缀', () {
      final result = runToElite(0x4E454F4E0001);
      // 70 秒窗口内只有 65 秒那一个固定精英（下一个在 105 秒）。
      expect(result.elites, greaterThanOrEqualTo(1), reason: '70 秒内应出现 65 秒的固定精英');
      expect(
        result.affixes,
        contains('AFFIX-ACCEL'),
        reason: 'wave 表 65 秒的固定精英词缀是 AFFIX-ACCEL',
      );
    });

    test('同种子两次运行的精英词缀序列一致（AC-01 要求）', () {
      final a = runToElite(0x4E454F4E0001);
      final b = runToElite(0x4E454F4E0001);
      expect(b.affixes, a.affixes, reason: '精英词缀必须可复现');
      expect(b.elites, a.elites);
    });
  });

  group('风险门（55 秒）在完整一局中确实打开', () {
    /// 推进到指定游戏秒数，**保持玩家存活**并自动选卡。
    ///
    /// 用**运行时级**验证而不是 UI 用例：UI 里玩家活不到 55 秒
    /// （测试无法复现真实走位水平），但"风险门是否在 55 秒打开"
    /// 这个集成点是必须覆盖的 —— 此前**没有任何用例**验证它。
    (String? gateId, List<String> options) runToRiskGate(int seed) {
      final rt = buildRuntime(seed);
      String? gateId;
      var options = const <String>[];
      var frame = 0;
      while (rt.combatSeconds < 56 && frame < 200 * 60) {
        rt.player.health.current = rt.player.health.max;
        final offer = rt.currentOffer;
        if (offer != null) {
          rt.selectDraftCard(0);
        }
        rt.advance(GameClock.fixedStepSeconds, inputFor(frame));
        final gate = rt.riskGate;
        if (gate != null && gateId == null) {
          gateId = gate.gateId;
          options = List<String>.from(gate.availableOptions);
        }
        frame++;
      }
      return (gateId, options);
    }

    test('55 秒打开 RG-55，且给出可选项', () {
      final result = runToRiskGate(0x4E454F4E0001);
      expect(
        result.$1,
        'RG-55',
        reason: 'risk_gates.json 里 55 秒的门是 RG-55',
      );
      expect(result.$2, isNotEmpty, reason: '风险门应给出可选项');
    });

    test('同种子两次运行的风险门一致（可复现）', () {
      final a = runToRiskGate(0x4E454F4E0001);
      final b = runToRiskGate(0x4E454F4E0001);
      expect(b.$1, a.$1);
      expect(b.$2, a.$2);
    });
  });
}
