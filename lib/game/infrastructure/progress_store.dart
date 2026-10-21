// ================================================================
// lib/game/infrastructure/progress_store.dart —— 本地设置与记录
//
// **架构位置**：Infrastructure（平台与 IO 适配） —— 把平台能力（音频/触觉/存档/性能）包成**可替换的端口**，便于测试注入替身。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：在假异步测试环境中须可注入替身 · 失败不得影响规则 · 平台不支持时静默 no-op。
//
// **本文件定义"存档契约"** —— 玩家进度（最高分/最佳通关/设置）的读写。
//
// **要点与易错点**：
//   * **存档失败绝不允许阻断对局**：读写异常必须被捕获并降级为"无进度"，
//     不得把异常抛到游戏循环里。**玩家想玩，不该因为存档坏了就玩不了。**
//   * **必须容忍"缺字段/多字段"**：旧版本存档在新版本里要能读
//     （缺失键取默认值），新存档在旧版本里读不出也不能崩。
//     **新增字段一律给默认值**，不要假定键一定存在。
//   * **不要在本层做业务判断**（例如"这个分数算不算纪录"）——
//     本层只负责存取，判断属 Domain。
//   * **测试必须注入替身**：真实实现走平台通道，在
//     `testWidgets` 的假异步区里不会完成；脚手架注入内存实现
//     （见 `mountV2App` 的 `store` 参数）。
//   * **写入应节流/合并**：不要把每一步都落盘（性能与磨损），
//     在关键节点（结算、设置变更）写即可。
// ================================================================
// 依据：产品基线 §8
//   「本地持久化键固定为：`settings.musicEnabled`、`settings.sfxEnabled`、
//     `settings.reduceMotion`、`settings.hapticsEnabled`、
//     `record.highScore`、`record.bestClearSeconds`、`schemaVersion`。
//     无任何账号和网络请求。」
//
// 架构 §2.1 的 `ProgressStore` 契约：
//   「读写失败不可阻断游玩」；架构 §7：
//   「存档失败 → 使用内存默认值；记录错误，下一次仍可尝试写入。」
//
// 因此本类**永不抛异常给调用方**：任何失败都退化为内存默认值。
// ================================================================

import 'package:flutter/foundation.dart' show TargetPlatform;

import 'haptics_port.dart';

/// 固定的持久化键。**不得增删或改名**（产品基线 §8）。


class ProgressKeys {
  static const String musicEnabled = 'settings.musicEnabled';
  static const String sfxEnabled = 'settings.sfxEnabled';
  static const String reduceMotion = 'settings.reduceMotion';
  static const String hapticsEnabled = 'settings.hapticsEnabled';
  static const String highScore = 'record.highScore';
  static const String bestClearSeconds = 'record.bestClearSeconds';
  static const String schemaVersion = 'schemaVersion';

  /// 当前存档 schema 版本。
  ///
  /// 高于本值的存档**只读不写**：不覆盖未知的高版本字段
  /// （测试计划 T-STORE-01）。
  static const int currentSchemaVersion = 1;
}

/// 底层键值存储的最小抽象。
abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 内存实现（测试默认，也是读写失败时的回退）。
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, String>? initial])
    : _data = <String, String>{...?initial};

  final Map<String, String> _data;

  Map<String, String> get snapshot => Map<String, String>.unmodifiable(_data);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

/// 每次操作都失败的存储，用来验证"存档失败不阻断游玩"。
class FailingKeyValueStore implements KeyValueStore {
  const FailingKeyValueStore();

  @override
  Future<String?> read(String key) async => throw StateError('read failed');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('write failed');

  @override
  Future<void> delete(String key) async => throw StateError('delete failed');
}

/// 设置。
class GameSettings {
  const GameSettings({
    this.musicEnabled = true,
    this.sfxEnabled = true,
    this.reduceMotion = false,
    this.hapticsEnabled = true,
  });

  final bool musicEnabled;
  final bool sfxEnabled;

  /// 减少动效（无障碍）：只降低非关键动效，不削弱预警与状态可读性
  /// （测试计划 T-UI-04）。
  final bool reduceMotion;

  final bool hapticsEnabled;

  /// **按平台取默认设置**（F-10 裁决）。
  ///
  /// 「支持触感的原生移动端**首次默认开**；Web/macOS **默认关**」。
  ///
  /// 为什么必须有这个工厂：`GameSettings()` 的字段默认值是一个
  /// **与平台无关的常量**，而裁决要求默认值**随平台变**。
  /// 首次安装（无存档）以及读取失败退化为默认时，都必须走这里 ——
  /// 否则 macOS / Web 上会默认开着触感，而它们根本没有触感能力。
  factory GameSettings.forPlatform({
    bool? isWebOverride,
    TargetPlatform? platformOverride,
    bool musicEnabled = true,
    bool sfxEnabled = true,
    bool reduceMotion = false,
  }) {
    return GameSettings(
      musicEnabled: musicEnabled,
      sfxEnabled: sfxEnabled,
      reduceMotion: reduceMotion,
      hapticsEnabled: platformSupportsHaptics(
        isWebOverride: isWebOverride,
        platformOverride: platformOverride,
      ),
    );
  }

  GameSettings copyWith({
    bool? musicEnabled,
    bool? sfxEnabled,
    bool? reduceMotion,
    bool? hapticsEnabled,
  }) => GameSettings(
    musicEnabled: musicEnabled ?? this.musicEnabled,
    sfxEnabled: sfxEnabled ?? this.sfxEnabled,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
  );

  @override
  bool operator ==(Object other) =>
      other is GameSettings &&
      other.musicEnabled == musicEnabled &&
      other.sfxEnabled == sfxEnabled &&
      other.reduceMotion == reduceMotion &&
      other.hapticsEnabled == hapticsEnabled;

  @override
  int get hashCode =>
      Object.hash(musicEnabled, sfxEnabled, reduceMotion, hapticsEnabled);
}

/// 本地记录。
class GameRecords {
  const GameRecords({this.highScore = 0, this.bestClearSeconds});

  final int highScore;

  /// 最快通关秒数；null 表示尚未通关过。
  final double? bestClearSeconds;

  /// 仅当更高时更新，返回是否刷新了记录。
  GameRecords withScore(int score) =>
      score > highScore ? GameRecords(highScore: score, bestClearSeconds: bestClearSeconds) : this;

  GameRecords withClearTime(double seconds) {
    final best = bestClearSeconds;
    if (best != null && best <= seconds) {
      return this;
    }
    return GameRecords(highScore: highScore, bestClearSeconds: seconds);
  }
}

/// 一次加载的结果。
class ProgressLoadResult {
  const ProgressLoadResult({
    required this.settings,
    required this.records,
    this.usedDefaults = false,
    this.readOnly = false,
    this.error,
  });

  final GameSettings settings;
  final GameRecords records;

  /// 是否退化到了内存默认值（读取失败或空存档）。
  final bool usedDefaults;

  /// 存档 schema 高于当前版本：**只读不写**，避免覆盖未知字段。
  final bool readOnly;

  final String? error;
}

/// 本地设置与记录。
class ProgressStore {
  ProgressStore({required this.store});

  final KeyValueStore store;

  bool _readOnly = false;
  String? _lastError;

  /// 最近一次读写的错误（可观察，但不阻断游玩）。
  String? get lastError => _lastError;
  bool get isReadOnly => _readOnly;

  /// 读取全部设置与记录。
  ///
  /// 任何异常都会被吞掉并退化为默认值 —— 存档问题**绝不阻断开局**。
  Future<ProgressLoadResult> load() async {
    try {
      // **WEB-T-05 内存态回退**：写盘失败时值只在 `_memoryMirror` 里，
      // 因此读路径必须先看镜像 —— 否则"退化为内存态"只是写了个寂寞 ✗。
      Future<String?> readWithMirror(String key) async {
        final fromStore = await store.read(key);
        return fromStore ?? _memoryMirror[key];
      }

      final versionRaw = await readWithMirror(ProgressKeys.schemaVersion);
      final version = int.tryParse(versionRaw ?? '');

      // 空存档：使用默认值。
      if (versionRaw == null) {
        return ProgressLoadResult(
          settings: GameSettings.forPlatform(),
          records: const GameRecords(),
          usedDefaults: true,
        );
      }

      // 旧存档：本版本按当前 schema 处理（version < current 时按默认补缺）。
      // 高版本：只读，绝不覆盖未知字段。
      if (version != null && version > ProgressKeys.currentSchemaVersion) {
        _readOnly = true;
      }

      final settings = GameSettings(
        musicEnabled: await _readBool(
          ProgressKeys.musicEnabled,
          fallback: true,
        ),
        sfxEnabled: await _readBool(ProgressKeys.sfxEnabled, fallback: true),
        reduceMotion: await _readBool(
          ProgressKeys.reduceMotion,
          fallback: false,
        ),
        hapticsEnabled: await _readBool(
          ProgressKeys.hapticsEnabled,
          fallback: true,
        ),
      );

      final scoreRaw = await readWithMirror(ProgressKeys.highScore);
      final clearRaw = await readWithMirror(ProgressKeys.bestClearSeconds);

      return ProgressLoadResult(
        settings: settings,
        records: GameRecords(
          highScore: int.tryParse(scoreRaw ?? '') ?? 0,
          bestClearSeconds: double.tryParse(clearRaw ?? ''),
        ),
        readOnly: _readOnly,
      );
    } catch (error) {
      // 损坏存档 / 读取失败：使用安全默认值，不阻塞开始。
      _lastError = '$error';
      return ProgressLoadResult(
        settings: GameSettings.forPlatform(),
        records: const GameRecords(),
        usedDefaults: true,
        error: _lastError,
      );
    }
  }

  Future<bool> _readBool(String key, {required bool fallback}) async {
    final raw = await store.read(key);
    if (raw == null) {
      return fallback;
    }
    return raw == 'true';
  }

  /// 保存设置。返回是否写入成功（失败不抛异常）。
  Future<bool> saveSettings(GameSettings settings) async {
    if (_readOnly) {
      return false;
    }
    return _writeAll(<String, String>{
      ProgressKeys.musicEnabled: '${settings.musicEnabled}',
      ProgressKeys.sfxEnabled: '${settings.sfxEnabled}',
      ProgressKeys.reduceMotion: '${settings.reduceMotion}',
      ProgressKeys.hapticsEnabled: '${settings.hapticsEnabled}',
      ProgressKeys.schemaVersion: '${ProgressKeys.currentSchemaVersion}',
    });
  }

  /// 保存记录。
  Future<bool> saveRecords(GameRecords records) async {
    if (_readOnly) {
      return false;
    }
    final values = <String, String>{
      ProgressKeys.highScore: '${records.highScore}',
      ProgressKeys.schemaVersion: '${ProgressKeys.currentSchemaVersion}',
    };
    final clear = records.bestClearSeconds;
    if (clear != null) {
      values[ProgressKeys.bestClearSeconds] = '$clear';
    }
    return _writeAll(values);
  }

  /// **内存态镜像**（WEB-T-05 要求）。
  ///
  /// 浏览器里 localStorage 可能因*隐私模式*、*配额满*、*策略禁用*而
  /// **写不进去** —— 规范要求此时设置与记录**"退化为内存态"** ✓，
  /// 而不是"这次存档丢掉" ✗。
  ///
  /// 差别很实际：玩家在隐私模式里打出一局好成绩，
  /// 至少**本次会话**能看到它（刷新后自然没了，那是浏览器的语义）。
  final Map<String, String> _memoryMirror = <String, String>{};

  Future<bool> _writeAll(Map<String, String> values) async {
    try {
      for (final entry in values.entries) {
        await store.write(entry.key, entry.value);
      }
      _lastError = null;
      // 写盘成功时内存镜像保持同步（让读路径单一）。
      _memoryMirror.addAll(values);
      return true;
    } catch (error) {
      // 架构 §7：记录错误，下一次仍可尝试写入。
      _lastError = '$error';
      // **退化而不是丢弃**：把值留在内存里，本次会话仍可读回 ✓
      _memoryMirror.addAll(values);
      return false;
    }
  }
}
