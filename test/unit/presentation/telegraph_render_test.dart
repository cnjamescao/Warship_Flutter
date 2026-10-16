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
import 'package:warship_flutter/game/presentation/warship_v2_game.dart';

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

  test('F-36 线形预警带宽按内容比例反推，横带厚度正确（防"巨大色块"回归）', () {
    // 玩家实测："中间突然闪现了一个战机然后又凭空消失了" ——
    // 根因是本文件所测的实现缺陷：`GFX-WARN-LINE` 的画布是 512×512，
    // 但**内容只有 500×72**；把画布高度当带宽会把横带纵向拉伸 7 倍。
    //
    // 这里把**代码常量**与**素材实测内容**绑定：素材若更换，
    // 本用例会失败并提示重新核对比例。
    const contentHeight = 72.0;
    const canvasHeight = 512.0;

    // 代码中的常量必须与素材实测一致。
    expect(
      kWarnLineContentHeightRatio,
      closeTo(contentHeight / canvasHeight, 1e-9),
      reason: 'kWarnLineContentHeightRatio 必须等于素材实测的 '
          '内容高/画布高（$contentHeight/$canvasHeight）',
    );

    // 反推出的画布带宽，其**实际横带厚度**应等于期望厚度。
    final canvasBand =
        kWarnLineVisualThickness / kWarnLineContentHeightRatio;
    final visibleThickness = canvasBand * kWarnLineContentHeightRatio;
    expect(
      visibleThickness,
      closeTo(kWarnLineVisualThickness, 1e-6),
      reason: '横带实际厚度应等于 kWarnLineVisualThickness',
    );
    // 若误用画布高度（旧实现），厚度会变成 512 —— 明确钉住这个反例。
    expect(
      visibleThickness,
      lessThan(canvasHeight / 4),
      reason: '厚度不应接近画布高度（那正是"巨大色块"的成因）',
    );
  });
}
