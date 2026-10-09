// ================================================================
// test/widget/viewport_test.dart —— 固定逻辑画布与窗口尺寸
// ================================================================
// 覆盖规格 §3.2（固定逻辑画布）与 §6 的 T06 / T07。
// 这些用例必须把游戏**挂进真实组件树**：
//   只有经过 Flutter 布局，onGameResize 才会带着新的画布尺寸触发。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/game_harness.dart';

void main() {
  group('T06 常规 resize', () {
    testWidgets('resize 后逻辑世界仍恒为 800×600', (tester) async {
      final game = await mountApp(tester);
      expect(game.size.x, 800);

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();

      expect(game.size.x, 800, reason: '规则边界必须与窗口尺寸解耦');
      expect(game.size.y, 600);
    });

    testWidgets('resize 不重排、不下移、不损坏现有舰队与飞船', (tester) async {
      final game = await mountApp(tester);
      // 停留在 menu，逻辑不推进，便于精确比较坐标
      final shipX = game.ship!.x;
      final shipY = game.ship!.y;
      final alienY = game.fleet.aliens.first.y;
      final minX = game.fleet.minX;
      final maxX = game.fleet.maxX;
      final count = game.fleet.alienCount;

      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();

      expect(game.ship!.x, shipX);
      expect(game.ship!.y, shipY);
      expect(game.fleet.aliens.first.y, alienY);
      expect(game.fleet.minX, minX);
      expect(game.fleet.maxX, maxX);
      expect(game.fleet.alienCount, count, reason: 'resize 不得重建或损坏舰队');
      expect(tester.takeException(), isNull);
    });

    testWidgets('resize 之后游戏依然可以正常进行', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      tester.view.physicalSize = const Size(300, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();

      stepGame(game, frames: 120);

      expect(tester.takeException(), isNull);
      expect(game.fleet.minX, greaterThanOrEqualTo(0));
      expect(game.fleet.maxX, lessThanOrEqualTo(800));
    });

    testWidgets('反复横跳 resize 不会破坏世界', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      const sizes = <Size>[
        Size(1600, 400),
        Size(200, 1200),
        Size(800, 600),
        Size(50, 50),
      ];

      for (final size in sizes) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        await tester.pump();
        stepGame(game, frames: 20);

        expect(game.size.x, 800, reason: '每次 resize 后世界都必须还是 800 宽');
        expect(game.fleet.maxX, lessThanOrEqualTo(800));
        expect(game.ship!.x, inInclusiveRange(0, game.config.shipMaxX));
      }
      addTearDown(tester.view.reset);
      expect(tester.takeException(), isNull);
    });
  });

  group('T07 极小窗口', () {
    testWidgets('1×1 窗口不抛异常、不产生负边界、不连续掉命', (tester) async {
      tester.view.physicalSize = const Size(1, 1);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      stepGame(game, frames: 120);

      expect(tester.takeException(), isNull);
      expect(game.config.shipMaxX, greaterThanOrEqualTo(0));
      expect(game.ship!.x, inInclusiveRange(0, game.config.shipMaxX));
      expect(game.session.lives, 3, reason: '2 秒内不应该掉命');
    });

    testWidgets('极端长宽比窗口同样安全', (tester) async {
      tester.view.physicalSize = const Size(4000, 60);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      stepGame(game, frames: 120);

      expect(tester.takeException(), isNull);
      expect(game.size.x, 800);
      expect(game.size.y, 600);
    });

    testWidgets('窗口小到 1 像素时依然能生成满编舰队', (tester) async {
      tester.view.physicalSize = const Size(1, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final game = await mountApp(tester);

      expect(game.fleet.alienCount, 35, reason: '固定逻辑画布不受物理窗口影响');
    });
  });
}
