// ================================================================
// lib/game/content/asset_manifest.dart —— 正式资源清单模型与校验
// ================================================================
// 依据：Spec/03_素材/Warship_v2.0素材清单与制作规范.md §1.1、§6
//   02_技术/v2.0/02_运行时与数据协议.md §1、§7
//
// 强约束：
//   * `素材/manifest.json` 是**唯一**允许被运行时解析的资源索引，
//     不得硬编码资源路径、不得按文件名猜资源、不得创建第二份 manifest；
//   * `AssetLoader` 必须在首次播放/渲染前把 `eventBindings` 解析为
//     不可变表，且只按 `event + when` 条件匹配 ——
//     禁止仅凭 `triggerEvents`、文件名或显示文本选资源；
//   * `contentVersion` 当前唯一允许值为 `2.0.6-material-repair`。
// ================================================================

import 'asset_id.dart';
import 'content_error.dart';

/// 资源大类。
enum AssetCategory {
  graphic,
  ui,
  sfx,
  bgm,
  font;

  static AssetCategory? tryParse(String? raw) {
    for (final value in AssetCategory.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return null;
  }

  /// 是否为需要解码的图形资源（决定进哪个运行时资源目录与内存预算）。
  bool get isVisual => this == AssetCategory.graphic || this == AssetCategory.ui;

  /// 是否为音频资源（决定是否参与音频总线与并发规则）。
  bool get isAudio => this == AssetCategory.sfx || this == AssetCategory.bgm;
}

/// 加载分组（协议 §7：firstRun 预载，boss 在 Boss 倒计时前预载，lazy 惰性）。
enum AssetLoadGroup {
  firstRun,
  boss,
  lazy;

  static AssetLoadGroup? tryParse(String? raw) {
    for (final value in AssetLoadGroup.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return null;
  }
}

/// 单个渲染状态的资源描述。
class RenderStateSpec {
  const RenderStateSpec({
    required this.runtimeFiles,
    required this.frameStart,
    required this.frameEnd,
    required this.frameCount,
    required this.fps,
    required this.blendMode,
    required this.anchor,
  });

  /// Flutter 资源键（由构建复制阶段写入，运行时原样使用）。
  final List<String> runtimeFiles;

  /// 序列帧起止（静态资源为 [0,0]，是显式合同）。
  final int frameStart;
  final int frameEnd;
  final int frameCount;
  final double fps;
  final String blendMode;
  final List<double> anchor;

  bool get isAnimated => frameCount > 1;
}

/// 一条 `DomainEvent → renderState / cueId` 的精确路由。
class EventBinding {
  const EventBinding({
    required this.event,
    required this.when,
    this.renderState,
    this.transientMs,
    this.restoreFromSnapshot = false,
  });

  /// 事件类型名（与协议 §3 的事件名一致）。
  final String event;

  /// 匹配条件。空 map 表示该事件没有可区分参数（例如 `DashStarted`）。
  final Map<String, Object?> when;

  /// 命中的渲染状态（图形资源）。
  final String? renderState;

  /// 临时状态时长（毫秒）。到期必须按 [restoreFromSnapshot] 处理。
  final int? transientMs;

  /// 到期后是否恢复最后一份数值/防御状态（禁止凭文件名推断）。
  final bool restoreFromSnapshot;

  /// 条件中是否声明了该键。
  bool hasCondition(String key) => when.containsKey(key);

  /// 读取字符串条件。
  String? stringCondition(String key) {
    final value = when[key];
    return value is String ? value : null;
  }

  /// 读取布尔条件。
  bool? boolCondition(String key) {
    final value = when[key];
    return value is bool ? value : null;
  }

  /// 读取数值条件。
  double? numberCondition(String key) {
    final value = when[key];
    return value is num ? value.toDouble() : null;
  }
}

/// 一条 manifest 资源记录。
class AssetRecord {
  const AssetRecord({
    required this.assetId,
    required this.category,
    required this.license,
    required this.loadGroup,
    required this.states,
    required this.runtimeFiles,
    required this.renderStates,
    required this.eventBindings,
    required this.memoryEstimateBytes,
    this.fallbackAssetId,
    this.cueId,
    this.bus,
    this.priority,
    this.maxVoices,
    this.minRetriggerMs,
    this.loop = false,
  });

  final AssetId assetId;
  final AssetCategory category;
  final String license;
  final AssetLoadGroup loadGroup;

  /// 声明支持的语义状态（§7.5 状态合同）。
  final List<String> states;

  /// 全部运行时文件（图形为各状态文件；音频为单个 MP3）。
  final List<String> runtimeFiles;

  /// 状态 → 资源（仅图形/UI 有意义）。
  final Map<String, RenderStateSpec> renderStates;

  /// 精确事件路由。
  final List<EventBinding> eventBindings;

  final String? fallbackAssetId;
  final int memoryEstimateBytes;

  // ---- 音频专有 ----
  final String? cueId;
  final String? bus;
  final int? priority;
  final int? maxVoices;
  final int? minRetriggerMs;
  final bool loop;

  bool get isAudio => category.isAudio;
  bool get isVisual => category.isVisual;

  /// 该资源是否声明了某个状态。
  bool hasState(String state) => states.contains(state);
}

/// 正式资源清单。
class AssetManifest {
  const AssetManifest({
    required this.schemaVersion,
    required this.contentVersion,
    required this.byId,
  });

  /// 当前唯一允许的内容版本（协议 §1）。
  static const String requiredContentVersion = '2.0.6-material-repair';

  /// 预期 schema 版本（素材规范 §8 的 v2.0.2 补充）。
  static const String expectedSchemaVersion = '1.1.0';

  final String schemaVersion;
  final String contentVersion;
  final Map<AssetId, AssetRecord> byId;

  Iterable<AssetRecord> get records => byId.values;

  int get length => byId.length;

  AssetRecord? operator [](AssetId id) => byId[id];

  AssetRecord? lookup(String id) => byId[AssetId.tryParse(id)];

  bool contains(AssetId id) => byId.containsKey(id);

  /// 指定加载分组的全部资源（Loading 阶段预载 firstRun）。
  Iterable<AssetRecord> inLoadGroup(AssetLoadGroup group) =>
      byId.values.where((r) => r.loadGroup == group);

  // ------------------------------------------------------------
  // 解析与校验
  // ------------------------------------------------------------

  /// 从 manifest JSON 解析并校验。
  ///
  /// [expectedVersion] 默认取 [requiredContentVersion]；
  /// 版本不符时返回 [ContentErrorKind.versionMismatch] 而不是抛异常，
  /// 让 Loading 页可以显示可重试错误。
  static ContentResult<AssetManifest> parse(
    Map<String, Object?> json, {
    String? expectedVersion,
  }) {
    final errors = <ContentError>[];
    final wantVersion = expectedVersion ?? requiredContentVersion;

    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! String || schemaVersion.isEmpty) {
      errors.add(
        const ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: 'manifest.json',
          field: 'schemaVersion',
          message: '缺少 schemaVersion',
        ),
      );
    }

    final contentVersion = json['contentVersion'];
    if (contentVersion is! String) {
      errors.add(
        const ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: 'manifest.json',
          field: 'contentVersion',
          message: '缺少 contentVersion',
        ),
      );
    } else if (contentVersion != wantVersion) {
      errors.add(
        ContentError(
          kind: ContentErrorKind.versionMismatch,
          location: 'manifest.json',
          field: 'contentVersion',
          message: '内容版本不符：期望 $wantVersion，实际 $contentVersion',
        ),
      );
    }

    final rawAssets = json['assets'];
    if (rawAssets is! List) {
      errors.add(
        const ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: 'manifest.json',
          field: 'assets',
          message: 'assets 必须是数组',
        ),
      );
      return ContentResult<AssetManifest>.failure(errors);
    }

    final byId = <AssetId, AssetRecord>{};
    for (var i = 0; i < rawAssets.length; i++) {
      final raw = rawAssets[i];
      final location = 'manifest.json#assets[$i]';
      if (raw is! Map) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.schemaViolation,
            location: location,
            message: '记录必须是对象',
          ),
        );
        continue;
      }
      final map = raw.cast<String, Object?>();
      final record = _parseRecord(map, location, errors);
      if (record == null) {
        continue;
      }
      if (byId.containsKey(record.assetId)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.invalidReference,
            location: location,
            assetId: record.assetId.value,
            message: 'AssetId 重复',
          ),
        );
        continue;
      }
      byId[record.assetId] = record;
    }

    // 交叉校验：fallback 必须真实存在（素材规范 §1.1 三条统一回退必须可解析）。
    for (final record in byId.values) {
      final fallback = record.fallbackAssetId;
      if (fallback == null || fallback.isEmpty) {
        continue;
      }
      final fallbackId = AssetId.tryParse(fallback);
      if (fallbackId == null) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.unknownReference,
            location: 'manifest.json#${record.assetId.value}',
            assetId: record.assetId.value,
            field: 'fallbackAssetId',
            message: '回退 ID 格式非法：$fallback',
          ),
        );
      } else if (!byId.containsKey(fallbackId)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.unknownReference,
            location: 'manifest.json#${record.assetId.value}',
            assetId: record.assetId.value,
            field: 'fallbackAssetId',
            message: '回退资源不存在：$fallback',
          ),
        );
      }
    }

    if (errors.isNotEmpty) {
      return ContentResult<AssetManifest>.failure(errors);
    }

    return ContentResult<AssetManifest>.success(
      AssetManifest(
        schemaVersion: schemaVersion as String,
        contentVersion: contentVersion as String,
        byId: Map<AssetId, AssetRecord>.unmodifiable(byId),
      ),
    );
  }

  static AssetRecord? _parseRecord(
    Map<String, Object?> map,
    String location,
    List<ContentError> errors,
  ) {
    final rawId = map['assetId'];
    final assetId = rawId is String ? AssetId.tryParse(rawId) : null;
    if (assetId == null) {
      errors.add(
        ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: location,
          field: 'assetId',
          message: '缺少或非法的 assetId：$rawId',
        ),
      );
      return null;
    }

    final where = 'manifest.json#${assetId.value}';

    final category = AssetCategory.tryParse(map['category'] as String?);
    if (category == null) {
      errors.add(
        ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: where,
          assetId: assetId.value,
          field: 'category',
          message: '未知 category：${map['category']}',
        ),
      );
      return null;
    }

    final license = map['license'];
    if (license is! String || license.trim().isEmpty) {
      errors.add(
        ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: where,
          assetId: assetId.value,
          field: 'license',
          message: '许可证不得为空（素材规范 §6）',
        ),
      );
    }

    // 字体记录是"系统字体声明"（只有 systemFallbacks，没有物理运行时文件），
    // 因此不要求 loadGroup；其余类别必须显式声明加载分组，
    // 因为协议 §7 的预载策略（firstRun / boss / lazy）依赖它。
    final loadGroup =
        AssetLoadGroup.tryParse(map['loadGroup'] as String?) ??
        (category == AssetCategory.font ? AssetLoadGroup.lazy : null);
    if (loadGroup == null) {
      errors.add(
        ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: where,
          assetId: assetId.value,
          field: 'loadGroup',
          message: '未知或缺失的 loadGroup：${map['loadGroup']}',
        ),
      );
      return null;
    }

    final states = _stringList(map['states']);
    final runtimeFiles = _stringList(map['runtimeFiles']);

    final renderStates = <String, RenderStateSpec>{};
    final rawRenderStates = map['renderStates'];
    if (rawRenderStates is Map) {
      for (final entry in rawRenderStates.entries) {
        final stateName = entry.key;
        final value = entry.value;
        if (stateName is! String || value is! Map) {
          continue;
        }
        renderStates[stateName] = _parseRenderState(
          value.cast<String, Object?>(),
          '$where.renderStates.$stateName',
        );
      }
    }

    // 多状态图形的每个声明状态都必须有可达资源（素材规范 §1.1）。
    if (category.isVisual) {
      if (renderStates.isEmpty) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.schemaViolation,
            location: where,
            assetId: assetId.value,
            field: 'renderStates',
            message: '图形/UI 资源必须提供 renderStates',
          ),
        );
      }
      for (final state in states) {
        final spec = renderStates[state];
        if (spec == null) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.unknownReference,
              location: where,
              assetId: assetId.value,
              field: 'renderStates',
              message: '声明的状态缺少 renderStates 映射：$state',
            ),
          );
        } else if (spec.runtimeFiles.isEmpty) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.schemaViolation,
              location: where,
              assetId: assetId.value,
              field: 'renderStates.$state',
              message: '状态 $state 没有运行时文件',
            ),
          );
        }
      }
    }

    final eventBindings = <EventBinding>[];
    final rawBindings = map['eventBindings'];
    if (rawBindings is List) {
      for (final raw in rawBindings) {
        if (raw is! Map) {
          continue;
        }
        final binding = _parseBinding(
          raw.cast<String, Object?>(),
          where,
          assetId.value,
          errors,
        );
        if (binding != null) {
          eventBindings.add(binding);
        }
      }
    }

    final cueId = map['cueId'];
    if (category.isAudio && (cueId is! String || cueId.isEmpty)) {
      errors.add(
        ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: where,
          assetId: assetId.value,
          field: 'cueId',
          message: '音频资源必须提供 cueId（与 AudioCue 一一对应）',
        ),
      );
    }

    final memory = map['memoryEstimateBytes'];

    return AssetRecord(
      assetId: assetId,
      category: category,
      license: license is String ? license : '',
      loadGroup: loadGroup,
      states: states,
      runtimeFiles: runtimeFiles,
      renderStates: Map<String, RenderStateSpec>.unmodifiable(renderStates),
      eventBindings: List<EventBinding>.unmodifiable(eventBindings),
      memoryEstimateBytes: memory is int && memory >= 0 ? memory : 0,
      fallbackAssetId: map['fallbackAssetId'] as String?,
      cueId: cueId is String ? cueId : null,
      bus: map['bus'] as String?,
      priority: map['priority'] as int?,
      maxVoices: map['maxVoices'] as int?,
      minRetriggerMs: map['minRetriggerMs'] as int?,
      loop: map['loop'] == true,
    );
  }

  static RenderStateSpec _parseRenderState(
    Map<String, Object?> map,
    String location,
  ) {
    final interval = map['frameInterval'];
    var frameStart = 0;
    var frameEnd = 0;
    if (interval is List && interval.length == 2) {
      frameStart = interval[0] is int ? interval[0] as int : 0;
      frameEnd = interval[1] is int ? interval[1] as int : 0;
    }
    return RenderStateSpec(
      runtimeFiles: _stringList(map['runtimeFiles']),
      frameStart: frameStart,
      frameEnd: frameEnd,
      frameCount: map['frameCount'] is int ? map['frameCount'] as int : 1,
      fps: map['fps'] is num ? (map['fps'] as num).toDouble() : 0,
      blendMode: map['blendMode'] is String
          ? map['blendMode'] as String
          : 'normal',
      anchor: _doubleList(map['anchor'], fallback: const <double>[0.5, 0.5]),
    );
  }

  static EventBinding? _parseBinding(
    Map<String, Object?> map,
    String where,
    String assetId,
    List<ContentError> errors,
  ) {
    final event = map['event'];
    if (event is! String || event.isEmpty) {
      errors.add(
        ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: where,
          assetId: assetId,
          field: 'eventBindings.event',
          message: '绑定缺少 event',
        ),
      );
      return null;
    }

    final when = <String, Object?>{};
    final rawWhen = map['when'];
    if (rawWhen is Map) {
      when.addAll(rawWhen.cast<String, Object?>());
    }

    return EventBinding(
      event: event,
      when: Map<String, Object?>.unmodifiable(when),
      renderState: map['renderState'] as String?,
      transientMs: map['transientMs'] as int?,
      restoreFromSnapshot: map['restoreFromSnapshot'] == true,
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) {
      return const <String>[];
    }
    return List<String>.unmodifiable(raw.whereType<String>());
  }

  static List<double> _doubleList(Object? raw, {required List<double> fallback}) {
    if (raw is! List) {
      return fallback;
    }
    final values = raw.whereType<num>().map((n) => n.toDouble()).toList();
    return values.isEmpty ? fallback : List<double>.unmodifiable(values);
  }
}
