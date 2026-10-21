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

// 唯一来源：版本/内容版本/commit 的读取全部来自这里。
// 本文件不再自带任何读取实现（否则就是第二份版本号）。
import 'release_identity.dart';

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

  // W0 身份入口：唯一来源，此处不得再写一份读取逻辑。
  final id = ReleaseIdentity.read();
  final commit = id.gitCommit;
  final releaseVersion = id.releaseVersion;
  final contentVersion = id.contentVersion;
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
  stdout.writeln('   $id');
}

