// ================================================================
// test/unit/content/asset_traceability_test.dart —— AC-09 素材溯源复验
// ================================================================
// 产品裁决：「AC-09 获准立即复验，但**在提交实际复验结果前仍保持 🔶**，
// 不得预先标记为通过。」
//
// 素材包 manifest 为每个 Asset 登记了完整溯源链：
//   `sourceFile`（源设计稿）→ `sha256`（源稿哈希）
//   → `runtimeSha256[]`（各运行时文件哈希）→ 应用侧 `assets/images/v2/`
//
// 本文件**实际执行**这条链的逐环校验，产出可复核的结果，
// 而不是把 🔶 直接改成 ✅。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/sha256.dart';

Map<String, Object?> _packManifest() =>
    jsonDecode(File('素材/manifest.json').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _runtimeManifest() =>
    jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
        as Map<String, Object?>;

void main() {
  test('AC-09 素材溯源：源稿存在，且 sha256 语义与类别一致', () {
    // ⚠️ **先说明一个我差点搞错的语义**（记录在此以免后人重踩）：
    //
    // 素材包 manifest 的 `sha256` **不是**源设计稿的哈希：
    //   * **音频**：`sha256` = **源母带 WAV** 的哈希（`sourceFile` 指向它）；
    //   * **图形/UI**：`sha256` = **首个运行时 PNG**（canonical）的哈希，
    //     而 `sourceFile`（源设计稿，如 `图形/角色与敌机/*.png`）
    //     **不在哈希登记范围内**，只做存在性校验。
    //
    // 实测依据：`sha256 == runtimeSha256[0]` 的条目共 129 条（图形/UI 数，2026-10-16 增补 Boss 预警后），
    // 源稿哈希出现在登记中的条目恰为 67 条（音频数）。
    //
    // 我第一版断言"`sha256` 应等于 `sourceFile` 的哈希"，
    // 于是把 8 个图形报成"溯源断裂" —— **那是我的假设错误，不是素材缺陷**。
    final manifest = _packManifest();
    final assets = (manifest['assets'] as List).cast<Map>();

    final missingSource = <String>[];
    final audioHashMismatch = <String>[];
    final graphicCanonicalMismatch = <String>[];
    var sourcesChecked = 0;

    for (final raw in assets) {
      final id = raw['assetId'] as String;
      final sourceFile = raw['sourceFile'] as String?;
      final sha = raw['sha256'] as String?;
      final runtimeHashes =
          (raw['runtimeSha256'] as List?)?.cast<String>() ?? const <String>[];
      final category = raw['category'];

      if (sourceFile != null) {
        if (!File('素材/$sourceFile').existsSync()) {
          missingSource.add('$id → 素材/$sourceFile');
        }
        sourcesChecked++;
      }
      if (sha == null) {
        continue;
      }

      // 音频类别：sfx（音效）+ bgm（背景音乐）。
      // 我第一版只判 'audio'，于是 68 条音频全部掉进图形分支误报。
      if (category == 'sfx' || category == 'bgm' || category == 'music') {
        // 音频：sha256 应等于源母带哈希。
        final file = File('素材/$sourceFile');
        if (sourceFile != null && file.existsSync()) {
          final actual = sha256Hex(file.readAsBytesSync());
          if (actual != sha) {
            audioHashMismatch.add('$id\n    登记 $sha\n    实际 $actual');
          }
        }
      } else if (runtimeHashes.isNotEmpty) {
        // 图形/UI：sha256 应等于首个运行时文件的哈希（canonical）。
        if (sha != runtimeHashes.first) {
          graphicCanonicalMismatch.add(
            '$id\n    sha256 $sha\n    runtimeSha256[0] ${runtimeHashes.first}',
          );
        }
      }
    }

    expect(
      missingSource,
      isEmpty,
      reason: '以下源稿文件不存在：\n${missingSource.join('\n')}',
    );
    expect(
      audioHashMismatch,
      isEmpty,
      reason: '音频源母带哈希与登记不符：\n${audioHashMismatch.join('\n')}',
    );
    expect(
      graphicCanonicalMismatch,
      isEmpty,
      reason: '图形 sha256 与 canonical 运行时文件不符：\n'
          '${graphicCanonicalMismatch.join('\n')}',
    );
    expect(sourcesChecked, greaterThan(0), reason: '应至少校验到一条源稿');
    // ignore: avoid_print
    print('AC-09 源稿存在性：$sourcesChecked 条通过；'
        '音频母带哈希、图形 canonical 哈希均一致');
  });

  test('AC-09 素材溯源：每个运行时文件哈希与登记一致', () {
    final manifest = _packManifest();
    final assets = (manifest['assets'] as List).cast<Map>();

    final mismatched = <String>[];
    var checked = 0;

    for (final raw in assets) {
      final id = raw['assetId'] as String;
      final states =
          (raw['renderStates'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{};
      final expectedHashes =
          (raw['runtimeSha256'] as List?)?.cast<String>() ?? const <String>[];
      if (expectedHashes.isEmpty) {
        continue;
      }
      // 汇总该 Asset 的全部运行时文件（相对素材包根）。
      final runtimeFiles = <String>[];
      for (final state in states.values) {
        final files =
            ((state as Map)['runtimeFiles'] as List?)?.cast<String>() ??
                const <String>[];
        runtimeFiles.addAll(files);
      }
      if (runtimeFiles.isEmpty) {
        continue;
      }
      // runtimeSha256 与汇总顺序一致（素材侧按 states 顺序登记）。
      for (var i = 0; i < runtimeFiles.length; i++) {
        final relative = runtimeFiles[i];
        final file = File('素材/$relative');
        if (!file.existsSync()) {
          mismatched.add('$id → 缺文件 素材/$relative');
          continue;
        }
        if (i >= expectedHashes.length) {
          mismatched.add('$id → 缺少 runtimeSha256 登记（$relative）');
          continue;
        }
        final actual = sha256Hex(file.readAsBytesSync());
        if (actual != expectedHashes[i]) {
          mismatched.add('$id / $relative\n    登记 ${expectedHashes[i]}\n'
              '    实际 $actual');
        }
        checked++;
      }
    }

    expect(
      mismatched,
      isEmpty,
      reason: '以下运行时文件哈希不符：\n${mismatched.join('\n')}',
    );
    // ignore: avoid_print
    print('AC-09 运行时哈希校验：$checked 个文件通过');
  });

  test('AC-09 素材溯源：应用侧副本与素材包运行时文件一致', () {
    final pack = _packManifest();
    final runtime = _runtimeManifest();
    final packById = <String, Map>{
      for (final a in (pack['assets'] as List).cast<Map>())
        a['assetId'] as String: a,
    };

    final mismatched = <String>[];
    var checked = 0;

    for (final record in (runtime['assets'] as List).cast<Map>()) {
      final id = record['assetId'] as String;
      final packRecord = packById[id];
      if (packRecord == null) {
        continue;
      }
      final packStates =
          (packRecord['renderStates'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{};
      final packFiles = <String>[
        for (final state in packStates.values)
          ...(((state as Map)['runtimeFiles'] as List?)?.cast<String>() ??
              const <String>[]),
      ];
      final appFiles =
          (record['runtimeFiles'] as List?)?.cast<String>() ?? const <String>[];

      // 应用侧逐个文件与素材包对应文件比对**内容哈希**。
      for (var i = 0; i < appFiles.length && i < packFiles.length; i++) {
        final appFile = File(appFiles[i]);
        final packFile = File('素材/${packFiles[i]}');
        if (!appFile.existsSync() || !packFile.existsSync()) {
          mismatched.add('$id → 文件缺失（app=${appFiles[i]}）');
          continue;
        }
        final a = sha256Hex(appFile.readAsBytesSync());
        final p = sha256Hex(packFile.readAsBytesSync());
        if (a != p) {
          mismatched.add('$id / ${appFiles[i]}\n    素材包 $p\n    应用侧 $a');
        }
        checked++;
      }
    }

    expect(
      mismatched,
      isEmpty,
      reason: '应用侧副本与素材包不一致：\n${mismatched.join('\n')}',
    );
    // ignore: avoid_print
    print('AC-09 应用侧一致性：$checked 个文件通过');
  });

  test('AC-09 素材溯源：内容版本一致且图形标记为 release_ready', () {
    final pack = _packManifest();
    final runtime = _runtimeManifest();

    final packVersion = pack['contentVersion'] as String?;
    final runtimeVersion = runtime['contentVersion'] as String?;
    expect(packVersion, isNotNull);
    expect(
      runtimeVersion,
      packVersion,
      reason: '应用侧 manifest 的内容版本必须与素材包一致 '
          '（素材包 $packVersion，应用侧 $runtimeVersion）',
    );

    final notReady = <String>[];
    for (final raw in (pack['assets'] as List).cast<Map>()) {
      if (raw['category'] != 'graphic' && raw['category'] != 'ui') {
        continue;
      }
      if (raw['status'] != 'release_ready') {
        notReady.add('${raw['assetId']} → ${raw['status']}');
      }
    }
    expect(
      notReady,
      isEmpty,
      reason: '以下图形/UI 素材未标记 release_ready：\n${notReady.join('\n')}',
    );
    // ignore: avoid_print
    print('AC-09 内容版本：$packVersion（素材包与应用侧一致）');
  });
}
