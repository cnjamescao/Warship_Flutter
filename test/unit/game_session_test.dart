// ================================================================
// test/unit/game_session_test.dart —— 对局状态与 UI 数据契约
// ================================================================
// 覆盖规格：
//   §2.1 对局规则（重置与保留）
//   §4.1 状态与 UI 契约（同步提交，不得依赖 post-frame 回调）
//   §4.2 生命周期（释放后不再通知）
// 对应验收项 T02 / T10 / T11（状态与释放部分）。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/game_config.dart';
import 'package:warship_flutter/game/game_session.dart';

void main() {
  GameSession newSession() => GameSession(config: const GameConfig());

  group('初始状态', () {
    test('T01 新会话为 menu，分数 0 / 最高分 0 / 生命 3', () {
      final session = newSession();
      addTearDown(session.dispose);

      expect(session.state, GameState.menu);
      expect(session.score, 0);
      expect(session.highScore, 0);
      expect(session.lives, 3);

      // notifier 初值必须与字段一致
      expect(session.scoreNotifier.value, 0);
      expect(session.highScoreNotifier.value, 0);
      expect(session.livesNotifier.value, 3);
      expect(session.stateNotifier.value, GameState.menu);
    });
  });

  group('T02 开始与重开', () {
    test('startNewGame 进入 playing 并重置分数与生命', () {
      final session = newSession();
      addTearDown(session.dispose);

      session.addScore(500);
      session.loseLife();
      session.setState(GameState.gameOver);

      session.startNewGame();

      expect(session.state, GameState.playing);
      expect(session.score, 0);
      expect(session.lives, 3);
    });

    test('重开保留当前进程的最高分', () {
      final session = newSession();
      addTearDown(session.dispose);

      session.startNewGame();
      session.addScore(1250);
      expect(session.highScore, 1250);

      session.startNewGame(); // 重开

      expect(session.score, 0, reason: '本局分数必须清零');
      expect(session.highScore, 1250, reason: '最高分必须跨局保留');
      expect(session.highScoreNotifier.value, 1250);
    });

    test('最高分只增不减', () {
      final session = newSession();
      addTearDown(session.dispose);

      session.startNewGame();
      session.addScore(300);
      expect(session.highScore, 300);
      session.startNewGame();
      session.addScore(100);
      expect(session.highScore, 300, reason: '低分不得覆盖最高分');
      expect(session.score, 100);
    });
  });

  group('分数与生命', () {
    test('addScore 累加；非正数被忽略', () {
      final session = newSession();
      addTearDown(session.dispose);

      session.startNewGame();
      session.addScore(50);
      session.addScore(50);
      expect(session.score, 100);

      session.addScore(0);
      session.addScore(-50);
      expect(session.score, 100);
    });

    test('loseLife 递减且不会低于 0', () {
      final session = newSession();
      addTearDown(session.dispose);

      session.startNewGame();
      session.loseLife();
      expect(session.lives, 2);
      session.loseLife();
      session.loseLife();
      expect(session.lives, 0);
      session.loseLife();
      expect(session.lives, 0, reason: '生命不得为负');
    });
  });

  group('T10 状态时序契约', () {
    test('变更方法返回后，listener 能立刻读到已提交的事实（无需 pump）', () {
      final session = newSession();
      addTearDown(session.dispose);

      session.startNewGame();
      session.addScore(150);
      session.loseLife();

      // 没有任何 addPostFrameCallback / pump，立刻读取就必须是一致的
      expect(session.scoreNotifier.value, 150);
      expect(session.highScoreNotifier.value, 150);
      expect(session.livesNotifier.value, 2);
      expect(session.stateNotifier.value, GameState.playing);
    });

    test('通知发生时，四个只读值已经彼此一致（不存在中间态）', () {
      final session = newSession();
      addTearDown(session.dispose);
      session.startNewGame();

      List<int>? observed;
      void listener() {
        observed = <int>[
          session.scoreNotifier.value,
          session.highScoreNotifier.value,
          session.livesNotifier.value,
          session.stateNotifier.value.index,
        ];
      }

      session.scoreNotifier.addListener(listener);
      addTearDown(() => session.scoreNotifier.removeListener(listener));

      session.addScore(200);

      expect(observed, isNotNull, reason: '分数变化必须触发通知');
      expect(observed![0], session.score);
      expect(observed![1], session.highScore);
      expect(observed![2], session.lives);
      expect(observed![3], session.state.index);
    });

    test('相同赋值不会产生多余通知', () {
      final session = newSession();
      addTearDown(session.dispose);

      var notifications = 0;
      void listener() => notifications++;
      session.stateNotifier.addListener(listener);
      addTearDown(() => session.stateNotifier.removeListener(listener));

      session.setState(GameState.menu); // 本来就是 menu
      expect(notifications, 0);

      session.setState(GameState.playing);
      expect(notifications, 1);
    });
  });

  group('T11 释放', () {
    test('dispose 之后不再发布任何通知，也不再改动 notifier', () {
      final session = newSession();
      session.startNewGame();
      session.addScore(100);

      var notifications = 0;
      void listener() => notifications++;
      session.scoreNotifier.addListener(listener);

      session.dispose();
      expect(session.isDisposed, isTrue);

      final scoreAfterDispose = session.scoreNotifier.value;

      // 释放后的任何规则变更都不得再触碰已释放的 notifier
      session.addScore(999);
      session.loseLife();
      session.setState(GameState.gameOver);
      session.commit();

      expect(notifications, 0, reason: '释放后不得再有通知');
      expect(session.scoreNotifier.value, scoreAfterDispose);
    });

    test('dispose 是幂等的', () {
      final session = newSession();
      session.dispose();
      expect(() => session.dispose(), returnsNormally);
    });
  });
}
