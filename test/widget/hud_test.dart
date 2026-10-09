// ================================================================
// test/widget/hud_test.dart —— HUD / 遮罩 / 静音按钮
// ================================================================
// 覆盖规格 §6 测试分层里的「Flutter Widget（HUD/遮罩/焦点）」一层。
// 代码审查反馈指出旧测试「只断言无异常」，这里改为断言**可见的 UI 结果**。
//
// 注意：游戏规则用 `stepGame/stepUntil` 确定性驱动，
// UI 刷新则交给 `tester.pump()`；两者职责清晰。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/game_config.dart';
import 'package:warship_flutter/game/game_session.dart';

import '../support/game_harness.dart';

void main() {
  group('T01 初始 HUD', () {
    testWidgets('显示 Ships: 3 / High Score: 0 / Score: 0', (tester) async {
      await mountApp(tester);

      expect(find.text('Ships: 3'), findsOneWidget);
      expect(find.text('High Score: 0'), findsOneWidget);
      expect(find.text('Score: 0'), findsOneWidget);
    });

    testWidgets('菜单遮罩显示标题与 Play 按钮', (tester) async {
      await mountApp(tester);

      expect(find.text('Alien Invasion'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Game Over'), findsNothing);
    });
  });

  group('HUD 布局位置（回归：曾错误地显示在屏幕垂直中线）', () {
    /// 当前测试画布的逻辑尺寸。
    Size screenSize(WidgetTester tester) =>
        tester.view.physicalSize / tester.view.devicePixelRatio;

    testWidgets('三项信息都贴在屏幕顶部，而不是垂直居中', (tester) async {
      await mountApp(tester);
      final screen = screenSize(tester);

      for (final label in <String>['Ships: 3', 'High Score: 0', 'Score: 0']) {
        final rect = tester.getRect(find.text(label));
        expect(
          rect.center.dy,
          lessThan(screen.height * 0.25),
          reason: '$label 应当位于屏幕上部（曾经的 bug 是落在垂直中线附近）',
        );
        expect(rect.top, greaterThanOrEqualTo(0));
      }
    });

    testWidgets('HUD 只占内容高度，不会被撑满整屏', (tester) async {
      await mountApp(tester);
      final rect = tester.getRect(find.text('Ships: 3'));

      // 文本自身高度约 20px；如果 HUD 被撑成全屏高，这里会大得多
      expect(rect.height, lessThan(60));
    });

    testWidgets('水平顺序为：左 Ships / 中 High Score / 右 Score', (tester) async {
      await mountApp(tester);
      final screen = screenSize(tester);

      final ships = tester.getCenter(find.text('Ships: 3'));
      final high = tester.getCenter(find.text('High Score: 0'));
      final score = tester.getCenter(find.text('Score: 0'));

      expect(ships.dx, lessThan(high.dx));
      expect(high.dx, lessThan(score.dx));

      // 分别落在左、中、右三等分内
      expect(ships.dx, lessThan(screen.width / 3));
      expect(score.dx, greaterThan(screen.width * 2 / 3));
    });

    testWidgets('窄窗口下 HUD 依然在顶部且不溢出', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await mountApp(tester);

      final rect = tester.getRect(find.text('Ships: 3'));
      expect(rect.center.dy, lessThan(300 * 0.25));
      expect(tester.takeException(), isNull);
    });
  });

  group('T02 开始与重开（UI）', () {
    testWidgets('点击 Play 后遮罩消失并进入 playing', (tester) async {
      final game = await mountApp(tester);

      await tester.tap(find.text('Play'));
      await tester.pump();

      expect(game.session.state, GameState.playing);
      expect(find.text('Play'), findsNothing);
      expect(find.text('Alien Invasion'), findsNothing);
    });

    testWidgets('HUD 分数随状态同步刷新', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      game.session.addScore(150);
      await tester.pump();

      expect(find.text('Score: 150'), findsOneWidget);
      expect(find.text('High Score: 150'), findsOneWidget);
    });

    testWidgets('生命变化会同步刷新 HUD', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      game.session.loseLife();
      await tester.pump();

      expect(find.text('Ships: 2'), findsOneWidget);
    });

    testWidgets('规则提交后无需额外帧就能读到正确的 UI 值', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      // 一次事务同时改分数与生命
      game.session.addScore(250);
      game.session.loseLife();

      // 只 pump 一次：4 个只读值必须在同一帧内全部体现出来
      await tester.pump();

      expect(find.text('Score: 250'), findsOneWidget);
      expect(find.text('Ships: 2'), findsOneWidget);
      expect(find.text('High Score: 250'), findsOneWidget);
    });
  });

  group('T09 结束界面（UI）', () {
    testWidgets('生命耗尽后显示 Game Over、最终分数与 Play Again', (tester) async {
      final game = await mountApp(
        tester,
        config: const GameConfig(initialLives: 1),
      );
      await tester.tap(find.text('Play'));
      await tester.pump();

      game.session.addScore(300);
      stepUntil(game, () => game.session.state == GameState.gameOver);
      await tester.pump();

      expect(find.text('Game Over'), findsOneWidget);
      // 分数会同时出现在 HUD 与结束遮罩上，因此是两个
      expect(find.text('Score: 300'), findsNWidgets(2));
      expect(find.text('Play Again'), findsOneWidget);
      expect(find.text('Ships: 0'), findsOneWidget);
      expect(find.text('High Score: 300'), findsOneWidget);
    });

    testWidgets('点击 Play Again 可重新开始，且最高分保留', (tester) async {
      // 使用默认配置（3 条命），这样可以直接验证"重开恢复到初始生命"
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();
      game.session.addScore(300);
      stepUntil(game, () => game.session.state == GameState.gameOver);
      await tester.pump();

      await tester.tap(find.text('Play Again'));
      await tester.pump();

      expect(game.session.state, GameState.playing);
      expect(find.text('Ships: 3'), findsOneWidget);
      expect(find.text('Score: 0'), findsOneWidget);
      expect(find.text('High Score: 300'), findsOneWidget, reason: '最高分跨局保留');
    });
  });

  group('T05 失焦桥接（GameScreen → 游戏层）', () {
    testWidgets('应用切到 inactive 时会清空输入并自动暂停', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      expect(game.input.moveLeft, isTrue);

      // 模拟窗口失焦：macOS 上切走窗口会进入 inactive
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

      expect(
        game.input.moveLeft,
        isFalse,
        reason: '失焦必须清空输入，否则切回来会持续移动',
      );
      expect(game.input.shoot, isFalse, reason: '失焦后不得继续射击');
      expect(
        game.session.state,
        GameState.paused,
        reason: '失焦必须自动暂停，否则离开一下回来就已经掉命',
      );
    });

    testWidgets('回到前台后保持暂停，需要玩家显式恢复', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(game.session.state, GameState.paused);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(
        game.session.state,
        GameState.paused,
        reason: '不自动恢复：玩家可能还没准备好',
      );

      // 显式恢复后一切正常
      game.resume();
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowRight));
      stepGame(game, frames: 10);

      expect(game.input.moveRight, isTrue);
      expect(game.session.state, GameState.playing);
    });
  });

  group('T12 暂停界面（UI）', () {
    testWidgets('进行中暂停会显示暂停菜单，HUD 仍然可见', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();

      game.pause();
      await tester.pump();

      expect(game.session.state, GameState.paused);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);
      expect(find.text('Esc / P to resume'), findsOneWidget);
      // 暂停时 HUD 不该消失
      expect(find.text('Ships: 3'), findsOneWidget);
      expect(find.text('Score: 0'), findsOneWidget);
    });

    testWidgets('点击 Resume 继续游戏', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();
      game.pause();
      await tester.pump();

      await tester.tap(find.text('Resume'));
      await tester.pump();

      expect(game.session.state, GameState.playing);
      expect(find.text('Paused'), findsNothing);
      expect(find.text('Resume'), findsNothing);
    });

    testWidgets('点击 Restart 可从暂停直接重开一局', (tester) async {
      final game = await mountApp(tester);
      await tester.tap(find.text('Play'));
      await tester.pump();
      game.session.addScore(150);
      game.pause();
      await tester.pump();

      await tester.tap(find.text('Restart'));
      await tester.pump();

      expect(game.session.state, GameState.playing);
      expect(game.session.score, 0);
      expect(game.session.lives, 3);
      expect(find.text('Paused'), findsNothing);
    });

    testWidgets('暂停菜单下静音按钮仍可用（在遮罩之上）', (tester) async {
      final audio = RecordingGameAudio();
      final game = await mountApp(tester, audio: audio);
      await tester.tap(find.text('Play'));
      await tester.pump();
      game.pause();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.volume_up));
      await tester.pump();

      expect(audio.isMuted, isTrue);
    });
  });

  group('静音开关', () {
    testWidgets('默认显示"音量开"图标', (tester) async {
      final audio = RecordingGameAudio();
      await mountApp(tester, audio: audio);

      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      expect(audio.isMuted, isFalse);
    });

    testWidgets('点击后切换为静音，再次点击恢复', (tester) async {
      final audio = RecordingGameAudio();
      await mountApp(tester, audio: audio);

      await tester.tap(find.byIcon(Icons.volume_up));
      await tester.pump();

      expect(audio.isMuted, isTrue);
      expect(find.byIcon(Icons.volume_off), findsOneWidget);

      await tester.tap(find.byIcon(Icons.volume_off));
      await tester.pump();

      expect(audio.isMuted, isFalse);
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
    });

    testWidgets('静音后对局仍在正常运行', (tester) async {
      final audio = RecordingGameAudio();
      final game = await mountApp(tester, audio: audio);

      await tester.tap(find.byIcon(Icons.volume_up));
      await tester.pump();
      await tester.tap(find.text('Play'));
      await tester.pump();

      stepGame(game, frames: 60);

      expect(game.session.state, GameState.playing);
      expect(audio.played, isEmpty);
    });
  });
}
