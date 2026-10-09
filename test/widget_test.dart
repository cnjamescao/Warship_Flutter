// ================================================================
// test/widget_test.dart —— 应用级冒烟测试（端到端）
// ================================================================
// 覆盖真实的 WarshipApp → GameScreen → GameWidget → WarshipGame 全链路：
//   加载资源 → 进入菜单 → 点击 Play → 推进若干帧 → 释放。
//
// 与旧版本的关键区别：
//   旧版用 `Future.delayed(500ms)` **猜测**资源何时加载完成，
//   而且只断言"没崩溃"；由于旧测试从未真正触发过 onLoad，
//   它其实连"资源是否加载成功"都没有验证。
//   现在改为等待公开的确定性完成信号 `game.onLoad()`
//   （规格 §6 明确要求，代码审查反馈 P2 也指出了这个时间假设问题）。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/game_audio.dart';
import 'package:warship_flutter/game/game_session.dart';
import 'package:warship_flutter/main.dart';

import 'support/game_harness.dart';

void main() {
  testWidgets('启动应用、加载资源、点击 Play 并推进若干帧不出现异常', (tester) async {
    // 注入静默音频：冒烟测试不触碰真实音频后端。
    await tester.pumpWidget(WarshipApp(audio: SilentGameAudio()));

    // 从组件树里取出真实创建的游戏实例
    final game = gameFromTree(tester);

    // 等待确定性就绪（交替 runAsync/pump 推进 Flame 自身的加载流程）
    await settleGameLoad(tester, game);

    expect(game.isWorldBuilt, isTrue);
    expect(game.fleet.alienCount, 35, reason: '资源加载完成后世界必须已建好');
    expect(find.text('Alien Invasion'), findsOneWidget);
    expect(find.text('Ships: 3'), findsOneWidget);

    await tester.tap(find.text('Play'));
    await tester.pump();
    expect(game.session.state, GameState.playing);

    stepGame(game, frames: 120);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Game Over'), findsNothing);

    // 释放：GameScreen.dispose 会调用 game.close()
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(game.isClosed, isTrue, reason: '屏幕释放必须释放它拥有的游戏实例');
  });
}
