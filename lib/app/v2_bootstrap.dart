// ================================================================
// lib/app/v2_bootstrap.dart —— v2.0 启动引导
// ================================================================
// **架构位置**：App 层。**依赖装配的唯一入口** ——
//   把「磁盘上的内容配置 + 素材」翻译成「Domain 可直接使用的运行时对象」。
//
// **依据**：Spec/02_技术/v2.0/02_运行时与数据协议.md §1
//   「加载器必须在进入 Briefing 前完成版本、hash 和 ID 交叉引用校验；
//     三者任一不一致均应停留在 Loading 并显示可重试错误。」
//
// **与谁交互**：
//   * 上游：`main.dart` / `V2AppFlow`
//   * 下游：`ContentCatalog`（内容）→ 各 Domain 系统的构造
//   * 产出：`GameRuntime`（含 `DirectorSystem` / `EnemySystem` / `BossSystem` …）
//
// **⚠️ 本文件最重要的易错点（真实事故，务必先读）**：
//   `buildRuntime` 必须把**每一个** Domain 系统都传进 `GameRuntime`。
//   曾经漏传 `bossSystem` —— 而 `_startBossFight()` 的首行守卫正是
//   `if (bossSystem == null) return;`，于是**150 秒的 bossEntry 波次行
//   被正常触发，但 Boss 入场被静默跳过**：玩家永远打不到 Boss、
//   **永远无法通关**（F-39，P0 发布阻塞）。
//   该缺陷的表现极具迷惑性：时间正常推进、行索引正常走到 31/31，
//   只有 Boss 不出现。最终靠"行已消费但实体不存在"这一对照才定位。
//   **因此：新增/修改 Domain 系统时，必须确认此处同步注入。**
//
// **关键约束**：
//   * 内容校验失败必须**拒绝开局**，不得以默认值兜底 ——
//     配置错误要在加载期暴露，而不是运行期变成难查的玩法异常
//   * `bossTelegraphs` 的素材按 manifest 的 `BossAttackTelegraphed`
//     **视觉**绑定解析；Boss 侧该绑定**唯一**（每招只对应一个 graphic），
//     故按 `attackId` 解析**无歧义**。敌机侧则**不可**这样做 ——
//     `sniper_line` 同时绑定机体与预警两张图，按 attackId 会命中机体
//     （F-38 的事故），故敌机侧必须由配置注入 `telegraphAssetId`。
//
// 这里只从 `assets/config/v2/` 读取（由 `tool/build_v2_assets.dart`
// 从仓库根目录 素材/ 复制而来），不接触 v1.x 的 assets/images、assets/audio。
// ================================================================

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../game/content/asset_manifest.dart';
import '../game/content/content_catalog.dart';
import '../game/core/event_bus.dart';
import '../game/core/game_clock.dart';
import '../game/core/game_phase.dart';
import '../game/core/game_runtime.dart';
import '../game/core/phase_controller.dart';
import '../game/core/random_source.dart';
import '../game/core/run_context.dart';
import '../game/domain/boss_system.dart';
import '../game/domain/director_system.dart';
import '../game/domain/enemy_system.dart';
import '../game/domain/risk_gate_system.dart';
import '../game/domain/upgrade_system.dart';
import '../game/domain/weapon_system.dart';
import '../game/infrastructure/asset_loader.dart';
import '../game/infrastructure/audio_director.dart';
import '../game/infrastructure/haptics_director.dart';

/// 内容根目录（构建复制品）。
const String kConfigRoot = 'assets/config/v2';

/// **v2.1 唯一版本入口**（蓝图 §2.1）。
///
/// ⚠️ **全项目只允许此处出现内容版本字面量**（门禁："代码中没有第二个
/// v2.1 版本字面量"）。`AssetManifest.parse` 与 `ContentCatalog.load`
/// 都必须接收它，从而保证 manifest 与 8 份内容文件**校验同一个版本**。
/// 新增/升级版本时**只改这一行**。
const String kActiveContentVersion = '2.1.0-neon-flow';

/// 启动结果。
class BootResult {
  const BootResult({
    this.runtime,
    this.bindingTable,
    this.manifest,
    this.catalog,
    this.error,
  });

  final GameRuntime? runtime;
  final AssetBindingTable? bindingTable;
  final AssetManifest? manifest;

  /// 已校验通过的内容目录（供相位流程直接构建运行时）。
  final ContentCatalog? catalog;
  final String? error;

  bool get isReady => runtime != null;
}

/// 引导 v2.0。
class V2Bootstrap {
  const V2Bootstrap();

  /// 加载并校验内容，构建一局运行时。
  ///
  /// 任何校验失败都返回 [BootResult.error]，由 Loading 页显示可重试错误，
  /// 且**禁止进入对局**（架构 §7）。
  Future<BootResult> boot({
    int seed = 0x4E454F4E0001,
    ContentCatalog? preloaded,
  }) async {
    try {
      final catalog = preloaded ?? await loadCatalog();
      return BootResult(
        runtime: buildRuntime(catalog: catalog, seed: seed),
        bindingTable: const AssetLoader().build(catalog.manifest),
        manifest: catalog.manifest,
        catalog: catalog,
      );
    } on ContentFailure catch (failure) {
      return BootResult(error: failure.message);
    } catch (error) {
      return BootResult(error: '$error');
    }
  }

  /// 读取并校验 manifest 与全部内容文件。
  Future<ContentCatalog> loadCatalog() async {
    final manifestJson =
        jsonDecode(await rootBundle.loadString('$kConfigRoot/manifest.json'))
            as Map<String, Object?>;

    final manifestResult = AssetManifest.parse(
      manifestJson,
      expectedVersion: kActiveContentVersion,
    );
    if (manifestResult.isFailure) {
      throw ContentFailure(manifestResult.describeErrors());
    }

    final files = <String, Map<String, Object?>>{};
    for (final name in ContentFiles.required) {
      files[name] =
          jsonDecode(await rootBundle.loadString('$kConfigRoot/$name'))
              as Map<String, Object?>;
    }

    final catalogResult = ContentCatalog.load(
      files: files,
      manifest: manifestResult.requireValue,
      expectedVersion: kActiveContentVersion,
    );
    if (catalogResult.isFailure) {
      throw ContentFailure(catalogResult.describeErrors());
    }
    return catalogResult.requireValue;
  }

  /// 由已校验的内容构建一局运行时。
  GameRuntime buildRuntime({
    required ContentCatalog catalog,
    required int seed,
    AudioDirector? audioDirector,
    HapticsDirector? hapticsDirector,
  }) {
    final tunings = <String, EnemyTuning>{
      for (final raw in catalog.enemyList)
        (raw['id'] as String): EnemyTuning.fromConfig(raw),
    };

    // 精英词缀表。**此前这里完全缺失** —— `EliteAffix.fromConfig`
    // 定义了却从未被调用，波次表的 `affixId` 也就无处解析，
    // 于是精英有 6 倍血量但没有任何词缀行为。
    final affixes = <String, EliteAffix>{
      for (final raw in (catalog.enemies['affixes'] as List? ?? const [])
          .cast<Map>())
        (raw['id'] as String):
            EliteAffix.fromConfig(raw.cast<String, Object?>()),
    };

    final windows = ((catalog.waves['dynamicAdjustment'] as Map)
            ['minimumUpgradeCountBySecond'] as List)
        .cast<Map>()
        .map((m) => MinimumUpgradeWindow.fromConfig(m.cast<String, Object?>()))
        .toList();
    final rows = catalog.waveList.map(WaveRow.fromConfig).toList();
    final budget = catalog.waves['objectBudget'] as Map?;
    final enemyCap = (budget?['enemies'] as num?)?.toInt() ?? 45;

    final breach = (catalog.player['breach'] as Map?) ?? const <String, Object?>{};

    return GameRuntime(
      catalogPlayer: catalog.player,
      enemyTunings: tunings,
      eliteAffixes: affixes,
      // **F-38**：Boss 招式预警规格（attackId → 素材/形状/时长）。
      // 素材取自 manifest 的 `BossAttackTelegraphed` **视觉**绑定
      //（已核对：每个 Boss 招式只对应一个图形素材，故无歧义）；
      // 形状与时长取自 `boss_aegis.json`。
      bossTelegraphs: _buildBossTelegraphs(catalog),
      runtime: RunContext(
        identity: RunIdentity(
          runId: 'run-$seed-${DateTime.now().microsecondsSinceEpoch}',
          seed: seed,
          prngAlgorithm: Pcg32(seed).algorithm,
          contentVersion: catalog.contentVersion,
          contentManifestSha256: 'runtime',
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
        totalEnemyCap: enemyCap,
      ),
      // **F-39 修复**：`bossSystem` 此前**从未传入** —— 而
      // `_startBossFight()` 的第一行守卫是 `if (bossSystem == null) return;`，
      // 因此**真实应用里 Boss 永远不会生成**，玩家永远无法通关。
      // 这是"声明了没接上"类缺陷：150 秒的 `bossEntry` 波次行被正常触发
      //（诊断实测 `nextRowIndex` 走到 31/31），但入场处理被静默跳过。
      bossSystem: BossSystem(),
      enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
      pulse: PulseWeapon(),
      breachNormalHpDamage: (breach['normalHpDamage'] as num?)?.toInt() ?? 8,
      breachEliteHpDamage: (breach['eliteHpDamage'] as num?)?.toInt() ?? 15,
      upgradeSystem: buildUpgradeSystem(catalog),
      riskGateSystem: buildRiskGateSystem(catalog),
      audioDirector: audioDirector,
      hapticsDirector: hapticsDirector,
    );
  }
}

/// 由已校验内容构建升级系统。
UpgradeSystem buildUpgradeSystem(ContentCatalog catalog) {
  final guaranteed = catalog.upgrades['guaranteed'] as Map?;
  return UpgradeSystem(
    cards: catalog.upgradeCards.map(UpgradeCard.fromConfig).toList(),
    xpThresholds: catalog.xpThresholds,
    firstDraftEarliestSecond:
        (catalog.upgrades['firstDraftEarliestSecond'] as num?)?.toDouble() ??
        15.0,
    maxDrafts: (catalog.upgrades['maxDrafts'] as num?)?.toInt() ?? 6,
    draftSize: (catalog.upgrades['draftSize'] as num?)?.toInt() ?? 3,
    damageCardIds:
        ((catalog.upgrades['damageCardIds'] as List?) ?? const <Object?>[])
            .whereType<String>()
            .toSet(),
    guaranteedFirstDraft:
        ((guaranteed?['firstDraft'] as List?) ?? const <Object?>[])
            .whereType<String>()
            .toList(),
    guaranteedSecondDraftAnyOf:
        ((guaranteed?['secondDraftAnyOf'] as List?) ?? const <Object?>[])
            .whereType<String>()
            .toList(),
  );
}

/// 由已校验内容构建风险门系统。
RiskGateSystem buildRiskGateSystem(ContentCatalog catalog) {
  final common = catalog.riskGates['common'] as Map?;
  final overload = catalog.riskOptions.firstWhere(
    (o) => o['id'] == RiskOptionIds.overload,
    orElse: () => const <String, Object?>{},
  );
  final pool = ((overload['effect'] as Map?)?['pool'] as List?)
          ?.whereType<String>()
          .toList() ??
      const <String>[];
  final condition = overload['availableCondition'] as Map?;

  return RiskGateSystem(
    overloadHpThreshold:
        (condition?['hpAbove'] as num?)?.toInt() ?? 35,
    selectionWindowSeconds:
        (common?['selectionWindowSeconds'] as num?)?.toDouble() ?? 5.0,
    timeoutFallbackId:
        common?['timeoutFallbackId'] as String? ?? RiskOptionIds.supply,
    overloadRarePool: pool,
  );
}

/// 内容校验失败。
class ContentFailure implements Exception {
  const ContentFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// **F-38**：从 manifest 视觉绑定 + `boss_aegis.json` 组装 Boss 预警规格。
///
/// 为什么可以按 `attackId` 解析素材：**Boss 招式的视觉绑定是唯一的**
///（实测：`boss_fan→GFX-WARN-CONE`、`boss_charge→GFX-WARN-CHARGE`、
/// `boss_ring→GFX-WARN-CIRCLE`、`boss_laser→GFX-WARN-LASER`，
/// 各只对应一个 `graphic`，另有同名 `sfx`）。
/// 这与敌机侧不同（`sniper_line` 同时绑定机体与预警素材），
/// 因此敌机侧必须用配置注入，而 Boss 侧此处解析是**无歧义**的。
Map<String, BossTelegraphSpec> _buildBossTelegraphs(ContentCatalog catalog) {
  final assetsByAttack = <String, String>{};
  for (final record in catalog.manifest.records) {
    if (!record.isVisual) {
      continue;
    }
    for (final binding in record.eventBindings) {
      if (binding.event == 'BossAttackTelegraphed') {
        final attackId = binding.when['attackId'] as String?;
        if (attackId != null) {
          assetsByAttack[attackId] = record.assetId.value;
        }
      }
    }
  }

  final out = <String, BossTelegraphSpec>{};
  final raw = catalog.boss;
  for (final attack in ((raw['attacks'] as List?) ?? const []).cast<Map>()) {
    final attackId = attack['attackId'] as String?;
    final assetId = assetsByAttack[attackId];
    final seconds = (attack['telegraphSeconds'] as num?)?.toDouble() ?? 0;
    if (attackId == null || assetId == null || seconds <= 0) {
      continue;
    }
    out[attackId] = BossTelegraphSpec(
      assetId: assetId,
      shape: (attack['telegraphShape'] as String?) ?? 'circle',
      totalSeconds: seconds,
    );
  }
  return out;
}
