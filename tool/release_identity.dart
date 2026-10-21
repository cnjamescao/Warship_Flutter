// ================================================================
// tool/release_identity.dart —— 发布身份唯一入口（版本/内容版本/commit）
//
// **架构位置**：工具层（发布身份）。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**（负责人批复 2026-10-21 原文）：
//   「`releaseVersion` 的唯一来源就是 `pubspec.yaml`；W0 的 `ReleaseIdentity`
//     工具负责读取它、内容版本与 commit，**禁止人工在代码或 CI 中
//     再写一份版本号**。」
//
// 因此本文件是全工程**唯一**知道"怎么读版本"的地方：
//   * `tool/build_release_manifest.dart` 复用这里的读取函数，
//     **不再自带一份实现**（否则就是"第二个来源"✗）；
//   * 任何需要版本号的工具/CI 都应 import 本文件。
//
// **设计取舍**：放在 `tool/` 而不是 `lib/`，因为它需要 `dart:io` 读文件
// 与起 `git` 进程 —— 而 W1 的目标正是"**共享表现层不得直接 import
// `dart:io`**"。发布身份属构建期，不进游戏运行时 ✓。
// ================================================================

import 'dart:convert';
import 'dart:io';

/// **发布身份**：一次候选发布不可变的三个标识。
///
/// 字段与双端发布需求 §3.1 的三项身份一一对应
/// （`releaseVersion` / `contentVersion` / `gitCommit`）。
class ReleaseIdentity {
  const ReleaseIdentity({
    required this.releaseVersion,
    required this.contentVersion,
    required this.gitCommit,
  });

  /// `pubspec.yaml` 的 `version:`（形如 `2.1.0+210`）。
  ///
  /// ⚠️ **唯一来源** —— 代码、CI、脚本里都不许再写一份 ✗。
  final String releaseVersion;

  /// 内容版本（来自 `assets/config/v2/*.json`，全部必须一致）。
  final String contentVersion;

  /// `git rev-parse HEAD`（40 位十六进制）。
  final String gitCommit;

  /// 短 commit（日志/归档用，只取前 7 位）。
  String get shortCommit =>
      gitCommit.length >= 7 ? gitCommit.substring(0, 7) : gitCommit;

  @override
  String toString() =>
      'ReleaseIdentity($releaseVersion · $contentVersion · $shortCommit)';

  /// **读取当前工作树的发布身份**（唯一入口）。
  ///
  /// 任何一项读不到就**抛错** —— 发布不能建立在"猜的版本号"上 ✗。
  static ReleaseIdentity read({
    String pubspecPath = 'pubspec.yaml',
    String configDir = 'assets/config/v2',
  }) {
    return ReleaseIdentity(
      releaseVersion: readPubspecVersion(pubspecPath),
      contentVersion: readContentVersion(configDir),
      gitCommit: readGitCommit(),
    );
  }
}

/// 从 `pubspec.yaml` 取 `version:`。
String readPubspecVersion(String pubspecPath) {
  final f = File(pubspecPath);
  if (!f.existsSync()) {
    throw StateError('找不到 $pubspecPath —— 版本号唯一来源缺失');
  }
  for (final line in f.readAsLinesSync()) {
    final t = line.trim();
    if (t.startsWith('version:')) {
      return t.substring('version:'.length).trim();
    }
  }
  throw StateError('$pubspecPath 里没有 version: 字段');
}

/// 从内容配置取 `contentVersion`，并**要求全部配置文件一致**。
///
/// 为什么要求一致：若 `player.json` 是 2.1、`weapons.json` 是 2.0，
/// 游戏会加载出**半新半旧**的内容 —— 而这种错误不会在启动时报错 ✗。
String readContentVersion(String configDir) {
  final dir = Directory(configDir);
  if (!dir.existsSync()) {
    throw StateError('找不到内容配置目录 $configDir');
  }
  final versions = <String, String>{}; // version → 第一个出现它的文件
  for (final f in dir.listSync().whereType<File>().toList()..sort(
    (a, b) => a.path.compareTo(b.path),
  )) {
    if (!f.path.endsWith('.json')) {
      continue;
    }
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is Map && decoded['contentVersion'] is String) {
      versions.putIfAbsent(decoded['contentVersion'] as String, () => f.path);
    }
  }
  if (versions.isEmpty) {
    throw StateError('$configDir 下没有任何 contentVersion 字段');
  }
  if (versions.length > 1) {
    throw StateError(
      '配置文件 contentVersion 不一致：'
      '${versions.entries.map((e) => "${e.key} @ ${e.value}").join(" / ")}',
    );
  }
  return versions.keys.single;
}

/// `git rev-parse HEAD`（发布必须能追溯到 commit）。
String readGitCommit() {
  final r = Process.runSync('git', <String>['rev-parse', 'HEAD']);
  if (r.exitCode != 0) {
    throw StateError('无法获取 git commit: ${r.stderr}');
  }
  final out = (r.stdout as String).trim();
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(out)) {
    throw StateError('git commit 格式异常："$out"');
  }
  return out;
}

void main() {
  final id = ReleaseIdentity.read();
  stdout.writeln('releaseVersion : ${id.releaseVersion}');
  stdout.writeln('contentVersion : ${id.contentVersion}');
  stdout.writeln('gitCommit      : ${id.gitCommit}');
}

