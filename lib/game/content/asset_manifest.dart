// ================================================================
// lib/game/content/asset_manifest.dart —— 正式资源清单模型与校验
//
// **架构位置**：Content 层 —— **内容与代码的分界线**。
//   产品数值、文案、素材绑定**全部来自配置**，代码不得硬编码这些值；
//   本层负责把它们**读进来、校验、并提供类型安全的访问**。
//
// **与谁交互**：
//   * 上游：`V2Bootstrap.loadCatalog()`（进入 Briefing 前）
//   * 下游：各 Domain 系统（经 `GameRuntime` 装配）、表现层（经 manifest）
//
// **关键约束**：
//   * **失败必须响亮**：缺 key、参数不匹配、ID 未登记等都必须在
//     **加载期**抛错，禁止以默认值兜底 —— 带着坏内容开局比开不了局更糟
//   * **文本只存在于 `strings_zh_CN.json`**；代码里出现玩家可见中文
//     由 `T-COPY-01` 静态守卫拦截
//
// **⚠️ 易错点（真实事故）**：
//   * **`sha256` 的语义按类别不同**（极易误判！）：
//       - **音频**：`sha256` = **源母带 WAV** 的哈希（`sourceFile` 指向它）；
//       - **图形/UI**：`sha256` = **首个运行时 PNG**（canonical）的哈希，
//         而 `sourceFile`（源设计稿）**不在哈希登记范围内**，只做存在性校验。
//     我在做 AC-09 溯源复验时先断言"`sha256` 应等于 `sourceFile` 的哈希"，
//     **于是把 8 个图形误报为"溯源断裂"** —— 那是我的假设错误，不是素材缺陷。
//     实测依据：`sha256 == runtimeSha256[0]` 恰 **129** 条（图形/UI 数），
//     源稿哈希出现在登记中恰 **67** 条（音频数）。
//   * **`runtimeSha256[]` 与 `renderStates` 的汇总顺序按索引对齐** ——
//     遍历时若顺序不一致，校验会全体错位。
//   * **类别枚举是 `ui`/`sfx`/`graphic`/`bgm`/`font`**，**没有 `audio`**
//     （我按 `'audio'` 判过，导致 68 条音频全部落入图形分支误报）。
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
//   * `contentVersion` 由调用方显式传入（唯一来源 `kActiveContentVersion`），
//     本文件**不再**持有版本字面量。
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
    this.frameRects = const <List<int>>[],
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

  /// **v2.1 新增**：每个子图在整张 **sheet** 中的像素裁切矩形。
  ///
  /// 语义：`frameRects[i] = [x, y, w, h]`（左上原点，单位 px），
  /// 沿同一张 sheet（`runtimeFiles` 的单张图）裁切出第 `i` 帧。
  ///
  /// **为什么需要它**：v2.0 资源是"**每帧一个 PNG**"，运行时不需要裁切；
  /// v2.1 的素材是**整张 sheet（2172×724）+ 精确 frameRect**
  /// （素材规范 §2），因此裁切信息必须由 manifest 承载 ——
  /// **绝不允许从文件名或格子等分去推断帧**（素材规范 §1 明文禁止）。
  ///
  /// 契约：**长度必须等于 `frameCount`**（静态单帧则为 1 项或空）。
  /// 数量不符会让帧错位（画出相邻子图或空白），由 `parse` 直接拒绝。
  final List<List<int>> frameRects;

  /// 是否使用 sheet + frameRect 模型（v2.1），而非"每帧一文件"（v2.0）。
  bool get usesSheetFrameRects => frameRects.isNotEmpty;

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

  // **B0（v2.1 蓝图 §2.1）**：此处**不再**硬编码内容版本。
  //
  // 存在理由：v2.0 时版本号写死在本文件，导致 `parse` 有一个**隐式默认值** ——
  // 调用方漏传也能"看起来正确"，升级版本时容易只改一处而漏改其他。
  // 现在 `expectedVersion` **必填**，唯一来源是
  // `v2_bootstrap.kActiveContentVersion`，从编译期就杜绝漏传。
  //
  // 门禁（蓝图）：**代码中不得出现第二个 v2.1 版本字面量**。

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
  /// [expectedVersion] **必填**，由 `V2Bootstrap` 传入唯一版本常量。
  /// 版本不符时返回 [ContentErrorKind.versionMismatch] 而不是抛异常，
  /// 让 Loading 页可以显示可重试错误（保留 v2.0 的可重试行为）。
  static ContentResult<AssetManifest> parse(
    Map<String, Object?> json, {
    required String expectedVersion,
  }) {
    final errors = <ContentError>[];
    final wantVersion = expectedVersion;

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
          errors: errors,
          assetId: assetId.value,
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
    String location, {
    required List<ContentError> errors,
    required String assetId,
  }) {
    final interval = map['frameInterval'];
    var frameStart = 0;
    var frameEnd = 0;
    if (interval is List && interval.length == 2) {
      frameStart = interval[0] is int ? interval[0] as int : 0;
      frameEnd = interval[1] is int ? interval[1] as int : 0;
    }
    final frameCount =
        map['frameCount'] is int ? map['frameCount'] as int : 1;

    // **v2.1**：解析 `frameRect`（整张 sheet 的子图裁切表）。
    // 支持两种写法：
    //   * 单帧：`[x, y, w, h]`
    //   * 多帧：`[[x,y,w,h], [x,y,w,h], ...]`
    final frameRects = _parseFrameRects(map['frameRect']);
    if (frameRects.isNotEmpty && frameRects.length != frameCount) {
      // ⚠️ **必须是结构化错误，不能抛异常** ——
      // 本文件的既有设计是"返回 `ContentError` 而不是抛异常"，
      // 以便 Loading 页显示**可重试**错误（见 `parse` 的文档）。
      // 我第一版写成 `throw`，会绕过这条契约，已修正。
      errors.add(
        ContentError(
          kind: ContentErrorKind.schemaViolation,
          location: location,
          assetId: assetId,
          field: 'renderStates.frameRect',
          message: 'frameRect 数量（${frameRects.length}）与 '
              'frameCount（$frameCount）不一致 —— 会导致帧错位；'
              '素材规范 §2 要求每个子图各自给出精确裁切。',
        ),
      );
    }

    return RenderStateSpec(
      runtimeFiles: _stringList(map['runtimeFiles']),
      frameStart: frameStart,
      frameEnd: frameEnd,
      frameCount: frameCount,
      fps: map['fps'] is num ? (map['fps'] as num).toDouble() : 0,
      blendMode: map['blendMode'] is String
          ? map['blendMode'] as String
          : 'normal',
      anchor: _doubleList(map['anchor'], fallback: const <double>[0.5, 0.5]),
      frameRects: frameRects,
    );
  }

  /// 解析 `frameRect`：接受 `[x,y,w,h]`（单帧）或 `[[x,y,w,h], ...]`（多帧）。
  ///
  /// 每项必须是**恰好 4 个整数**且 `w`/`h` **为正** ——
  /// 宽高为 0 的裁切会画出空白帧，属于应当**响亮失败**的配置错误。
  static List<List<int>> _parseFrameRects(Object? raw) {
    if (raw == null) {
      return const <List<int>>[];
    }
    final asList = raw is List ? raw : null;
    if (asList == null || asList.isEmpty) {
      return const <List<int>>[];
    }
    // 单帧写法：[0, 0, 543, 724]
    if (asList.length == 4 && asList.every((e) => e is int)) {
      final rect = asList.cast<int>();
      return rect[2] > 0 && rect[3] > 0
          ? <List<int>>[rect]
          : const <List<int>>[];
    }
    // 多帧写法：[[...], [...]]
    final out = <List<int>>[];
    for (final item in asList) {
      if (item is! List || item.length != 4) {
        return const <List<int>>[];
      }
      final rect = <int>[];
      for (final v in item) {
        if (v is! int) {
          return const <List<int>>[];
        }
        rect.add(v);
      }
      if (rect[2] <= 0 || rect[3] <= 0) {
        return const <List<int>>[];
      }
      out.add(rect);
    }
    return out;
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
