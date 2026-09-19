// ================================================================
// game_flow_test.dart —— 游戏主流程回归测试
// ================================================================
//
// 这些测试在无头（headless）测试环境中驱动【真实的】 WarshipGame
// 游戏循环，用来验证游戏能否正常跑起来，而不只是"能编译"。
//
// 覆盖链路：
//   菜单初始态 → startNewGame 开局 → 键盘操作 → 掉命 → 游戏结束 → 重开
//
// 与 widget_test.dart 的分工：
//   - widget_test.dart 验证 "Flutter 外壳 + Flame 画布" 能集成运行；
//   - 本文件验证 "游戏规则本身" 是否正确推进。
// ================================================================

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/warship_game.dart';

void main() {
  /// 把游戏挂到一棵最小化的 Flutter 组件树中，并等待精灵图片真正加载完成。
  ///
  /// 为什么要 runAsync？
  ///   读取 assets 里的 PNG 是真实的异步 IO；
  ///   普通 pump 使用的是"假时钟"，不会真正等待 IO 完成，
  ///   所以必须用 runAsync 包住真实等待。
  Future<void> boot(WidgetTester tester, WarshipGame game) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: GameWidget(game: game),
      ),
    );

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
  }

  /// 推进 [frames] 帧游戏时间，每帧 [ms] 毫秒。
  Future<void> advance(
    WidgetTester tester, {
    int frames = 60,
    int ms = 16,
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(Duration(milliseconds: ms));
    }
  }

  testWidgets('初始状态为菜单，分数 / 最高分 / 生命均为默认值', (tester) async {
    final game = WarshipGame();
    await boot(tester, game);

    expect(game.stateNotifier.value, GameState.menu);
    expect(game.scoreNotifier.value, 0);
    expect(game.highScoreNotifier.value, 0);
    expect(game.livesNotifier.value, 3);
  });

  testWidgets('startNewGame 之后进入 playing 状态并可持续推进游戏循环', (tester) async {
    final game = WarshipGame();
    await boot(tester, game);

    game.startNewGame();
    // startNewGame 内部通过 addPostFrameCallback 同步 UI，需要再 pump 一帧
    await tester.pump();

    expect(game.stateNotifier.value, GameState.playing);
    expect(game.scoreNotifier.value, 0);
    expect(game.livesNotifier.value, 3);

    // 连续跑 2 秒游戏时间，验证游戏循环不抛异常
    await advance(tester, frames: 120);
    expect(tester.takeException(), isNull);
    expect(game.stateNotifier.value, GameState.playing);
  });

  testWidgets('方向键 / A / D / 空格 输入不会导致崩溃', (tester) async {
    final game = WarshipGame();
    await boot(tester, game);
    game.startNewGame();
    await tester.pump();

    // 左移 + 持续射击
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await advance(tester, frames: 40);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);

    // 右移（D 键别名）+ 持续射击
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await advance(tester, frames: 40);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);

    expect(tester.takeException(), isNull);
    expect(game.stateNotifier.value, GameState.playing);
  });

  testWidgets('放任不管：敌人推进到底部导致掉命，最终进入 gameOver', (tester) async {
    final game = WarshipGame();
    await boot(tester, game);
    game.startNewGame();
    await tester.pump();

    // 不给任何输入，只推进时间。
    // 敌人舰队会不断"撞边 → 反向 → 下移"，最终触底或撞到飞船。
    var frames = 0;
    while (game.stateNotifier.value != GameState.gameOver && frames < 3000) {
      await tester.pump(const Duration(milliseconds: 33));
      frames++;
    }

    expect(game.stateNotifier.value, GameState.gameOver,
        reason: '敌人的下压应当最终耗尽 3 条生命');
    expect(game.livesNotifier.value, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('游戏中途重开：分数与生命被重置', (tester) async {
    final game = WarshipGame();
    await boot(tester, game);
    game.startNewGame();
    await tester.pump();

    // 先跑一段时间，让局面发生变化
    await advance(tester, frames: 200, ms: 33);

    // 重新开局
    game.startNewGame();
    await tester.pump();

    expect(game.stateNotifier.value, GameState.playing);
    expect(game.scoreNotifier.value, 0);
    expect(game.livesNotifier.value, 3);

    // 重开后游戏仍能继续正常运行
    await advance(tester, frames: 60);
    expect(tester.takeException(), isNull);
  });
}
