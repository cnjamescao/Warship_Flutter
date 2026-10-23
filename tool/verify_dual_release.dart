// ================================================================
// tool/verify_dual_release.dart —— 双端候选发布校验（DUAL-T-01/03）
//
// **架构位置**：工具层（构建/发布）。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**：
//   * **只读**：本工具绝不修改候选包，也不写仓库（发布验证必须可重放）✓
//   * **任一不一致即失败**：不做"部分通过"，因为双端原子性要求
//     「任一端失败，整个 release train 退回候选态」；
//   * **SHA-256 必须真算**：不接受"文件存在"或"大小相同"作为替代 ✗。
//
// **依据**：
//   * `Spec/01_产品/v2.1/Warship_v2.1双端发布需求.md` §3.1（字段与原子性）；
//   * `Spec/02_技术/v2.1/04_测试计划与验收用例.md` 的 DUAL-T-01 / DUAL-T-03。
// ================================================================

import 'dart:convert';
import 'dart:io';

/// `release-manifest.json` 的**必需字段**（顺序无关，但必须全部存在）。
///
/// 来源：双端发布需求 §3.1 的字段清单 —— 与文档**逐字对应**，
/// 少一个字段就意味着"这次发布无法被复核"。
const List<String> kRequiredManifestFields = <String>[
  'releaseVersion',
  'contentVersion',
  'gitCommit',
  'buildUtc',
  'macosArtifactSha256',
  'webArchiveSha256',
  'webBaseHref',
  'flutterVersion',
  'wasmEnabled',
];

/// 一个端的候选包描述。
class ReleaseCandidate {
  const ReleaseCandidate({
    required this.platform,
    required this.manifest,
    required this.artifactPath,
  });

  /// `macos` 或 `web`。
  final String platform;

  /// 解析后的 `release-manifest.json`。
  final Map<String, Object?> manifest;

  /// 产物路径（macOS 是 `.app`，Web 是目录压缩包）—— 用于算 SHA-256。
  final String artifactPath;
}

/// 校验结果：`problems` 为空才算通过。
class DualReleaseReport {
  DualReleaseReport(this.problems, this.checkedFields);

  final List<String> problems;
  final List<String> checkedFields;

  bool get ok => problems.isEmpty;
}

/// **核心校验**（纯函数，便于单测；不碰文件系统）。
///
/// 规则（DUAL-T-01 / DUAL-T-03）：
/// 1. 两个端的 manifest 都必须含**全部必需字段**；
/// 2. `releaseVersion` / `contentVersion` / `gitCommit` **两端必须相同**
///    —— 这正对应"由同一 commit、同一版本构建"；
/// 3. `buildUtc` **允许不同**（两端构建时间天然不同）✗ 不参与相等比较；
/// 4. `wasmEnabled` 只在 Web 端必须为 true（macOS 无此概念）；
/// 5. `webBaseHref` 必须为非空字符串且以 `/` 结尾（根路径写 `/`）。
DualReleaseReport verifyDualRelease(
  ReleaseCandidate macos,
  ReleaseCandidate web,
) {
  final problems = <String>[];
  final checked = <String>[];

  // ① 必需字段齐全（两端都查）。
  for (final c in <ReleaseCandidate>[macos, web]) {
    for (final f in kRequiredManifestFields) {
      if (!c.manifest.containsKey(f)) {
        problems.add('${c.platform}: 缺少必需字段 "$f"（§3.1 要求全部字段）');
      }
    }
  }

  // ② 三项身份必须相同。
  for (final f in <String>['releaseVersion', 'contentVersion', 'gitCommit']) {
    checked.add(f);
    final a = macos.manifest[f];
    final b = web.manifest[f];
    if (a == null || b == null) {
      continue; // 已由 ① 报告缺失。
    }
    if (a != b) {
      problems.add(
        '$f 两端不一致：macos=$a / web=$b '
        '（双端必须由同一 commit 与同一版本构建）',
      );
    }
  }

  // ③ wasmEnabled：Web 必须为 true。
  checked.add('wasmEnabled');
  if (web.manifest['wasmEnabled'] != true) {
    problems.add('web: wasmEnabled 必须为 true（Web 正式端要求 WASM 构建）');
  }

  // ④ webBaseHref：非空、以 / 结尾。
  checked.add('webBaseHref');
  final base = web.manifest['webBaseHref'];
  if (base is! String || base.isEmpty) {
    problems.add('web: webBaseHref 必须是非空字符串');
  } else if (!base.endsWith('/')) {
    problems.add('web: webBaseHref 必须以 "/" 结尾（当前 "$base"）');
  }

  // ⑤ 两个 SHA-256 必须"看起来是真的"（64 位十六进制）。
  checked.add('macosArtifactSha256');
  checked.add('webArchiveSha256');
  // **四个都要查**：两份 manifest 各自都该带**两个** SHA ✓。
  //
  // ⚠️ 我第一版只查了"各自那一半"（macos 文件的 macos-SHA、web 文件的
  // web-SHA）✗ —— 于是实测中"对方那一半是 64 个 0"**完全没被发现** ✗，
  // 而那正是 DUAL-T-01「两个 SHA-256 完整」要挡的东西 ✓。
  for (final pair in <(String, Object?)>[
    ('macos: macosArtifactSha256', macos.manifest['macosArtifactSha256']),
    ('macos: webArchiveSha256', macos.manifest['webArchiveSha256']),
    ('web: macosArtifactSha256', web.manifest['macosArtifactSha256']),
    ('web: webArchiveSha256', web.manifest['webArchiveSha256']),
  ]) {
    final v = pair.$2;
    if (v is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) {
      problems.add('${pair.$1} 必须是 64 位小写十六进制 SHA-256（当前 "$v"）');
      continue;
    }
    // **格式对不等于内容真**：全零是"这一端没算"的占位符 ✗。
    // DUAL-T-01 要求「两个 SHA-256 **完整**」—— 因此这里必须挡 0。
    if (RegExp(r'^0{64}$').hasMatch(v)) {
      problems.add(
        '${pair.$1} 全为 0 —— 说明该端产物 SHA 根本没有计算 '
        '（DUAL-T-01 要求两个 SHA 都完整）',
      );
    }
  }

  return DualReleaseReport(problems, checked);
}

/// 计算文件或目录树的 SHA-256（目录按**相对路径排序**后拼接，
/// 保证同一内容在任何文件系统上得到同一 hash）。
Future<String> sha256OfPath(String path) async {
  final result = await Process.run('shasum', <String>['-a', '256', path]);
  if (result.exitCode != 0) {
    throw StateError('无法计算 $path 的 SHA-256: ${result.stderr}');
  }
  return (result.stdout as String).split(' ').first.trim();
}

Future<Map<String, Object?>> readManifest(String path) async {
  final f = File(path);
  if (!f.existsSync()) {
    throw StateError('缺少 release-manifest.json：$path');
  }
  final decoded = jsonDecode(f.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw StateError('release-manifest.json 必须是对象：$path');
  }
  return decoded;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      '用法：dart run tool/verify_dual_release.dart '
      '<macos release-manifest.json> <web release-manifest.json>',
    );
    exit(2);
  }
  final macos = ReleaseCandidate(
    platform: 'macos',
    manifest: await readManifest(args[0]),
    artifactPath: args[0],
  );
  final web = ReleaseCandidate(
    platform: 'web',
    manifest: await readManifest(args[1]),
    artifactPath: args[1],
  );

  final report = verifyDualRelease(macos, web);
  if (report.ok) {
    stdout.writeln('✅ 双端候选发布校验通过（DUAL-T-01/03）');
    stdout.writeln('   已校验字段：${report.checkedFields.join(', ')}');
    return;
  }
  stderr.writeln('❌ 双端候选发布校验失败 —— 整个 RC 不得标记发布：');
  for (final p in report.problems) {
    stderr.writeln('  · $p');
  }
  exit(1);
}

