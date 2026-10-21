// ================================================================
// tool/build_release_manifest.dart —— 生成 release-manifest.json（双端发布身份）
//
// **架构位置**：工具层（构建/发布）。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**：
//   * **不手写版本号**：`releaseVersion` 必须来自 `pubspec.yaml`，
//     `contentVersion` 来自内容配置，`gitCommit` 来自 `git rev-parse`
//     —— 三者任一"手填"都会让双端身份校验失去意义 ✗；
//   * **产物不提交仓库**：manifest 写到候选包根目录（`build/release/`），
//     属构建产物；
//   * 生成的字段与 `verify_dual_release.dart` 的必需字段**一一对应**。
//
// **依据**：`Spec/01_产品/v2.1/Warship_v2.1双端发布需求.md` §3.1。
// ================================================================

import 'dart:convert';
import 'dart:io';

/// 从 `pubspec.yaml` 取 `version:`（形如 `2.1.0+210`）。
String readPubspecVersion(String pubspecPath) {
  final lines = File(pubspecPath).readAsLinesSync();
  for (final line in lines) {
    final t = line.trim();
    if (t.startsWith('version:')) {
      return t.substring('version:'.length).trim();
    }
  }
  throw StateError('$pubspecPath 里没有 version: 字段');
}

/// 从内容配置取 `contentVersion`（唯一来源：`assets/config/v2/*.json`）。
///
/// 代码里只有**一处**版本字面量（`kActiveContentVersion`），但它不可从
/// 工具进程直接 import（Flutter 依赖）。因此这里读**配置本身**，
/// 并用「所有配置文件必须同版本」来防串版本。
String readContentVersion(String configDir) {
  final dir = Directory(configDir);
  final versions = <String>{};
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json')) {
      continue;
    }
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is Map && decoded['contentVersion'] is String) {
      versions.add(decoded['contentVersion'] as String);
    }
  }
  if (versions.isEmpty) {
    throw StateError('$configDir 下没有任何 contentVersion 字段');
  }
  if (versions.length > 1) {
    throw StateError('配置文件 contentVersion 不一致：$versions');
  }
  return versions.single;
}

/// `git rev-parse HEAD`（失败即抛 —— 发布必须能追溯到 commit）。
String gitCommit() {
  final r = Process.runSync('git', <String>['rev-parse', 'HEAD']);
  if (r.exitCode != 0) {
    throw StateError('无法获取 git commit: ${r.stderr}');
  }
  return (r.stdout as String).trim();
}

String flutterVersion() {
  final r = Process.runSync('flutter', <String>['--version']);
  final out = (r.stdout as String);
  final m = RegExp(r'Flutter\s+([0-9.]+)').firstMatch(out);
  return m?.group(1) ?? 'unknown';
}

String sha256OfFile(String path) {
  final r = Process.runSync('shasum', <String>['-a', '256', path]);
  if (r.exitCode != 0) {
    throw StateError('无法计算 $path 的 SHA-256');
  }
  return (r.stdout as String).split(' ').first.trim();
}

/// 生成 manifest（**纯数据**，便于单测）。
Map<String, Object?> buildManifest({
  required String releaseVersion,
  required String contentVersion,
  required String commit,
  required String buildUtc,
  required String macosArtifactSha256,
  required String webArchiveSha256,
  required String webBaseHref,
  required String flutterVer,
  required bool wasmEnabled,
}) => <String, Object?>{
  'releaseVersion': releaseVersion,
  'contentVersion': contentVersion,
  'gitCommit': commit,
  'buildUtc': buildUtc,
  'macosArtifactSha256': macosArtifactSha256,
  'webArchiveSha256': webArchiveSha256,
  'webBaseHref': webBaseHref,
  'flutterVersion': flutterVer,
  'wasmEnabled': wasmEnabled,
};

void main(List<String> args) {
  // 用法：dart run tool/build_release_manifest.dart <平台 macos|web>
  //        <产物路径> [输出目录=build/release] [baseHref=/]
  final platform = args.isNotEmpty ? args[0] : 'macos';
  final artifact = args.length > 1 ? args[1] : '';
  final outDir = args.length > 2 ? args[2] : 'build/release';
  final baseHref = args.length > 3 ? args[3] : '/';

  final commit = gitCommit();
  final releaseVersion = readPubspecVersion('pubspec.yaml');
  final contentVersion = readContentVersion('assets/config/v2');
  final artifactSha =
      artifact.isEmpty ? '0' * 64 : sha256OfFile(artifact);

  final manifest = buildManifest(
    releaseVersion: releaseVersion,
    contentVersion: contentVersion,
    commit: commit,
    buildUtc: DateTime.now().toUtc().toIso8601String(),
    macosArtifactSha256: platform == 'macos' ? artifactSha : '0' * 64,
    webArchiveSha256: platform == 'web' ? artifactSha : '0' * 64,
    webBaseHref: baseHref,
    flutterVer: flutterVersion(),
    wasmEnabled: platform == 'web',
  );

  Directory(outDir).createSync(recursive: true);
  final out = File('$outDir/release-manifest.json');
  out.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(manifest),
  );
  stdout.writeln('✅ 已生成 ${out.path}（platform=$platform）');
  stdout.writeln('   releaseVersion=$releaseVersion · '
      'contentVersion=$contentVersion · commit=${commit.substring(0, 7)}');
}

