// ================================================================
// lib/game/infrastructure/asset_loader.dart —— 事件 → 资源路由表
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §7
//   「AssetLoader 必须在首次播放/渲染前将 eventBindings 解析为不可变表，
//     且只按 `event + when` 条件匹配，**禁止仅凭 triggerEvents、
//     文件名或显示文本选资源**。」
//   素材规范 §1.1
//   「`when` 为空仅允许用于没有可区分参数的生命周期事件；敌机攻击 binding
//     必须同时填写 enemyId 与 attackId，Boss 攻击 binding 必须填写 attackId。」
//
// 以及 T-ASSET-02：
//   「逐个喂入 manifest 所列 eventBindings 的事件 fixture，输出的
//     Asset ID、renderState/cueId 与 binding 精确一致；
//     任一无匹配或多匹配均失败。」
//
// 因此本模块的核心契约是：**匹配结果必须恰好一条**。
// 0 条 → [BindingMatchStatus.noMatch]；≥2 条 → [BindingMatchStatus.ambiguous]。
// 两者都是需要被测试暴露的配置缺陷，而不是"取第一条"糊过去。
// ================================================================

import '../content/asset_id.dart';
import '../content/asset_manifest.dart';

/// 一次绑定解析的结果状态。
enum BindingMatchStatus {
  /// 恰好命中一条。
  matched,

  /// 没有任何绑定匹配。
  noMatch,

  /// 命中多条（含"本应互斥的条件同时成立"与"配置写得太宽泛"）。
  ambiguous,
}

/// 一条命中的图形/UI 路由。
class ResolvedVisual {
  const ResolvedVisual({
    required this.assetId,
    required this.binding,
    this.renderState,
    this.stateSpec,
    this.runtimeFiles = const <String>[],
    this.transientMs,
    this.restoreFromSnapshot = false,
  });

  final AssetId assetId;
  final IndexedBinding binding;
  final String? renderState;
  final RenderStateSpec? stateSpec;
  final List<String> runtimeFiles;
  final int? transientMs;
  final bool restoreFromSnapshot;
}

/// 一条命中的音频路由。
class ResolvedCue {
  const ResolvedCue({
    required this.assetId,
    required this.binding,
    this.cueId,
    this.bus,
    this.loop = false,
    this.priority = 0,
    this.maxVoices = 1,
    this.minRetriggerMs = 0,
  });

  final AssetId assetId;
  final IndexedBinding binding;
  final String? cueId;
  final String? bus;
  final bool loop;
  final int priority;
  final int maxVoices;
  final int minRetriggerMs;
}

/// 一条已索引的绑定。
class IndexedBinding {
  const IndexedBinding({
    required this.record,
    required this.event,
    required this.when,
    this.renderState,
    this.transientMs,
    this.restoreFromSnapshot = false,
  });

  final AssetRecord record;
  final String event;
  final Map<String, Object?> when;
  final String? renderState;
  final int? transientMs;
  final bool restoreFromSnapshot;

  @override
  String toString() =>
      '${record.assetId}${renderState == null ? '' : '#$renderState'} '
      'when=$when';
}

/// 不可变的事件 → 资源路由表。
class AssetBindingTable {
  AssetBindingTable._(this.visualByEvent, this.audioByEvent, this.records);

  final Map<String, List<IndexedBinding>> visualByEvent;
  final Map<String, List<IndexedBinding>> audioByEvent;
  final Map<AssetId, AssetRecord> records;

  /// 该事件是否至少有一条图形绑定。
  bool hasVisualBinding(String event) =>
      (visualByEvent[event] ?? const <IndexedBinding>[]).isNotEmpty;

  /// 该事件是否至少有一条音频绑定。
  bool hasAudioBinding(String event) =>
      (audioByEvent[event] ?? const <IndexedBinding>[]).isNotEmpty;

  Iterable<String> get boundEvents => <String>{
    ...visualByEvent.keys,
    ...audioByEvent.keys,
  };

  /// 解析图形/UI 的**全部**匹配。
  ///
  /// 一个事件可以驱动多个视觉层，这是设计使然而不是缺陷：
  /// 例如 `EnemyAttackTelegraphed{EN-SNIPER, sniper_line}` 同时命中
  ///   * `GFX-EN-SNIPER#charge` —— 机体自身的蓄力状态；
  ///   * `GFX-WARN-LINE`        —— 地面上的线形预警标记。
  /// 两者都要显示，因此这里返回列表，由表现层按资源语义分层使用。
  ///
  /// 「无匹配」仍然是必须暴露的缺陷：事件带了参数却没有任何绑定命中，
  /// 说明要么 manifest 漏了路由，要么事件负载缺字段。调用方应当据此
  /// 记录 Asset ID 并使资源验收失败（协议 §7）。
  List<ResolvedVisual> resolveVisuals(
    String event, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    final bindings = visualByEvent[event] ?? const <IndexedBinding>[];
    return <ResolvedVisual>[
      for (final binding in bindings)
        if (AssetBindingTable.matches(binding.when, params))
          ResolvedVisual(
            assetId: binding.record.assetId,
            renderState: binding.renderState,
            stateSpec: binding.renderState == null
                ? null
                : binding.record.renderStates[binding.renderState],
            runtimeFiles: binding.renderState == null
                ? binding.record.runtimeFiles
                : (binding.record.renderStates[binding.renderState]
                          ?.runtimeFiles ??
                      binding.record.runtimeFiles),
            transientMs: binding.transientMs,
            restoreFromSnapshot: binding.restoreFromSnapshot,
            binding: binding,
          ),
    ];
  }

  /// 解析音频 cue 的**全部**匹配（通常为 1 条，但不预设上限）。
  List<ResolvedCue> resolveCues(
    String event, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    final bindings = audioByEvent[event] ?? const <IndexedBinding>[];
    return <ResolvedCue>[
      for (final binding in bindings)
        if (AssetBindingTable.matches(binding.when, params))
          ResolvedCue(
            assetId: binding.record.assetId,
            cueId: binding.record.cueId,
            bus: binding.record.bus,
            loop: binding.record.loop,
            priority: binding.record.priority ?? 0,
            maxVoices: binding.record.maxVoices ?? 1,
            minRetriggerMs: binding.record.minRetriggerMs ?? 0,
            binding: binding,
          ),
    ];
  }

  /// 判断某个事件在给定参数下是否**恰好**命中一条图形绑定。
  ///
  /// 用于那些语义上只能有一个结果的场合（例如 HUD 的某个控件状态）。
  BindingMatchStatus visualMatchStatus(
    String event, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    final count = resolveVisuals(event, params).length;
    if (count == 0) {
      return BindingMatchStatus.noMatch;
    }
    return count == 1 ? BindingMatchStatus.matched : BindingMatchStatus.ambiguous;
  }

  /// 条件匹配。
  ///
  /// 支持的键形态（与正式 manifest 实际使用的一致）：
  ///   * `xxxLte`：参数 `xxx` 存在且 `≤ 期望值`；
  ///   * `xxxGt` ：参数 `xxx` 存在且 `> 期望值`；
  ///   * 其余：参数键与期望值**严格相等**。
  ///
  /// 缺失参数一律视为不匹配 —— 这样"事件没带 attackId"会被暴露成
  /// noMatch，而不是静默命中一条宽泛绑定。
  static bool matches(
    Map<String, Object?> when,
    Map<String, Object?> params,
  ) {
    for (final entry in when.entries) {
      final key = entry.key;
      final expected = entry.value;

      if (key.endsWith('Lte')) {
        final actual = params[key.substring(0, key.length - 3)];
        if (actual is! num || expected is! num || actual > expected) {
          return false;
        }
        continue;
      }
      if (key.endsWith('Gt')) {
        final actual = params[key.substring(0, key.length - 2)];
        if (actual is! num || expected is! num || actual <= expected) {
          return false;
        }
        continue;
      }
      if (params[key] != expected) {
        return false;
      }
    }
    return true;
  }
}

/// 从 [AssetManifest] 构建路由表。
class AssetLoader {
  const AssetLoader();

  /// 构建不可变路由表。可在首次渲染前调用一次并长期持有。
  AssetBindingTable build(AssetManifest manifest) {
    final visual = <String, List<IndexedBinding>>{};
    final audio = <String, List<IndexedBinding>>{};

    for (final record in manifest.records) {
      for (final binding in record.eventBindings) {
        final indexed = IndexedBinding(
          record: record,
          event: binding.event,
          when: binding.when,
          renderState: binding.renderState,
          transientMs: binding.transientMs,
          restoreFromSnapshot: binding.restoreFromSnapshot,
        );
        final target = record.category.isVisual ? visual : audio;
        target.putIfAbsent(binding.event, () => <IndexedBinding>[]).add(indexed);
      }
    }

    return AssetBindingTable._(
      _freeze(visual),
      _freeze(audio),
      Map<AssetId, AssetRecord>.unmodifiable(manifest.byId),
    );
  }

  static Map<String, List<IndexedBinding>> _freeze(
    Map<String, List<IndexedBinding>> source,
  ) => Map<String, List<IndexedBinding>>.unmodifiable(
    <String, List<IndexedBinding>>{
      for (final entry in source.entries)
        entry.key: List<IndexedBinding>.unmodifiable(entry.value),
    },
  );
}
