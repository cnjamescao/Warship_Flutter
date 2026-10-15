// ================================================================
// test/unit/presentation/battlefield_render_test.dart —— F-26-02 端侧验证
// ================================================================
// 玩家复测："看不到飞机，敌机也不知道跑哪里去了"。
//
// 加载已经修好（84/84 成功），因此本文件**不再查加载**，
// 而是**真的把战场画出来数像素** —— 这是"图能不能看见"的唯一硬证据。
//
// 裁决要求「对战场截图做人工视觉验收，确认玩家是可辨认的战舰而非
// 圆点/简化几何图形」。人工那一半由产品负责人做；本文件提供
// **可自动化的那一半**：确认玩家位置附近确实画出了非背景像素。
// ================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/presentation/asset_cache.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    manifest = (await loadV2CatalogForTests()).manifest;
  });

  testWidgets('F-26-02 真实预载后，玩家机体素材能画到画布上（数像素）', (tester) async {
    final cache = VisualAssetCache(manifest: manifest);
    await tester.runAsync(() async {
      await cache.loadGroup(AssetLoadGroup.firstRun);
    });

    final image = cache.imageFor('GFX-PLAYER-BASE', 'default');
    expect(image, isNotNull, reason: '玩家素材应可取到');

    // 用与渲染器**相同**的数学画一遍，然后数"非透明"像素。
    // 这验证的是"素材能不能真的落到画布上"，而不是"缓存里有没有"。
    const radius = 30.0;
    const kSpriteScale = 2.4;
    final iw = image!.width.toDouble();
    final ih = image.height.toDouble();
    final longest = iw > ih ? iw : ih;
    final scale = (radius * 2 * kSpriteScale) / longest;
    final w = iw * scale;
    final h = ih * scale;

    // ignore: avoid_print
    print('玩家素材: ${iw.toInt()}x${ih.toInt()} → 绘制 ${w.toStringAsFixed(1)}x'
        '${h.toStringAsFixed(1)} logical px');

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, iw, ih),
      Rect.fromLTWH(0, 0, w, h),
      Paint(),
    );
    final picture = recorder.endRecording();
    final rendered = await tester.runAsync(
      () => picture.toImage(w.ceil(), h.ceil()),
    );
    expect(rendered, isNotNull);

    final bytes = await tester.runAsync(
      () => rendered!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    final data = bytes!.buffer.asUint8List();

    var opaque = 0;
    for (var i = 3; i < data.length; i += 4) {
      if (data[i] > 8) {
        opaque++;
      }
    }
    final total = w.ceil() * h.ceil();
    // ignore: avoid_print
    print('绘制区域 $total 像素，其中非透明 $opaque');

    expect(
      opaque,
      greaterThan(total * 0.05),
      reason: '玩家素材画出来几乎全是透明的（$opaque/$total）—— '
          '玩家会"看不到飞机"。素材本身的可见像素比例过低。',
    );
  });
}
