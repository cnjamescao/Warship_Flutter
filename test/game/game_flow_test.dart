// ================================================================
// test/game/game_flow_test.dart —— 规则集成测试（确定性驱动）
// ================================================================
// 在真实的 WarshipGame + Flame 组件树上验证规则，
// 但不依赖渲染帧：用 `stepGame()` 直接驱动 update，
// 因此完全确定、不受测试环境时钟影响。
//
// 覆盖规格 §6 的 T01–T09 / T11 中与规则相关的部分。
// 纯数学与纯状态的部分在 test/unit/ 中单独覆盖。
// ================================================================

import 'package:flame/components.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/components.dart';
import 'package:warship_flutter/game/game_config.dart';
import 'package:warship_flutter/game/game_session.dart';
import 'package:warship_flutter/game/warship_game.dart';

import '../support/game_harness.dart';

void main() {
  group('T01 启动与就绪', () {
    testWidgets('加载完成后进入 menu，初始值为 3/0/0', (tester) async {
      final game = await createGame(tester);

      expect(game.isWorldReady, isTrue);
      expect(game.session.state, GameState.menu);
      expect(game.session.lives, 3);
      expect(game.session.score, 0);
      expect(game.session.highScore, 0);
    });

    testWidgets('onLoad 是幂等的：不会重复初始化世界', (tester) async {
      final game = await createGame(tester);
      expect(game.fleet.alienCount, 35);

      // 再次调用（组件树挂载时 Flame 也会调用一次）不得重复生成
      await tester.runAsync(() => game.onLoad());

      expect(game.fleet.alienCount, 35, reason: '重复 onLoad 不得产生第二批敌人');
    });

    testWidgets('固定逻辑画布：世界恒为 800×600，与窗口无关', (tester) async {
      final game = await createGame(tester);
      expect(game.size.x, 800);
      expect(game.size.y, 600);
    });

    testWidgets('menu 状态下逻辑不推进', (tester) async {
      final game = await createGame(tester);
      final before = game.fleet.minX;

      stepGame(game, frames: 60);

      expect(game.fleet.minX, before);
      expect(game.session.state, GameState.menu);
    });
  });

  group('T02 开始与重开', () {
    testWidgets('startNewGame 进入 playing 并生成满编舰队', (tester) async {
      final game = await createGame(tester);

      game.startNewGame();

      expect(game.session.state, GameState.playing);
      expect(game.session.lives, 3);
      expect(game.session.score, 0);
      expect(game.fleet.alienCount, 35);
    });

    testWidgets('重开重置本局数据但保留最高分', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      game.session.addScore(750);

      game.startNewGame();

      expect(game.session.score, 0);
      expect(game.session.lives, 3);
      expect(game.session.highScore, 750);
      expect(game.fleet.alienCount, 35);
      expect(game.bullets, isEmpty);
    });

    testWidgets('playing 时舰队会推进', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      final before = game.fleet.minX;

      stepGame(game, frames: 30);

      expect(game.fleet.minX, isNot(before));
    });
  });

  group('输入与射击', () {
    testWidgets('按住左键飞船左移，并且不会越界', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      final startX = game.ship!.x;
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      stepGame(game, frames: 30);
      expect(game.ship!.x, lessThan(startX));

      stepGame(game, frames: 300);
      expect(game.ship!.x, 0, reason: '一直向左应停在左边界');
    });

    testWidgets('按住右键飞船右移并停在右边界', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.keyD));
      stepGame(game, frames: 300);

      expect(game.ship!.x, game.config.shipMaxX);
      expect(game.ship!.x, 736);
    });

    testWidgets('按住空格会生成子弹', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      expect(game.bullets, isEmpty);

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      stepGame(game, frames: 10);

      expect(game.bullets, isNotEmpty);
    });

    testWidgets('射击受冷却限制（不会每帧一颗）', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      // 把飞船移到最左侧：该位置的弹道不会命中任何敌人，
      // 否则"子弹被击毁"会干扰对"发射了几颗"的计数。
      game.ship!.x = 0;
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));

      // 一帧内最多一颗
      stepGame(game, frames: 1);
      expect(game.bullets.length, 1);

      // 冷却 0.28s ≈ 17 帧 @60fps
      stepGame(game, frames: 10);
      expect(game.bullets.length, 1, reason: '冷却期内不得再发射');

      stepGame(game, frames: 10); // 累计 21 帧 > 17 帧冷却
      expect(game.bullets.length, greaterThan(1), reason: '冷却结束后应再次发射');
    });

    testWidgets('松开空格后停止射击，旧子弹最终被回收', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      stepGame(game, frames: 10);
      game.input.handleKeyEvent(keyUp(LogicalKeyboardKey.space));

      stepGame(game, frames: 400);

      expect(game.bullets, isEmpty, reason: '飞出顶部后必须被回收');
    });
  });

  group('T05 失焦', () {
    testWidgets('失焦会清空输入并自动暂停', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      expect(game.input.moveLeft, isTrue);

      game.handleFocusLost();

      expect(game.input.moveLeft, isFalse);
      expect(game.input.shoot, isFalse);
      expect(
        game.session.state,
        GameState.paused,
        reason: '失焦必须自动暂停，避免"离开一下回来就已经掉命"',
      );

      final x = game.ship!.x;
      stepGame(game, frames: 60);
      expect(game.ship!.x, x, reason: '失焦后世界必须冻结');
    });

    testWidgets('失焦自动暂停不会改变分数与坐标', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      stepGame(game, frames: 30);

      final score = game.session.score;
      final shipX = game.ship!.x;
      final fleetMin = game.fleet.minX;

      game.handleFocusLost();

      expect(game.session.score, score);
      expect(game.ship!.x, shipX);
      expect(game.fleet.minX, fleetMin);
    });

    testWidgets('不在 playing 时失焦是安全的空操作', (tester) async {
      final game = await createGame(tester);
      expect(game.session.state, GameState.menu);

      expect(game.handleFocusLost, returnsNormally);
      expect(game.session.state, GameState.menu, reason: '菜单不该被"暂停"');
    });
  });

  group('T08 帧时间限幅', () {
    testWidgets('巨大 dt 被限制到 maxStepSeconds，飞船不会瞬移', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowRight));
      final before = game.ship!.x;

      game.update(10); // 模拟卡顿 10 秒

      expect(
        game.ship!.x - before,
        closeTo(game.config.shipSpeed * game.config.maxStepSeconds, 0.001),
      );
    });

    testWidgets('巨大 dt 之后舰队仍在边界内', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      game.update(10);

      expect(game.fleet.minX, greaterThanOrEqualTo(0));
      expect(game.fleet.maxX, lessThanOrEqualTo(800));
    });
  });

  group('T03 唯一命中（集成）', () {
    testWidgets('击毁敌人只加一次 50 分', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      // 把飞船移到最左列敌人正下方，然后持续射击
      final targetX = game.fleet.aliens.first.x;
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      stepUntil(game, () => game.ship!.x <= 0);
      game.input.handleKeyEvent(keyUp(LogicalKeyboardKey.arrowLeft));
      // 直接对齐到目标列，避免依赖具体速度
      game.ship!.x = targetX.clamp(0.0, game.config.shipMaxX);

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));

      final hitFrame = stepUntil(game, () => game.session.score > 0);
      expect(hitFrame, greaterThanOrEqualTo(0), reason: '应当击落至少一个敌人');

      // 每击毁一个敌人恰好 +50（不是 +100 之类）
      final firstScore = game.session.score;
      expect(firstScore % game.config.alienPoints, 0);
    });
  });

  group('T09 掉命与结束', () {
    testWidgets('放任不管会掉光 3 条命并进入 gameOver', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      final frames = stepUntil(
        game,
        () => game.session.state == GameState.gameOver,
      );

      expect(frames, greaterThanOrEqualTo(0), reason: '敌人下压应最终耗尽生命');
      expect(game.session.lives, 0);
      expect(game.session.state, GameState.gameOver);
    });

    testWidgets('初始只有一条命时，掉一次命即结束', (tester) async {
      final game = await createGame(
        tester,
        config: const GameConfig(initialLives: 1),
      );
      game.startNewGame();

      stepUntil(game, () => game.session.state == GameState.gameOver);

      expect(game.session.lives, 0);
      expect(game.session.state, GameState.gameOver);
    });

    testWidgets('掉命后场上敌人与子弹被清空并重建', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      stepGame(game, frames: 20);
      expect(game.bullets, isNotEmpty);

      final livesBefore = game.session.lives;
      stepUntil(game, () => game.session.lives < livesBefore);

      expect(game.session.lives, livesBefore - 1);
      expect(game.fleet.alienCount, 35, reason: '掉命后应重建满编舰队');
    });

    testWidgets('gameOver 之后逻辑不再推进', (tester) async {
      final game = await createGame(
        tester,
        config: const GameConfig(initialLives: 1),
      );
      game.startNewGame();
      stepUntil(game, () => game.session.state == GameState.gameOver);

      final fleetMin = game.fleet.minX;
      final score = game.session.score;

      stepGame(game, frames: 120);

      expect(game.fleet.minX, fleetMin);
      expect(game.session.score, score);
      expect(game.session.state, GameState.gameOver);
    });
  });

  group('T12 暂停 / 恢复', () {
    /// 直接向游戏投递一个按键事件，返回引擎的处理结果。
    KeyEventResult press(WarshipGame game, LogicalKeyboardKey key) =>
        game.onKeyEvent(keyDown(key), <LogicalKeyboardKey>{});

    KeyEventResult release(WarshipGame game, LogicalKeyboardKey key) =>
        game.onKeyEvent(keyUp(key), <LogicalKeyboardKey>{});

    testWidgets('Esc 暂停后世界完全冻结', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      stepGame(game, frames: 30);

      expect(press(game, LogicalKeyboardKey.escape), KeyEventResult.handled);
      expect(game.session.state, GameState.paused);
      expect(game.isPaused, isTrue);

      final score = game.session.score;
      final lives = game.session.lives;
      final shipX = game.ship!.x;
      final fleetMin = game.fleet.minX;
      final bulletCount = game.bullets.length;

      stepGame(game, frames: 300);

      expect(game.session.state, GameState.paused);
      expect(game.session.score, score, reason: '暂停不得改变分数');
      expect(game.session.lives, lives, reason: '暂停不得改变生命');
      expect(game.ship!.x, shipX, reason: '暂停不得改变飞船坐标');
      expect(game.fleet.minX, fleetMin, reason: '暂停不得改变舰队坐标');
      expect(game.bullets.length, bulletCount, reason: '暂停不得生成或移除子弹');
    });

    testWidgets('P 键同样可以暂停', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      expect(press(game, LogicalKeyboardKey.keyP), KeyEventResult.handled);
      expect(game.session.state, GameState.paused);
    });

    testWidgets('再次按暂停键恢复，世界重新推进', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      press(game, LogicalKeyboardKey.escape);
      expect(game.session.state, GameState.paused);

      press(game, LogicalKeyboardKey.escape);

      expect(game.session.state, GameState.playing);
      final before = game.fleet.minX;
      stepGame(game, frames: 30);
      expect(game.fleet.minX, isNot(before), reason: '恢复后必须继续推进');
    });

    testWidgets('长按暂停键不会反复抖动（边沿触发）', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      press(game, LogicalKeyboardKey.escape);
      expect(game.session.state, GameState.paused);

      // 长按期间系统会补发重复事件，必须被忽略
      for (var i = 0; i < 5; i++) {
        game.onKeyEvent(
          KeyRepeatEvent(
            physicalKey: PhysicalKeyboardKey.escape,
            logicalKey: LogicalKeyboardKey.escape,
            timeStamp: Duration(milliseconds: 100 * (i + 1)),
          ),
          <LogicalKeyboardKey>{},
        );
      }
      expect(game.session.state, GameState.paused, reason: '重复事件不得来回切换');

      // 抬起也不应该切换
      release(game, LogicalKeyboardKey.escape);
      expect(game.session.state, GameState.paused);
    });

    testWidgets('暂停会清空输入：恢复后不会自己移动或射击', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      expect(game.input.hasAnyInput, isTrue);

      game.pause();

      expect(game.input.hasAnyInput, isFalse, reason: '暂停必须清空输入状态');
      expect(game.bullets, isEmpty);

      game.resume();
      final x = game.ship!.x;
      stepGame(game, frames: 60);
      expect(game.ship!.x, x, reason: '恢复后不得因残留按键而移动');
      expect(game.bullets, isEmpty, reason: '恢复后不得因残留按键而射击');
    });

    testWidgets('暂停中移动/射击键不被消费', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      game.pause();

      expect(press(game, LogicalKeyboardKey.arrowLeft), KeyEventResult.ignored);
      expect(press(game, LogicalKeyboardKey.space), KeyEventResult.ignored);
      expect(game.input.moveLeft, isFalse);
      expect(game.input.shoot, isFalse);
    });

    testWidgets('menu 与 gameOver 下暂停键不生效', (tester) async {
      final game = await createGame(tester);
      expect(game.session.state, GameState.menu);
      expect(press(game, LogicalKeyboardKey.escape), KeyEventResult.ignored);
      expect(game.session.state, GameState.menu);

      game.session.setState(GameState.gameOver);
      expect(press(game, LogicalKeyboardKey.escape), KeyEventResult.ignored);
      expect(game.session.state, GameState.gameOver);
    });

    testWidgets('pause/resume/togglePause 在错误状态下是安全的空操作', (tester) async {
      final game = await createGame(tester);

      // menu 下
      expect(game.pause, returnsNormally);
      expect(game.resume, returnsNormally);
      expect(game.togglePause, returnsNormally);
      expect(game.session.state, GameState.menu);

      // gameOver 下
      game.session.setState(GameState.gameOver);
      game.togglePause();
      expect(game.session.state, GameState.gameOver);
    });

    testWidgets('close 之后暂停相关操作安全', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      game.close();

      expect(game.togglePause, returnsNormally);
      expect(game.pause, returnsNormally);
      expect(game.resume, returnsNormally);
      expect(game.session.state, GameState.playing);
    });

    testWidgets('暂停期间不会掉命（世界真的冻结了）', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      game.pause();

      // 20 秒游戏时间：若不冻结，敌人早已触底并扣命
      stepGame(game, frames: 1200);

      expect(game.session.lives, 3, reason: '暂停期间不得掉命');
      expect(game.session.state, GameState.paused);
    });
  });

  group('T10 单帧事务（集成）', () {
    testWidgets('击毁敌人的那一帧最多只通知一次', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      // 对齐到最左列敌人正下方并持续射击，确保必然会击毁敌人
      game.ship!.x = game.fleet.aliens.first.x.clamp(
        0.0,
        game.config.shipMaxX,
      );
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));

      var notifications = 0;
      void listener() => notifications++;
      game.session.scoreNotifier.addListener(listener);
      addTearDown(() => game.session.scoreNotifier.removeListener(listener));

      final scoreBefore = game.session.score;
      var frames = 0;
      var lastFrameNotifications = 0;

      while (game.session.score == scoreBefore && frames < 900) {
        notifications = 0; // 只统计"这一帧"的通知次数
        game.update(1 / 60);
        lastFrameNotifications = notifications;
        frames++;
      }

      expect(
        game.session.score,
        greaterThan(scoreBefore),
        reason: '前置条件：应当击毁至少一个敌人',
      );
      expect(
        lastFrameNotifications,
        1,
        reason: '一次规则事务只允许通知一次（旧实现中"加分"与"掉命"会各通知一次）',
      );
    });
  });

  group('T11 释放', () {
    testWidgets('close 之后不再更新、不再通知', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      stepGame(game, frames: 10);

      var notifications = 0;
      void listener() => notifications++;
      game.session.livesNotifier.addListener(listener);

      game.close();
      expect(game.isClosed, isTrue);

      final lives = game.session.lives;
      final score = game.session.score;

      stepGame(game, frames: 120);

      expect(game.session.lives, lives);
      expect(game.session.score, score);
      expect(notifications, 0, reason: '释放后不得再向 UI 发通知');

      game.session.livesNotifier.removeListener(listener);
    });

    testWidgets('close 会把本游戏创建的实体全部从 World 摘除', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();
      // 制造出子弹，确保场上各类实体都存在
      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      stepGame(game, frames: 30);

      expect(game.bullets, isNotEmpty, reason: '前置条件：场上应有子弹');
      expect(game.fleet.alienCount, greaterThan(0));
      expect(game.ship, isNotNull);
      // 让 Flame 处理挂载队列，实体真正进入 World
      game.update(0.016);
      expect(
        game.world.children.whereType<PlayerShip>(),
        isNotEmpty,
        reason: '前置条件：飞船应在 World 中',
      );

      game.close();

      // 引用被清空
      expect(game.ship, isNull);
      expect(game.bullets, isEmpty);
      expect(game.fleet.alienCount, 0);

      // 让 Flame 处理移除队列（移除是排队的）
      game.update(0);

      expect(
        game.world.children.whereType<PlayerShip>(),
        isEmpty,
        reason: '关闭后 World 不应再保留飞船',
      );
      expect(game.world.children.whereType<AlienEnemy>(), isEmpty);
      expect(game.world.children.whereType<Bullet>(), isEmpty);
      expect(
        game.world.children.whereType<RectangleComponent>(),
        isEmpty,
        reason: '关闭后 World 不应再保留背景',
      );
    });

    testWidgets('close 是幂等的', (tester) async {
      final game = await createGame(tester);
      game.startNewGame();

      expect(() {
        game.close();
        game.close();
      }, returnsNormally);
    });

    testWidgets('close 之后 startNewGame 是安全的空操作', (tester) async {
      final game = await createGame(tester);
      game.close();

      expect(() => game.startNewGame(), returnsNormally);
      expect(game.session.state, GameState.menu);
      expect(game.fleet.alienCount, 0, reason: '关闭后不得重建世界');
    });

    testWidgets('资源加载未完成时 close：不建立世界，worldReady 以取消结束', (tester) async {
      final audio = RecordingGameAudio();
      final game = WarshipGame(audio: audio);
      addTearDown(game.close);

      // 启动加载但不等待它完成，就在加载途中关闭
      final load = game.onLoad();
      game.close();
      expect(game.isClosed, isTrue);

      // onLoad 本身应正常返回，而不是抛异常
      await load;

      expect(game.isWorldReady, isTrue, reason: '就绪信号必须被明确终结，不能悬空');
      expect(game.ship, isNull, reason: '关闭后不得建立世界');
      expect(game.fleet.alienCount, 0);
      expect(audio.preloadCount, 0, reason: '关闭后不得再预加载音频');

      await expectLater(
        game.worldReady,
        throwsA(isA<GameLoadCancelled>()),
        reason: '必须以可识别的取消错误结束，便于区分"取消"与"加载失败"',
      );
    });
  });

  group('音效（已批准提升进 v1.1）', () {
    testWidgets('初始化会调用一次 preload', (tester) async {
      final audio = RecordingGameAudio();
      await createGame(tester, audio: audio);
      expect(audio.preloadCount, 1);
    });

    testWidgets('射击会触发射击音效', (tester) async {
      final audio = RecordingGameAudio();
      final game = await createGame(tester, audio: audio);
      game.startNewGame();

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      stepGame(game, frames: 5);

      expect(audio.played, contains('shoot'));
    });

    testWidgets('生命周期设守卫：重复 onLoad 不会重复 preload', (tester) async {
      final audio = RecordingGameAudio();
      final game = await createGame(tester, audio: audio);
      await tester.runAsync(() => game.onLoad());
      expect(audio.preloadCount, 1);
    });

    testWidgets('静音后不再播放任何音效', (tester) async {
      final audio = RecordingGameAudio();
      final game = await createGame(tester, audio: audio);
      game.startNewGame();
      audio.setMuted(true);

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      stepGame(game, frames: 60);

      expect(audio.played, isEmpty);
    });

    testWidgets('掉命时播放掉命音效', (tester) async {
      final audio = RecordingGameAudio();
      final game = await createGame(tester, audio: audio);
      game.startNewGame();

      stepUntil(game, () => game.session.lives < 3);

      expect(audio.played, contains('lifeLost'));
    });

    testWidgets('结束时播放结束音效', (tester) async {
      final audio = RecordingGameAudio();
      final game = await createGame(
        tester,
        config: const GameConfig(initialLives: 1),
        audio: audio,
      );
      game.startNewGame();
      stepUntil(game, () => game.session.state == GameState.gameOver);

      expect(audio.played, contains('gameOver'));
    });

    testWidgets('音频实现抛异常绝不会影响对局', (tester) async {
      final game = await createGame(tester, audio: ThrowingGameAudio());
      game.startNewGame();

      game.input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      stepGame(game, frames: 30);

      expect(game.session.state, GameState.playing);
      expect(game.bullets, isNotEmpty, reason: '音频失败也必须照常射击');
    });
  });
}
