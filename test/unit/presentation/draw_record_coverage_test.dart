// ================================================================
// test/unit/presentation/draw_record_coverage_test.dart —— 绘制记录覆盖度守卫
// ================================================================
// **存在理由**：本项目用 `BattlefieldComponent.drawnAssetMaxRadius`
// 作为"某个正式素材**确实被绘制了**"的证据（F-40 的 Golden 断言依赖它）。
//
// 但该记录**只在 `_drawSpriteOrNull` 里写入** —— 任何**绕过它直接绘制**
// 的路径都会成为**仪表盲区**：素材明明画了，记录里却没有，
// 于是断言会误报"未被绘制"。
//
// 我为这个盲区**踩了三次**（两次是线形预警 `_drawLineTelegraph`），
// 因此加一条静态守卫，从根上防止第四次。
//
// 规则：`warship_v2_game.dart` 里**每一处** `drawImageRect(` 调用点，
// 其所属方法必须满足二者之一：
//   1. 是 `_drawSpriteOrNull`（记录的唯一公共入口）；或
//   2. 方法体内显式写入了 `drawnAssetMaxRadius[`（自行登记）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('绘制记录覆盖度：每个 drawImageRect 入口都必须登记到 drawnAssetMaxRadius', () {
    final lines = File(
      'lib/game/presentation/warship_v2_game.dart',
    ).readAsLinesSync();

    /// 找到 `index` 行所属的方法签名（向上找最近的缩进两空格的签名行）。
    String enclosingMethod(int index) {
      for (var i = index; i >= 0; i--) {
        final line = lines[i];
        if (RegExp(r'^  [A-Za-z_][A-Za-z0-9_<>?, ]*\s+_?[A-Za-z0-9_]+\(')
            .hasMatch(line)) {
          return line.trim();
        }
      }
      return '(未知)';
    }

    /// 方法的完整方法体（从签名到下一个同缩进签名）。
    String methodBody(String signature) {
      final start = lines.indexWhere((l) => l.trim() == signature);
      if (start < 0) {
        return '';
      }
      final buffer = <String>[];
      for (var i = start; i < lines.length; i++) {
        if (i > start &&
            RegExp(r'^  [A-Za-z_][A-Za-z0-9_<>?, ]*\s+_?[A-Za-z0-9_]+\(')
                .hasMatch(lines[i])) {
          break;
        }
        buffer.add(lines[i]);
      }
      return buffer.join('\n');
    }

    final offenders = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].contains('drawImageRect(')) {
        continue;
      }
      final method = enclosingMethod(i);
      final isRecorderEntry = method.contains('_drawSpriteOrNull(');
      final selfRecords = methodBody(method).contains('drawnAssetMaxRadius[');
      if (!isRecorderEntry && !selfRecords) {
        offenders.add('第 ${i + 1} 行，所属方法：$method');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '以下 `drawImageRect` 调用点**绕过了绘制记录** —— '
          '素材会被画出来，但 `drawnAssetMaxRadius` 里查不到，'
          '导致"素材确实被绘制"类断言误报（我为这个盲区踩过三次）：\n'
          '${offenders.join("\n")}\n\n'
          '修法：在该方法内显式写入 '
          '`drawnAssetMaxRadius[assetId] = <绘制半径>;`，'
          '或改为经由 `_drawSpriteOrNull` 绘制。',
    );
  });
}
