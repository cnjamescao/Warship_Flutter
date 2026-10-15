// ================================================================
// test/unit/presentation/copy_guard_test.dart —— T-COPY-01（F-01）
// ================================================================
// 技术协议 §2「文本与参数」：
//   「所有玩家可见文本（Widget 文本、HUD 标签、按钮、提示、结算、
//     卡牌标题/描述和 `Semantics` 标签）**只能通过
//     `catalog.text(key, params)` 取得**。`strings_zh_CN.json` 是唯一
//     正文来源；缺失 key、参数缺失或多余参数必须在 debug/测试失败…
//     **对 `lib/` 的静态检查必须排除上述非 UI 目录后拒绝新的玩家可见
//     字符串字面量。**」
//
// 这是**唯一能防止 F-01 回潮的机制**：人总会顺手写一句中文，
// 而那样测试全会绿。因此把"不许写"变成一条会红的测试。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 扫描范围：玩家可见文本只可能出现在这些目录。
const List<String> kScannedDirs = <String>['lib/app', 'lib/game/presentation'];

/// 白名单：日志、调试与断言信息（规范明确不受本条限制）。
final List<RegExp> kWhitelist = <RegExp>[
  RegExp(r'\bdebugPrint\s*\('),
  RegExp(r'\bprint\s*\('),
  // 标准输出/错误流也属日志（规范：「日志…不受本条限制」）。
  RegExp(r'\bstdout\.writeln\s*\('),
  RegExp(r'\bstderr\.writeln\s*\('),
  RegExp(r'\bassert\s*\('),
  RegExp(r'\bStateError\s*\('),
  RegExp(r'^\s*//'), // 注释行
  RegExp(r'^\s*///'),
  // 错误对象的 `toString()`（用于日志，不是玩家可见文本）。
  RegExp(r'String\s+toString\s*\(\s*\)'),
];

/// 含中日韩字符的字符串字面量。
final RegExp kCjkLiteral = RegExp(r"'[^'\n]*[\u4e00-\u9fff][^'\n]*'");

void main() {
  test('T-COPY-01 玩家可见代码里不得出现硬编码中文字面量', () {
    final offenders = <String>[];

    for (final dir in kScannedDirs) {
      final directory = Directory(dir);
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        // 日志/断言常常**跨多行**（`writeln(` 后若干续行）。
        // 只看单行会把这些续行误判成"玩家可见文本" —— 这是我第一版
        // 守卫的真实缺陷。因此按**括号深度**跳过整段调用。
        var skipUntilDepthZero = false;
        var depth = 0;

        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];

          if (skipUntilDepthZero) {
            depth += _delta(line);
            if (depth <= 0) {
              skipUntilDepthZero = false;
              depth = 0;
            }
            continue;
          }

          // ⚠️ **先查白名单、再查中文** —— 顺序不能反：
          // `stderr.writeln(` 这一行**本身没有中文**，若先按"无中文"跳过，
          // 就永远不会进入跨行跳过模式，它的中文续行仍会被误报。
          if (kWhitelist.any((re) => re.hasMatch(line))) {
            final d = _delta(line);
            if (d > 0) {
              skipUntilDepthZero = true;
              depth = d;
            }
            continue;
          }
          if (!kCjkLiteral.hasMatch(line)) continue;
          offenders.add('${entity.path}:${i + 1}  ${line.trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'F-01：玩家可见文本必须走 catalog.text(key, params)，'
          '文本只能存在于 strings_zh_CN.json。\n'
          '若某行属于日志/断言/调试输出，请把它并入白名单（需说明理由）。\n'
          '发现 ${offenders.length} 处：\n${offenders.join('\n')}',
    );
  });

  test('T-COPY-01 所有已使用的文案 key 在 strings_zh_CN.json 中且参数匹配', () {
    // 扫描代码里出现的 `text('...')` / `text("...")` 调用，逐个校验。
    // 允许显式的类型实参（`<String, Object?>{...}`），
    // 否则参数块匹配不上，会把**本来正确**的调用报成"参数缺失"。
    final keyPattern = RegExp(
      r'''\.text\(\s*'([^']+)'(?:\s*,\s*(?:<[^>]*>)?\s*\{([^}]*)\})?''',
    );
    final strings = _loadStrings();
    final problems = <String>[];

    for (final dir in kScannedDirs) {
      final directory = Directory(dir);
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final src = entity.readAsStringSync();
        for (final m in keyPattern.allMatches(src)) {
          final key = m.group(1)!;
          // 插值 key（如 `result.tier.$tier`）无法静态校验，跳过。
          if (key.contains(r'$')) continue;
          final template = strings[key];
          if (template == null) {
            problems.add('${entity.path}: 使用了不存在的 key "$key"');
            continue;
          }
          // 校验模板里的占位符与调用处传入的命名参数一致。
          final declared = RegExp(r'\{(\w+)\}')
              .allMatches(template)
              .map((e) => e.group(1)!)
              .toSet();
          final passed = (m.group(2) ?? '')
              .split(',')
              .map((s) => s.split(':').first.trim().replaceAll("'", '').replaceAll('"', ''))
              .where((s) => s.isNotEmpty)
              .toSet();
          // ⚠️ Dart 的 Set 默认是**身份相等**：空集 != 空集 为真。
          // 我第一版直接用 `declared != passed`，导致**每个 key 都被报成
          // 参数不匹配**（包括本来正确的）。必须做集合比较。
          if (!_sameSet(declared, passed)) {
            problems.add(
              '${entity.path}: key "$key" 参数不匹配 —— '
              '模板需要 $declared，调用传入 $passed',
            );
          }
        }
      }
    }

    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}

/// 本行的净括号增量（用于跨行日志调用的跳过）。
int _delta(String line) {
  var d = 0;
  for (final ch in line.split('')) {
    if (ch == '(') d++;
    if (ch == ')') d--;
  }
  return d;
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

Map<String, String> _loadStrings() {
  final file = File('assets/config/v2/strings_zh_CN.json');
  final src = file.readAsStringSync();
  // 不引第三方 JSON 依赖：用最小的提取（键与值都是字符串）。
  final map = <String, String>{};
  final re = RegExp(r'"([^"]+)"\s*:\s*"((?:[^"\\]|\\.)*)"');
  final start = src.indexOf('"strings"');
  for (final m in re.allMatches(src.substring(start))) {
    map[m.group(1)!] = m.group(2)!;
  }
  return map;
}
