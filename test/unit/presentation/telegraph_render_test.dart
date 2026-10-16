// ================================================================
// test/unit/presentation/telegraph_render_test.dart —— F-36 第 3 步
// ================================================================
// 协议 §3.2 对预警渲染的约束：
//   * 「预警与危险区均处于**背景之上、实体之下**」；
//   * 「只允许使用 manifest 绑定的**正式素材**及正式 danger pattern，
//     **不得用 Canvas 几何替代资源**」。
//
// 这两条都是**结构性**要求，用运行时像素难以稳定断言，
// 因此以静态检查守住（与 F-28/F-31 的实体外观守卫同一思路）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _source() =>
    File('lib/game/presentation/warship_v2_game.dart').readAsStringSync();

void main() {
  test('F-36 预警绘制在背景之后、实体之前（背景之上、实体之下）', () {
    final source = _source();
    final renderStart = source.indexOf('void render(Canvas canvas) {');
    expect(renderStart, greaterThanOrEqualTo(0));
    final renderBody = source.substring(
      renderStart,
      source.indexOf('\n  }', renderStart),
    );

    final iBackground = renderBody.indexOf('_drawBackground(');
    final iTelegraph = renderBody.indexOf('_drawTelegraphs(');
    final iEnemies = renderBody.indexOf('_drawEnemies(');

    expect(iBackground, greaterThanOrEqualTo(0), reason: '应有背景绘制');
    expect(iTelegraph, greaterThanOrEqualTo(0), reason: '应有预警绘制');
    expect(iEnemies, greaterThanOrEqualTo(0), reason: '应有实体绘制');

    expect(
      iBackground < iTelegraph,
      isTrue,
      reason: '预警必须画在**背景之上**',
    );
    expect(
      iTelegraph < iEnemies,
      isTrue,
      reason: '预警必须画在**实体之下**（协议 §3.2）',
    );
  });

  test('F-36 预警只用 manifest 素材，不得用 Canvas 几何替代', () {
    final source = _source();
    final start = source.indexOf('void _drawTelegraphs(');
    expect(start, greaterThanOrEqualTo(0), reason: '应有 _drawTelegraphs');
    final end = source.indexOf('\n  void _drawHazards(', start);
    final body = source.substring(start, end);

    // 必须经 manifest 查绑定 —— 不允许硬编码素材 ID。
    expect(
      body.contains('_telegraphAssetFor('),
      isTrue,
      reason: '预警素材必须按 manifest 绑定解析，不得硬编码',
    );

    // 不得用 Canvas 几何**替代**资源：
    // 圆形/线形都必须走图片绘制（drawImageRect），
    // 不允许出现 drawCircle / drawPath / drawLine 作为预警主体。
    for (final banned in <String>['drawCircle(', 'drawPath(', 'drawLine(']) {
      expect(
        body.contains(banned),
        isFalse,
        reason: '预警绘制里出现了 `$banned` —— 协议 §3.2 禁止用 Canvas '
            '几何替代正式素材',
      );
    }
    expect(
      body.contains('drawImageRect('),
      isTrue,
      reason: '预警应以正式素材绘制',
    );
  });

  test('F-36 两个强制预警招式的素材绑定可解析', () {
    // 与 _telegraphAssetFor 相同的查表逻辑（独立实现，交叉验证）。
    final manifest = File(
      'assets/config/v2/manifest.json',
    ).readAsStringSync();

    for (final entry in <String, String>{
      'sniper_line': 'GFX-WARN-LINE',
      'bomber_drop': 'GFX-HAZARD-BOMBER-WARN',
    }.entries) {
      expect(
        manifest.contains('"${entry.value}"'),
        isTrue,
        reason: '${entry.key} 的素材 ${entry.value} 应已登记',
      );
      expect(
        manifest.contains('"attackId": "${entry.key}"'),
        isTrue,
        reason: '${entry.key} 应有 manifest 绑定',
      );
    }
  });
}
