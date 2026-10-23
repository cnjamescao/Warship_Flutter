// ================================================================
// test/tool/verify_dual_release_test.dart —— DUAL-T-01 / DUAL-T-03
// ================================================================
// **架构位置**：工具层测试。验证 `tool/verify_dual_release.dart` 的判定。
//
// **依据**：
//   * `04_测试计划与验收用例.md` DUAL-T-01（双端构建身份）、
//     DUAL-T-03（双端候选发布**原子性**）；
//   * 双端发布需求 §3.2：「任一端构建、签名/归档、hash、静态托管探测
//     或证据缺失，即**整个 RC 不得标记发布**」。
//
// **为什么要测"反例"**：这个工具的职责是**拦住**不一致的发布。
//   只测"一致时通过"没有意义 —— 它必须在**任一字段不一致**时失败 ✓。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'package:flutter_test/flutter_test.dart';

import '../../tool/verify_dual_release.dart';

/// 一份"合法"的 manifest（测试基线）。
Map<String, Object?> goodManifest({Map<String, Object?> overrides = const {}}) {
  return <String, Object?>{
    'releaseVersion': '2.1.0+210',
    'contentVersion': '2.1.0-neon-flow',
    'gitCommit': 'abc1234',
    'buildUtc': '2026-10-21T10:00:00Z',
    'macosArtifactSha256': 'a' * 64,
    'webArchiveSha256': 'b' * 64,
    'webBaseHref': '/',
    'flutterVersion': '3.47.1',
    'wasmEnabled': true,
    ...overrides,
  };
}

ReleaseCandidate cand(String platform, Map<String, Object?> m) =>
    ReleaseCandidate(platform: platform, manifest: m, artifactPath: '/tmp/x');

void main() {
  test('DUAL-T-01a 两端完全一致时通过', () {
    final r = verifyDualRelease(
      cand('macos', goodManifest()),
      cand('web', goodManifest()),
    );
    expect(r.problems, isEmpty, reason: r.problems.join('\n'));
    expect(r.ok, isTrue);
  });

  test('DUAL-T-01b 三项身份**任一**不同即失败（原子性）', () {
    for (final f in <String>[
      'releaseVersion',
      'contentVersion',
      'gitCommit',
    ]) {
      final r = verifyDualRelease(
        cand('macos', goodManifest()),
        cand('web', goodManifest(overrides: {f: 'DIFFERENT'})),
      );
      expect(r.ok, isFalse, reason: '$f 不一致必须失败');
      expect(
        r.problems.any((p) => p.contains(f)),
        isTrue,
        reason: '失败信息必须**指名**是哪个字段不一致',
      );
    }
  });

  test('DUAL-T-01c buildUtc 允许不同（两端构建时间天然不同）', () {
    final r = verifyDualRelease(
      cand('macos', goodManifest(overrides: {'buildUtc': 'A'})),
      cand('web', goodManifest(overrides: {'buildUtc': 'B'})),
    );
    expect(r.ok, isTrue, reason: 'buildUtc 不应参与相等比较');
  });

  test('DUAL-T-01d 缺任一必需字段即失败，且指出字段名', () {
    for (final f in kRequiredManifestFields) {
      final m = goodManifest()..remove(f);
      final r = verifyDualRelease(cand('macos', m), cand('web', goodManifest()));
      expect(r.ok, isFalse, reason: '缺少 $f 必须失败');
      expect(r.problems.any((p) => p.contains(f)), isTrue);
    }
  });

  test('DUAL-T-01e SHA-256 必须是 64 位小写十六进制（不认"看起来像"）', () {
    for (final bad in <String>['', 'abc', 'A' * 64, 'g' * 64]) {
      final r = verifyDualRelease(
        cand('macos', goodManifest(overrides: {'macosArtifactSha256': bad})),
        cand('web', goodManifest()),
      );
      expect(r.ok, isFalse, reason: '非法 SHA "$bad" 必须被拒');
    }
  });

  test('DUAL-T-01g **全零 SHA** 必须被拒（这是"没算"的占位符）', () {
    // 实测抓到过：两端 manifest 里"对方那一半"是 64 个 0 ✗ ——
    // 格式合法（64 位十六进制），但内容根本不存在 ✓。
    // DUAL-T-01 要求"两个 SHA-256 **完整**"，因此必须挡 0 ✓。
    final r = verifyDualRelease(
      cand('macos', goodManifest(overrides: {
        'webArchiveSha256': '0' * 64,
      })),
      cand('web', goodManifest(overrides: {
        'macosArtifactSha256': '0' * 64,
      })),
    );
    expect(r.ok, isFalse, reason: '全零 SHA 必须被拒');
    expect(
      r.problems.where((p) => p.contains('全为 0')).length,
      2,
      reason: '两端都要各自报告（一次列出全部问题）',
    );
  });

  test('DUAL-T-01f Web 端 wasmEnabled 必须为 true', () {
    final r = verifyDualRelease(
      cand('macos', goodManifest()),
      cand('web', goodManifest(overrides: {'wasmEnabled': false})),
    );
    expect(r.ok, isFalse);
    expect(r.problems.any((p) => p.contains('wasmEnabled')), isTrue);
  });

  test('DUAL-T-03a webBaseHref 必须以 / 结尾（子路径托管）', () {
    for (final bad in <String>['', '/game', 'game/']) {
      final r = verifyDualRelease(
        cand('macos', goodManifest()),
        cand('web', goodManifest(overrides: {'webBaseHref': bad})),
      );
      if (bad.isEmpty || !bad.endsWith('/')) {
        expect(r.ok, isFalse, reason: 'webBaseHref "$bad" 必须被拒');
      }
    }
    // 合法的子路径形式。
    final ok = verifyDualRelease(
      cand('macos', goodManifest()),
      cand('web', goodManifest(overrides: {'webBaseHref': '/game/'})),
    );
    expect(ok.ok, isTrue, reason: '子路径 "/game/" 应合法');
  });

  test('DUAL-T-03b 多个问题**一次性全部报告**（不是只报第一个）', () {
    final r = verifyDualRelease(
      cand('macos', goodManifest(overrides: {'gitCommit': 'X'})),
      cand('web', goodManifest(overrides: {
        'contentVersion': 'Y',
        'wasmEnabled': false,
        'webBaseHref': 'bad',
      })),
    );
    expect(r.ok, isFalse);
    expect(r.problems.length, greaterThanOrEqualTo(4),
        reason: '应同时报告 4 个问题，便于一次修完');
  });

  test('DUAL-T-03c 必需字段清单与规范 §3.1 **逐字对应**', () {
    expect(kRequiredManifestFields, <String>[
      'releaseVersion',
      'contentVersion',
      'gitCommit',
      'buildUtc',
      'macosArtifactSha256',
      'webArchiveSha256',
      'webBaseHref',
      'flutterVersion',
      'wasmEnabled',
    ]);
  });
}
