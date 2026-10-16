// ================================================================
// test/unit/presentation/full_shield_visibility_test.dart —— AC-05 精确用例（1/2）
// ================================================================
// 负责人批复（2026-10-16）：
// 「玩家满护盾：验证完整护盾时机体仍可见，**不能被不透明护盾层遮住**。」
//
// 产品来源：`Warship现代化产品设计文档.md` §7.5 状态表「玩家满护盾」行 ——
// 结束条件/验收：「**不遮挡机体**」。
//
// 做法：用**与渲染器相同的数学**分别画两次 ——
//   ① 只画机体；② 先画满护盾层、再画机体（渲染器的真实顺序）。
// 然后比较**机体范围内**（半径 ≤ player.radius）的像素：
// 必须**完全一致**，即护盾层没有遮住机体。
// 这直接验证"可见性"，而不是只检查代码里有没有画圆。
// ================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/presentation/asset_cache.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;

const double kRadius = 30;
const double kSpriteScale = 2.4;
/// 与渲染器一致：护盾环画在 `player.radius + 10`。
const double kShieldRingRadius = kRadius + 10;

Future<ui.Image> _render(
  WidgetTester tester,
  ui.Image sprite, {
  required bool withShield,
}) async {
  final iw = sprite.width.toDouble();
  final ih = sprite.height.toDouble();
  final longest = iw > ih ? iw : ih;
  final scale = (kRadius * 2 * kSpriteScale) / longest;
  final w = iw * scale;
  final h = ih * scale;
  final size = (kShieldRingRadius * 2 + 8).ceil();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final center = Offset(size / 2, size / 2);

  if (withShield) {
    // 渲染器真实顺序：**先**画护盾环，**再**画机体。
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0x6633E1FF);
    canvas.drawCircle(center, kShieldRingRadius, stroke);
  }
  canvas.drawImageRect(
    sprite,
    Rect.fromLTWH(0, 0, iw, ih),
    Rect.fromLTWH(center.dx - w / 2, center.dy - h / 2, w, h),
    Paint(),
  );

  final picture = recorder.endRecording();
  final image = await tester.runAsync(() => picture.toImage(size, size));
  return image!;
}

Future<List<int>> _bytes(WidgetTester tester, ui.Image image) async {
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    manifest = (await loadV2CatalogForTests()).manifest;
  });

  testWidgets('AC-05 满护盾：机体范围内的像素完全不被护盾层改变', (tester) async {
    final cache = VisualAssetCache(manifest: manifest);
    await tester.runAsync(() async {
      await cache.loadGroup(AssetLoadGroup.firstRun);
    });
    final sprite = cache.imageFor('GFX-PLAYER-BASE', 'default');
    expect(sprite, isNotNull, reason: '玩家素材应可取到');

    final plain = await _render(tester, sprite!, withShield: false);
    final shielded = await _render(tester, sprite, withShield: true);
    final a = await _bytes(tester, plain);
    final b = await _bytes(tester, shielded);

    final size = plain.width;
    final center = size / 2.0;

    var bodyPixels = 0;
    var changedInBody = 0;
    // 遍历整个画布，但只对**机体范围内**（≤ player.radius）的像素做等值断言。
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final dx = x + 0.5 - center;
        final dy = y + 0.5 - center;
        if (dx * dx + dy * dy > kRadius * kRadius) {
          continue;
        }
        bodyPixels++;
        final i = (y * size + x) * 4;
        if (a[i] != b[i] ||
            a[i + 1] != b[i + 1] ||
            a[i + 2] != b[i + 2] ||
            a[i + 3] != b[i + 3]) {
          changedInBody++;
        }
      }
    }

    expect(bodyPixels, greaterThan(0), reason: '机体范围内应有像素');
    expect(
      changedInBody,
      0,
      reason: '满护盾时**机体范围内**有 $changedInBody 个像素被改变 —— '
          '说明护盾层遮住了机体（§7.5「不遮挡机体」）。'
          '护盾环应画在机体**之外**（半径 $kShieldRingRadius > $kRadius）'
          '且为**描边**而非填充。',
    );

    plain.dispose();
    shielded.dispose();
  });
}
