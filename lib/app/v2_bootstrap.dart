// ================================================================
// lib/app/v2_bootstrap.dart —— v2.0 启动引导
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §1
//   「加载器必须在进入 Briefing 前完成版本、hash 和 ID 交叉引用校验；
//     三者任一不一致均应停留在 Loading 并显示可重试错误。」
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
import '../game/domain/director_system.dart';
import '../game/domain/enemy_system.dart';
import '../game/domain/weapon_system.dart';
import '../game/infrastructure/asset_loader.dart';

/// 内容根目录（构建复制品）。
const String kConfigRoot = 'assets/config/v2';

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

    final manifestResult = AssetManifest.parse(manifestJson);
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
  }) {
    final tunings = <String, EnemyTuning>{
      for (final raw in catalog.enemyList)
        (raw['id'] as String): EnemyTuning.fromConfig(raw),
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
      enemySystem: EnemySystem(breachWarningY: 920, breachRemoveY: 1140),
      pulse: PulseWeapon(),
      breachNormalHpDamage: (breach['normalHpDamage'] as num?)?.toInt() ?? 8,
      breachEliteHpDamage: (breach['eliteHpDamage'] as num?)?.toInt() ?? 15,
    );
  }
}

/// 内容校验失败。
class ContentFailure implements Exception {
  const ContentFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
