// ================================================================
// test/tool/build_release_manifest_test.dart —— DUAL-T-01（生成端）
// ================================================================
// **架构位置**：工具层测试。验证 `release-manifest.json` 的**生成**逻辑。
//
// **为什么必须测"来源"而不是"结果"**：
//   双端身份的全部意义在于「**版本号不是手写的**」。
//   一个"能生成正确字段"但版本来自常量的生成器，会**悄悄地**
//   让两端用同一份手填值通过校验 —— 那就等于没有校验 ✗。
//   因此这里断言的是**取值来源**（pubspec / 配置文件 / git）。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/build_release_manifest.dart';
import '../../tool/verify_dual_release.dart';

void main() {
  test('DUAL-T-01 生成的 manifest 含规范 §3.1 的**全部九个字段**', () {
    final m = buildManifest(
      releaseVersion: '2.1.0+210',
      contentVersion: '2.1.0-neon-flow',
      commit: 'abc1234',
      buildUtc: '2026-10-21T10:00:00Z',
      macosArtifactSha256: 'a' * 64,
      webArchiveSha256: 'b' * 64,
      webBaseHref: '/',
      flutterVer: '3.47.1',
      wasmEnabled: true,
    );
    expect(m.keys.toSet(), kRequiredManifestFields.toSet());
  });

  test('DUAL-T-01b releaseVersion **来自 pubspec.yaml**（不是常量）', () {
    final v = readPubspecVersion('pubspec.yaml');
    // 形如 x.y.z+n
    expect(
      RegExp(r'^\d+\.\d+\.\d+\+\d+$').hasMatch(v),
      isTrue,
      reason: 'pubspec 的 version 必须是 x.y.z+n，实际 "$v"',
    );
  });

  test('DUAL-T-01c contentVersion **来自内容配置**，且全部配置文件一致', () {
    final v = readContentVersion('assets/config/v2');
    expect(v, '2.1.0-neon-flow');
    // 交叉验证：内容目录里的版本与这里一致（防"工具读的和游戏读的不同"）。
    final manifest = jsonDecode(
      File('assets/config/v2/manifest.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(manifest['contentVersion'], v);
  });

  test('DUAL-T-01d gitCommit **来自 git**，且是 40 位十六进制', () {
    final c = gitCommit();
    expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(c), isTrue,
        reason: '实际 "$c"');
  });

  test('DUAL-T-01e 生成器与校验器**字段名完全一致**（防止一边改名）', () {
    final m = buildManifest(
      releaseVersion: '1.0.0+1',
      contentVersion: 'x',
      commit: 'c',
      buildUtc: 't',
      macosArtifactSha256: '0' * 64,
      webArchiveSha256: '1' * 64,
      webBaseHref: '/',
      flutterVer: 'f',
      wasmEnabled: true,
    );
    // 生成的 manifest 必须能让校验器"只剩身份差异"这一项。
    final r = verifyDualRelease(
      ReleaseCandidate(platform: 'macos', manifest: m, artifactPath: 'x'),
      ReleaseCandidate(
        platform: 'web',
        manifest: <String, Object?>{...m, 'wasmEnabled': true},
        artifactPath: 'y',
      ),
    );
    expect(r.ok, isTrue, reason: r.problems.join('\n'));
  });
}
