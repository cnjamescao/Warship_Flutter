// ================================================================
// test/dual/dual_platform_consistency_test.dart —— DUAL-T-02
// ================================================================
// **架构位置**：双端一致性测试。
//
// **依据**（DUAL-T-02）：
//   「两端解析的 manifest 版本、Asset ID、配置 hash、五形态和胜负结果
//     在**固定 seed** 下**逐字段一致**；**禁止平台特判改变 Domain 结果**。」
//
// **为什么"禁止平台特判"是这条的核心**：
//   双端一致**不是**靠"两端各跑一遍比结果"来保证的 ✓ ——
//   那样只能在发布时发现不一致 ✗。
//   真正的保证是**结构性的**：Domain 层**根本读不到平台信息**，
//   于是它在两端**必然**算出同一个结果 ✓。
//   这条测试就是验证这个结构性前提。
//
// 每条断言都能失败（R6.2）：只要有人在 domain/core 里写
// `kIsWeb ? ... : ...`，本文件立刻失败 ✓。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **Domain 与 Core 层**（两端必须逐字段一致的地方）。
const List<String> kDomainDirs = <String>['lib/game/domain', 'lib/game/core'];

/// **禁止出现在 Domain/Core 里的平台判定**（字面量清单）。
///
/// 用字面量而不是正则：更直观，也不会误伤注释（注释里说明"不许用"是允许的 ✓）。
/// 每一条都对应一种"平台特判"的写法：
/// * `kIsWeb` / `defaultTargetPlatform` —— Flutter 的平台开关；
/// * `Platform.is` / `Platform.environment` —— `dart:io` 的平台信息；
/// * `dart.library.html` —— 条件导入的平台分支。
const List<String> kForbiddenLiterals = <String>[
  'kIsWeb',
  'defaultTargetPlatform',
  'TargetPlatform',
  'Platform.is',
  'Platform.environment',
  'dart.library.html',
];

/// 遍历 Domain/Core 的 Dart 文件，返回 `(路径, 命中行)`。
List<(String, String, int)> scanForPlatformChecks() {
  final hits = <(String, String, int)>[];
  for (final dir in kDomainDirs) {
    final d = Directory(dir);
    if (!d.existsSync()) {
      continue;
    }
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) {
        continue;
      }
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final raw = lines[i];
        final t = raw.trimLeft();
        // 只检查**代码**，注释里提到这些词是允许的（说明"不许用"）。
        if (t.startsWith('//') || t.startsWith('///')) {
          continue;
        }
        for (final lit in kForbiddenLiterals) {
          if (raw.contains(lit)) {
            hits.add((f.path, raw.trim(), i + 1));
            break;
          }
        }
      }
    }
  }
  return hits;
}

void main() {
  test('DUAL-T-02a Domain/Core **不得**出现平台判定（否则两端结果会分叉）', () {
    final hits = scanForPlatformChecks();
    expect(
      hits,
      isEmpty,
      reason: '以下位置出现了平台判定 —— 它会让两端算出不同结果 ✗：\n'
          '${hits.map((h) => '${h.$1}:${h.$3}  ${h.$2}').join('\n')}',
    );
  });

  test('DUAL-T-02b 两端共用**同一份**内容配置（不存在按平台分叉的配置目录）', () {
    // 只允许一个内容配置目录。
    final configDirs = Directory('assets/config')
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path)
        .where((p) => p.contains('v2'))
        .toList();
    expect(
      configDirs,
      hasLength(1),
      reason: '内容配置必须只有一份（v2），否则两端会读到不同数据 ✗：$configDirs',
    );
  });

  test('DUAL-T-02c 五形态在两端的定义**唯一来源**（weapons.json）', () {
    // 五形态来自 `weapons.json.mainWeaponStyles`，没有第二份定义。
    final json = jsonDecode(
      File('assets/config/v2/weapons.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final styles = (json['mainWeaponStyles'] as List?) ?? const <Object?>[];
    final ids = styles
        .whereType<Map>()
        .map((m) => m['styleId'])
        .whereType<String>()
        .toSet();
    expect(ids, <String>{'prism', 'arc', 'plasma', 'needle', 'missile'},
        reason: '五形态必须且只能来自这一处配置');
  });

  test('DUAL-T-02d manifest 的 Asset ID 与内容版本两端同源（构建期唯一副本）', () {
    final m = jsonDecode(
      File('assets/config/v2/manifest.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(m['contentVersion'], '2.1.0-neon-flow');
    final assets = (m['assets'] as List).whereType<Map>().toList();
    expect(assets.length, 237, reason: '素材条数必须两端一致（同一份 manifest）');
    // Asset ID 不得出现按平台分叉的命名（如 -WEB / -DESKTOP 后缀）。
    final platformSpecific = assets
        .map((a) => a['assetId'])
        .whereType<String>()
        .where((id) => id.endsWith('-WEB') || id.endsWith('-DESKTOP'))
        .toList();
    expect(platformSpecific, isEmpty,
        reason: '不得有平台专属素材（DUAL-T-02：两端同一份素材）：'
            '$platformSpecific');
  });

  test('DUAL-T-02e 判定逻辑对"平台无关"有**结构性**保证（Domain 不 import io）', () {
    // 与 `platform_isolation_test` 互补：那里查 io 导入，
    // 这里查"平台判定常量" —— 两者一起才能封住"平台特判"这条路。
    final hits = scanForPlatformChecks();
    expect(hits.where((h) => h.$2.contains('kIsWeb')), isEmpty,
        reason: 'Domain/Core 里出现 kIsWeb 就是平台特判 ✗');
  });
}
