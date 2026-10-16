// ================================================================
// lib/game/infrastructure/shared_preferences_store.dart
//
// **架构位置**：Infrastructure（平台与 IO 适配） —— 把平台能力（音频/触觉/存档/性能）包成**可替换的端口**，便于测试注入替身。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：在假异步测试环境中须可注入替身 · 失败不得影响规则 · 平台不支持时静默 no-op。
// ================================================================
// 依据：产品基线 §8
//   「本地持久化键固定为：… 无任何账号和网络请求。」
//
// `shared_preferences` 在 macOS / iOS / Android / Web / Windows / Linux
// 上都有实现，因此这一层是**平台适配**，不含任何产品规则
// （架构 §2：infrastructure 负责平台适配，不负责产品规则）。
//
// 选用它而不是自己写文件，是为了保持 Web 兼容：`dart:io` 在 Web 上不可用，
// 而 WP-09 的浏览器矩阵要求离线可用。
// ================================================================

import 'package:shared_preferences/shared_preferences.dart';

import 'progress_store.dart';

/// 基于 `shared_preferences` 的键值存储。
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore(this._preferences);

  final SharedPreferences _preferences;

  /// 打开平台存储。任何失败都向上抛，由 `ProgressStore` 捕获并降级。
  static Future<SharedPreferencesStore> open() async =>
      SharedPreferencesStore(await SharedPreferences.getInstance());

  /// 打开一个在失败时退化为内存的存储。
  ///
  /// 存档不可用**不应阻断开局**（架构 §7），因此调用方通常用这个。
  static Future<KeyValueStore> openOrMemory() async {
    try {
      return await open();
    } catch (_) {
      return InMemoryKeyValueStore();
    }
  }

  @override
  Future<String?> read(String key) async => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) async {
    final ok = await _preferences.setString(key, value);
    if (!ok) {
      // 与 ProgressStore 的契约一致：写失败以异常形式暴露，由它记录。
      throw StateError('shared_preferences 写入失败：$key');
    }
  }

  @override
  Future<void> delete(String key) async => _preferences.remove(key);
}
