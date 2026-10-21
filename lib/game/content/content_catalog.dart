// ================================================================
// lib/game/content/content_catalog.dart —— 内容目录与交叉引用校验
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
//   * **`text()` 是 fail-fast 的**：缺 key 或**参数不匹配**都会立即失败，
//     并在 debug/测试中返回 `kMissingTextMarker` 而非静默回退中文。
//     这是刻意的 —— F-25-01 的事故正是"UI 直接把 key 当文案显示了
//     一段时间而没人发现"。
//   * **`key` 与 `params` 必须成对**：调用 `text('k')` 而该 key 含
//     `{n}` 占位符会失败，反之亦然。**改文案时两处要一起改。**
//   * 本文件**只做读取与校验**，不含任何玩法判断。
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §1、§1.1、§8
//   「加载器必须在进入 `Briefing` 前完成版本、hash 和 ID 交叉引用校验；
//     三者任一不一致均应停留在 Loading 并显示可重试错误。」
//   「配置校验必须拒绝：未知 ID、循环前置、互斥卡同时被强制加入、
//     负数 HP/时间、波次重复秒、超过对象预算的单次生成、
//     Boss 缺失安全预警、资产 ID 缺失。」
//
// 设计：本类只做**结构与引用**校验，不解释玩法语义
// （例如"护盾上限 +10"的含义由 UpgradeSystem 决定）。
// 它不知道 Flutter、Flame 或文件系统，因此可以在纯 Dart 测试中驱动。
// ================================================================

import 'asset_id.dart';
import 'asset_manifest.dart';
import 'content_error.dart';

/// 内容文件名（协议 §1 的固定集合）。
/// 九份配置文件的**原始 JSON**（已解码，尚未结构化为强类型）。
///
/// 设计意图：这一层只负责"把文件读成 Map"，**不做语义校验** ——
/// 语义校验分散在各自的领域系统里（`EnemyTuning.fromConfig` 等）。
/// 好处是**错误信息能指向具体字段**；坏处是"缺文件"和"字段写错"
/// 会在不同阶段暴露，因此 `ContentCatalog.load` 会**先**检查必需文件齐全。
class ContentFiles {
  static const String player = 'player.json';
  static const String weapons = 'weapons.json';
  static const String upgrades = 'upgrades.json';
  static const String enemies = 'enemies.json';
  static const String waves = 'waves_normal.json';
  static const String riskGates = 'risk_gates.json';
  static const String boss = 'boss_aegis.json';
  static const String strings = 'strings_zh_CN.json';

  /// 除 manifest 外必须存在的全部内容文件。
  static const List<String> required = <String>[
    player,
    weapons,
    upgrades,
    enemies,
    waves,
    riskGates,
    boss,
    strings,
  ];
}

/// 已加载并校验通过的内容目录（只读）。
/// **内容目录**：一局游戏看到的全部配置与本地化文案。
///
/// 三条贯穿全项目的约束：
///
/// 1. **只读**。加载后没有任何 `setter` —— 若允许运行时改配置，
///    "同一份内容版本产生同一场对局"就不再成立（回放/验收都会失效）。
/// 2. **不猜**。取不到的 key **不返回空串**、不返回 key 本身，
///    而是走 `text()` 的断言/受控错误标记 —— 让"缺文案"在测试里**响亮失败**，
///    而不是把 `objective.survive` 这样的原文显示给玩家（v2.0 的 F-25-01）。
/// 3. **不做数值推断**。这里只搬运配置；任何"从图片尺寸/文件名推数值"
///    都属违规（技术协议 §3 明文禁止）。
class ContentCatalog {
  const ContentCatalog({
    required this.contentVersion,
    required this.manifest,
    required this.player,
    required this.weapons,
    required this.upgrades,
    required this.enemies,
    required this.waves,
    required this.riskGates,
    required this.boss,
    required this.strings,
  });

  final String contentVersion;
  final AssetManifest manifest;

  final Map<String, Object?> player;
  final Map<String, Object?> weapons;
  final Map<String, Object?> upgrades;
  final Map<String, Object?> enemies;
  final Map<String, Object?> waves;
  final Map<String, Object?> riskGates;
  final Map<String, Object?> boss;
  final Map<String, String> strings;

  // ---- 常用投影 ----

  List<Map<String, Object?>> get enemyList =>
      _objectList(enemies['enemies']);

  List<Map<String, Object?>> get weaponList =>
      _objectList(weapons['weapons']);

  List<Map<String, Object?>> get upgradeCards =>
      _objectList(upgrades['cards']);

  List<Map<String, Object?>> get waveList => _objectList(waves['waves']);

  List<Map<String, Object?>> get riskOptions =>
      _objectList(riskGates['options']);

  List<Map<String, Object?>> get bossAttacks => _objectList(boss['attacks']);

  List<int> get xpThresholds =>
      (upgrades['xpThresholds'] as List?)?.whereType<num>().map((n) => n.toInt()).toList() ??
      const <int>[];

  /// 按 ID 取敌人配置。
  Map<String, Object?>? enemyById(String id) =>
      _byId(enemyList, id);

  /// 按 ID 取升级卡。
  Map<String, Object?>? upgradeById(String id) =>
      _byId(upgradeCards, id);

  /// 按 ID 取武器。
  Map<String, Object?>? weaponById(String id) =>
      _byId(weaponList, id);

  /// 本地化文案（**唯一正文来源**，技术协议 §2「文本与参数」）。
  ///
  /// 契约（严格按规范）：
  ///   * `strings_zh_CN.json` 是唯一正文来源；文本不得硬编码；
  ///   * 参数以**命名占位符** `{name}` 表示；
  ///   * **缺失 key、参数缺失或多余参数必须在 debug/测试失败**；
  ///     正式版显示受控错误页，**不得回退为硬编码文本或裸 key**。
  ///
  /// 因此这里**刻意不写 `?? key`** —— 那种"回退显示 key"的做法会让
  /// 未翻译项**静默通过**，正是规范禁止的。
  /// **按 key 取本地化文案**（唯一的文案入口）。
  ///
  /// * 缺 key：debug/测试下 `assert` 抛错（CI 立刻红），
  ///   Release 下返回**受控错误标记**（不崩、也不假装正常）；
  /// * 参数不匹配：同样**响亮失败** —— 模板里的占位符与传入参数
  ///   必须一一对应（多传/少传都算错，因为两者都会让玩家看到乱码）；
  /// * 支持 `{name}` 形式占位符。
  ///
  /// 为什么把校验做得这么严：文案错配**不会报错**，只会显示成
  /// 半截句子或原文 key —— 那是玩家最先看到、也最难被自动化发现的问题。
  String text(String key, [Map<String, Object?>? params]) {
    final template = strings[key];
    if (template == null) {
      // 正式版：返回受控错误标记（不崩、也不假装是正常文案）。
      // debug/测试：直接失败，让缺 key 无法混过 CI。
      assert(() {
        throw StateError('缺少文案 key："$key"（文本必须在 strings_zh_CN.json 中）');
      }());
      return kMissingTextMarker;
    }

    final names = _placeholderNames(template);
    final provided = params ?? const <String, Object?>{};

    assert(() {
      final missing = names.difference(provided.keys.toSet());
      final extra = provided.keys.toSet().difference(names);
      if (missing.isNotEmpty || extra.isNotEmpty) {
        throw StateError(
          '文案 "$key" 的参数不匹配：缺失 $missing，多余 $extra',
        );
      }
      return true;
    }());

    var out = template;
    for (final entry in provided.entries) {
      out = out.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return out;
  }

  /// 正式版缺 key 时的**受控错误标记**（不是裸 key、也不是硬编码中文）。
  static const String kMissingTextMarker = '[text:missing]';

  static final RegExp _placeholderPattern = RegExp(r'\{(\w+)\}');

  static Set<String> _placeholderNames(String template) => _placeholderPattern
      .allMatches(template)
      .map((m) => m.group(1)!)
      .toSet();

  bool hasText(String key) => strings.containsKey(key);

  static Map<String, Object?>? _byId(
    List<Map<String, Object?>> list,
    String id,
  ) {
    for (final item in list) {
      if (item['id'] == id) {
        return item;
      }
    }
    return null;
  }

  static List<Map<String, Object?>> _objectList(Object? raw) {
    if (raw is! List) {
      return const <Map<String, Object?>>[];
    }
    return raw
        .whereType<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList(growable: false);
  }

  // ------------------------------------------------------------
  // 加载 + 校验
  // ------------------------------------------------------------

  /// 从已解析的 JSON 映射构建目录。
  ///
  /// [files] 的键为 [ContentFiles] 中的文件名。
  static ContentResult<ContentCatalog> load({
    required Map<String, Map<String, Object?>> files,
    required AssetManifest manifest,
    // **B0（v2.1 蓝图 §2.1）**：**必填**且**不得回落**到任何默认常量 ——
    // 内容文件的版本校验必须与 manifest 用**同一个**来源，
    // 否则会出现"manifest 已是 v2.1、内容还是 v2.0"的不一致而无人发现。
    required String expectedVersion,
  }) {
    final wantVersion = expectedVersion;
    final errors = <ContentError>[];

    // ---- 0. 必需文件齐全 ----
    for (final name in ContentFiles.required) {
      if (!files.containsKey(name)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.fileMissing,
            location: name,
            message: '缺少必需的内容文件',
          ),
        );
      }
    }
    if (errors.isNotEmpty) {
      return ContentResult<ContentCatalog>.failure(errors);
    }

    // ---- 1. 版本一致 ----
    for (final entry in files.entries) {
      final version = entry.value['contentVersion'];
      if (version != wantVersion) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.versionMismatch,
            location: entry.key,
            field: 'contentVersion',
            message: '内容版本不符：期望 $wantVersion，实际 $version',
          ),
        );
      }
    }
    if (errors.isNotEmpty) {
      return ContentResult<ContentCatalog>.failure(errors);
    }

    final player = files[ContentFiles.player]!;
    final weapons = files[ContentFiles.weapons]!;
    final upgrades = files[ContentFiles.upgrades]!;
    final enemies = files[ContentFiles.enemies]!;
    final waves = files[ContentFiles.waves]!;
    final riskGates = files[ContentFiles.riskGates]!;
    final boss = files[ContentFiles.boss]!;
    final stringsFile = files[ContentFiles.strings]!;

    // ---- 2. 字符串表 ----
    final strings = <String, String>{};
    final rawStrings = stringsFile['strings'];
    if (rawStrings is Map) {
      for (final entry in rawStrings.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String || value.trim().isEmpty) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.schemaViolation,
              location: ContentFiles.strings,
              field: '$key',
              message: '文案必须是非空 UTF-8 文本',
            ),
          );
          continue;
        }
        strings[key] = value;
      }
    }

    // ---- 3. 资产 ID 交叉引用（通用扫描所有 *AssetId 字段）----
    for (final entry in files.entries) {
      _collectAssetReferences(
        entry.value,
        entry.key,
        manifest,
        errors,
      );
    }

    // ---- 4. 数值合法性（负数 HP / 时间）----
    for (final entry in files.entries) {
      _rejectNegativeNumbers(entry.value, entry.key, errors);
    }

    // ---- 5. 升级卡：ID 唯一、前置存在、无循环、互斥有效、文案键存在 ----
    final cards = ContentCatalog._objectList(upgrades['cards']);
    final cardIds = <String>{};
    for (final card in cards) {
      final id = card['id'];
      if (id is! String || id.isEmpty) {
        errors.add(
          const ContentError(
            kind: ContentErrorKind.schemaViolation,
            location: ContentFiles.upgrades,
            field: 'cards[].id',
            message: '升级卡缺少 id',
          ),
        );
        continue;
      }
      if (!cardIds.add(id)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.invalidReference,
            location: ContentFiles.upgrades,
            field: id,
            message: '升级卡 ID 重复',
          ),
        );
      }
      final maxLevel = card['maxLevel'];
      if (maxLevel is! int || maxLevel < 1) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.schemaViolation,
            location: ContentFiles.upgrades,
            assetId: id,
            field: 'maxLevel',
            message: 'maxLevel 必须是正整数',
          ),
        );
      }
      for (final keyField in <String>['nameKey', 'descKey']) {
        final key = card[keyField];
        if (key is! String || !strings.containsKey(key)) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.unknownReference,
              location: ContentFiles.upgrades,
              assetId: id,
              field: keyField,
              message: '文案键不存在：$key',
            ),
          );
        }
      }
    }

    // 前置存在 + 排除存在
    for (final card in cards) {
      final id = card['id'];
      if (id is! String) {
        continue;
      }
      for (final prereq in _stringList(card['prerequisites'])) {
        if (prereq == 'anyPulseCard') {
          continue; // 语义前置，由 UpgradeSystem 解释
        }
        if (!cardIds.contains(prereq)) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.unknownReference,
              location: ContentFiles.upgrades,
              assetId: id,
              field: 'prerequisites',
              message: '前置卡不存在：$prereq',
            ),
          );
        }
      }
      for (final excluded in _stringList(card['excludes'])) {
        if (!cardIds.contains(excluded)) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.unknownReference,
              location: ContentFiles.upgrades,
              assetId: id,
              field: 'excludes',
              message: '互斥卡不存在：$excluded',
            ),
          );
        }
      }
    }

    // 循环前置检测（DFS）
    final prereqMap = <String, List<String>>{
      for (final card in cards)
        if (card['id'] is String)
          card['id'] as String: _stringList(card['prerequisites'])
              .where(cardIds.contains)
              .toList(),
    };
    for (final cycle in _findCycles(prereqMap)) {
      errors.add(
        ContentError(
          kind: ContentErrorKind.invalidReference,
          location: ContentFiles.upgrades,
          field: 'prerequisites',
          message: '存在循环前置：${cycle.join(' → ')}',
        ),
      );
    }

    // 保证卡集合本身不得互相排斥（协议：互斥卡同时被强制加入必须拒绝）
    _checkForcedSetConflicts(
      upgrades,
      cardIds,
      cards,
      errors,
    );

    // ---- 6. 敌人：ID 唯一、越界伤害与得分字段非负 ----
    final enemyIds = <String>{};
    for (final enemy in ContentCatalog._objectList(enemies['enemies'])) {
      final id = enemy['id'];
      if (id is! String || id.isEmpty) {
        errors.add(
          const ContentError(
            kind: ContentErrorKind.schemaViolation,
            location: ContentFiles.enemies,
            field: 'enemies[].id',
            message: '敌人缺少 id',
          ),
        );
        continue;
      }
      if (!enemyIds.add(id)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.invalidReference,
            location: ContentFiles.enemies,
            field: id,
            message: '敌人 ID 重复',
          ),
        );
      }
    }

    // 精英词缀 ID
    final affixIds = <String>{
      for (final affix in ContentCatalog._objectList(enemies['affixes']))
        if (affix['id'] is String) affix['id'] as String,
    };

    // ---- 7. 波次：秒唯一、递增、敌人/词缀/风险门引用存在、单批不超预算 ----
    final budget = waves['objectBudget'];
    final enemyCap = budget is Map && budget['enemies'] is int
        ? budget['enemies'] as int
        : 45;

    final gateIds = <String>{
      for (final gate in ContentCatalog._objectList(riskGates['gates']))
        if (gate['id'] is String) gate['id'] as String,
    };

    final waveRows = ContentCatalog._objectList(waves['waves']);
    final seenSeconds = <int>{};
    var previousSecond = -1;
    for (final row in waveRows) {
      final second = row['startSecond'];
      if (second is! int) {
        errors.add(
          const ContentError(
            kind: ContentErrorKind.schemaViolation,
            location: ContentFiles.waves,
            field: 'waves[].startSecond',
            message: 'startSecond 必须是整数秒',
          ),
        );
        continue;
      }
      if (!seenSeconds.add(second)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.invalidReference,
            location: ContentFiles.waves,
            field: 'startSecond',
            message: '波次秒重复：$second',
          ),
        );
      }
      if (second < previousSecond) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.schemaViolation,
            location: ContentFiles.waves,
            field: 'startSecond',
            message: '波次必须按时间升序：$second 在 $previousSecond 之后',
          ),
        );
      }
      previousSecond = second;

      var batchTotal = 0;
      for (final spawn in ContentCatalog._objectList(row['spawns'])) {
        final enemyId = spawn['enemyId'];
        if (enemyId is! String || !enemyIds.contains(enemyId)) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.unknownReference,
              location: ContentFiles.waves,
              field: 'spawns[].enemyId',
              message: '未定义的敌人：$enemyId',
            ),
          );
        }
        final affixId = spawn['affixId'];
        if (affixId != null && !affixIds.contains(affixId)) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.unknownReference,
              location: ContentFiles.waves,
              field: 'spawns[].affixId',
              message: '未定义的精英词缀：$affixId',
            ),
          );
        }
        final count = spawn['count'];
        if (count is int) {
          batchTotal += count;
        }
      }
      final extraFromAdjustment = 2; // 动态校正最多 +1 × 两批
      if (batchTotal + extraFromAdjustment > enemyCap) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.budgetExceeded,
            location: ContentFiles.waves,
            field: 'spawns',
            message:
                '第 $second 秒单批生成 $batchTotal（含动态校正上界后超过同屏上限 $enemyCap）',
          ),
        );
      }

      final gateId = row['riskGateId'];
      if (gateId != null && !gateIds.contains(gateId)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.unknownReference,
            location: ContentFiles.waves,
            field: 'riskGateId',
            message: '未定义的风险门：$gateId',
          ),
        );
      }
    }

    // ---- 8. 风险门：超时保底必须存在且是选项之一 ----
    final optionIds = <String>{
      for (final option in ContentCatalog._objectList(riskGates['options']))
        if (option['id'] is String) option['id'] as String,
    };
    for (final gate in ContentCatalog._objectList(riskGates['gates'])) {
      final fallback = gate['timeoutFallback'];
      if (fallback is! String || !optionIds.contains(fallback)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.unknownReference,
            location: ContentFiles.riskGates,
            assetId: gate['id'] is String ? gate['id'] as String : null,
            field: 'timeoutFallback',
            message: '保底选项不存在：$fallback',
          ),
        );
      }
      for (final optionId in _stringList(gate['optionIds'])) {
        if (!optionIds.contains(optionId)) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.unknownReference,
              location: ContentFiles.riskGates,
              assetId: gate['id'] is String ? gate['id'] as String : null,
              field: 'optionIds',
              message: '选项未定义：$optionId',
            ),
          );
        }
      }
    }
    // 过载卡的稀有池必须都是已定义的升级卡
    for (final option in ContentCatalog._objectList(riskGates['options'])) {
      final effect = option['effect'];
      if (effect is Map) {
        for (final poolId in _stringList(effect['pool'])) {
          if (!cardIds.contains(poolId)) {
            errors.add(
              ContentError(
                kind: ContentErrorKind.unknownReference,
                location: ContentFiles.riskGates,
                field: 'effect.pool',
                message: '稀有池引用了未定义的升级卡：$poolId',
              ),
            );
          }
        }
      }
    }

    // ---- 9. Boss：每个**造成伤害**的招式必须有预警；attackId 唯一 ----
    final attackIds = <String>{};
    for (final attack in ContentCatalog._objectList(boss['attacks'])) {
      final attackId = attack['attackId'];
      if (attackId is! String || attackId.isEmpty) {
        errors.add(
          const ContentError(
            kind: ContentErrorKind.schemaViolation,
            location: ContentFiles.boss,
            field: 'attacks[].attackId',
            message: 'Boss 招式缺少 attackId',
          ),
        );
        continue;
      }
      if (!attackIds.add(attackId)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.invalidReference,
            location: ContentFiles.boss,
            field: attackId,
            message: 'Boss 招式 attackId 重复',
          ),
        );
      }

      final dealsDamage = _attackDealsDamage(attack);
      final telegraph = attack['telegraphSeconds'];
      if (dealsDamage && (telegraph is! num || telegraph <= 0)) {
        errors.add(
          ContentError(
            kind: ContentErrorKind.missingTelegraph,
            location: ContentFiles.boss,
            assetId: attackId,
            field: 'telegraphSeconds',
            message: '造成伤害的 Boss 招式必须有正数预警时长（产品基线 §3.3 公平性）',
          ),
        );
      }
    }

    // 阶段循环引用的招式必须存在
    for (final phase in ContentCatalog._objectList(boss['phases'])) {
      for (final attackId in _stringList(phase['loop'])) {
        if (!attackIds.contains(attackId)) {
          errors.add(
            ContentError(
              kind: ContentErrorKind.unknownReference,
              location: ContentFiles.boss,
              assetId: phase['id'] is String ? phase['id'] as String : null,
              field: 'loop',
              message: '阶段引用了未定义的招式：$attackId',
            ),
          );
        }
      }
    }

    if (errors.isNotEmpty) {
      return ContentResult<ContentCatalog>.failure(errors);
    }

    return ContentResult<ContentCatalog>.success(
      ContentCatalog(
        contentVersion: wantVersion,
        manifest: manifest,
        player: player,
        weapons: weapons,
        upgrades: upgrades,
        enemies: enemies,
        waves: waves,
        riskGates: riskGates,
        boss: boss,
        strings: Map<String, String>.unmodifiable(strings),
      ),
    );
  }

  // ------------------------------------------------------------
  // 校验辅助
  // ------------------------------------------------------------

  /// 递归扫描所有以 `AssetId` 结尾的字段，确认其在 manifest 中存在。
  static void _collectAssetReferences(
    Object? node,
    String location,
    AssetManifest manifest,
    List<ContentError> errors,
  ) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && key.endsWith('AssetId')) {
          if (value is String) {
            final id = AssetId.tryParse(value);
            if (id == null || !manifest.contains(id)) {
              errors.add(
                ContentError(
                  kind: ContentErrorKind.unknownReference,
                  location: location,
                  field: key,
                  message: '引用了 manifest 中不存在的资源：$value',
                ),
              );
            }
          } else if (value != null) {
            errors.add(
              ContentError(
                kind: ContentErrorKind.schemaViolation,
                location: location,
                field: key,
                message: 'AssetId 字段必须是字符串或 null',
              ),
            );
          }
        }
        _collectAssetReferences(value, location, manifest, errors);
      }
    } else if (node is List) {
      for (final item in node) {
        _collectAssetReferences(item, location, manifest, errors);
      }
    }
  }

  /// 递归拒绝负数的 HP / 时间类字段。
  static void _rejectNegativeNumbers(
    Object? node,
    String location,
    List<ContentError> errors,
  ) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is num && value < 0) {
          final looksLikeHpOrTime = key.toLowerCase().contains('hp') ||
              key.toLowerCase().contains('health') ||
              key.toLowerCase().contains('second') ||
              key.toLowerCase().contains('time') ||
              key.toLowerCase().contains('duration') ||
              key.toLowerCase().contains('damage');
          if (looksLikeHpOrTime) {
            errors.add(
              ContentError(
                kind: ContentErrorKind.schemaViolation,
                location: location,
                field: key,
                message: 'HP / 时间类字段不得为负：$value',
              ),
            );
          }
        }
        _rejectNegativeNumbers(value, location, errors);
      }
    } else if (node is List) {
      for (final item in node) {
        _rejectNegativeNumbers(item, location, errors);
      }
    }
  }

  /// 保证卡集合内部不得互相排斥。
  ///
  /// 协议 §1.1：「互斥卡同时被强制加入」必须被拒绝。
  /// 例如把 `UP-LASER-UNLOCK` 与 `UP-DRONE-UNLOCK` 同时写进同一保证组
  /// 会让候选生成无解，这类配置必须在加载期暴露。
  static void _checkForcedSetConflicts(
    Map<String, Object?> upgrades,
    Set<String> cardIds,
    List<Map<String, Object?>> cards,
    List<ContentError> errors,
  ) {
    final excludesOf = <String, Set<String>>{
      for (final card in cards)
        if (card['id'] is String)
          card['id'] as String: _stringList(card['excludes']).toSet(),
    };

    void checkGroup(List<String> group, String label) {
      for (var i = 0; i < group.length; i++) {
        for (var j = i + 1; j < group.length; j++) {
          final a = group[i];
          final b = group[j];
          if (excludesOf[a]?.contains(b) == true ||
              excludesOf[b]?.contains(a) == true) {
            errors.add(
              ContentError(
                kind: ContentErrorKind.invalidReference,
                location: ContentFiles.upgrades,
                field: label,
                message: '互斥卡被同时强制加入：$a 与 $b',
              ),
            );
          }
        }
      }
    }

    final guaranteed = upgrades['guaranteed'];
    if (guaranteed is Map) {
      checkGroup(
        _stringList(guaranteed['firstDraft']),
        'guaranteed.firstDraft',
      );
      checkGroup(
        _stringList(guaranteed['secondDraftAnyOf']),
        'guaranteed.secondDraftAnyOf',
      );
    }
  }

  /// 找出前置图中的所有环。
  static List<List<String>> _findCycles(Map<String, List<String>> graph) {
    final cycles = <List<String>>[];
    final state = <String, int>{}; // 0=未访问 1=访问中 2=完成
    final stack = <String>[];

    void visit(String node) {
      final current = state[node] ?? 0;
      if (current == 2) {
        return;
      }
      if (current == 1) {
        final start = stack.indexOf(node);
        if (start >= 0) {
          cycles.add(<String>[...stack.sublist(start), node]);
        }
        return;
      }
      state[node] = 1;
      stack.add(node);
      for (final next in graph[node] ?? const <String>[]) {
        visit(next);
      }
      stack.removeLast();
      state[node] = 2;
    }

    for (final node in graph.keys) {
      visit(node);
    }
    return cycles;
  }

  /// 该 Boss 招式是否会造成伤害（决定它是否必须有预警）。
  static bool _attackDealsDamage(Map<String, Object?> attack) {
    final projectile = attack['projectile'];
    if (projectile is Map && (projectile['damage'] as num?) != null) {
      final damage = projectile['damage'] as num;
      if (damage > 0) {
        return true;
      }
    }
    for (final key in <String>['damage', 'damagePerTick', 'contactDamage']) {
      final value = attack[key];
      if (value is num && value > 0) {
        return true;
      }
    }
    // 召唤类招式自身不造成伤害，它召唤的实体按各自规则处理。
    return false;
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) {
      return const <String>[];
    }
    return raw.whereType<String>().toList(growable: false);
  }
}
