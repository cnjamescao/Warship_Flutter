// ================================================================
// test/support/game_harness.dart —— 测试公共脚手架
// ================================================================
//
// 【为什么不用 GameWidget 的帧循环来推进游戏？】
//
// 实测结论（见开发过程记录）：
//   Flame 的组件生命周期（mount / onLoad）由游戏循环的 `updateTree` 驱动，
//   而 flutter_test 里的"帧时钟"（pump）与"真实异步时钟"（runAsync）
//   是两个互不推进的域：
//     * 只 pump  → 资源 IO 永远不完成（停在 fake async 域）；
//     * 只 runAsync → 帧不推进，onLoad 根本不会启动。
//   两者互相等待，最终表现为测试挂起。
//
// 因此这里采用【确定性驱动】：
//   1. 用 `tester.runAsync(() => game.onLoad())` 在真实事件循环里完成
//      资源加载（而不是 sleep 猜测，符合规格 §6）；
//   2. 用 `stepGame()` 直接调用 `game.update(dt)` 推进规则。
//
// 好处：不依赖渲染帧、完全确定、速度快，
// 正好落实规格的非功能目标「核心规则可在无窗口测试」。
// ================================================================

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/game_audio.dart';
import 'package:warship_flutter/game/game_config.dart';
import 'package:warship_flutter/game/warship_game.dart';
import 'package:warship_flutter/main.dart';

/// 记录被播放的音效，但不触碰任何真实音频后端。
///
/// 行为与 [FlameGameAudio] 的契约保持一致：静音或已释放时不再记录。
class RecordingGameAudio extends GameAudio {
  final List<String> played = <String>[];
  int preloadCount = 0;

  void _record(String name) {
    if (isMuted || isDisposed) {
      return;
    }
    played.add(name);
  }

  @override
  Future<void> preload() async => preloadCount++;

  @override
  void playShoot() => _record('shoot');

  @override
  void playHit() => _record('hit');

  @override
  void playLifeLost() => _record('lifeLost');

  @override
  void playGameOver() => _record('gameOver');
}

/// 每次调用都抛异常 —— 用于验证"音频失败绝不阻塞对局"。
class ThrowingGameAudio extends GameAudio {
  @override
  Future<void> preload() async => throw StateError('音频不可用');

  @override
  void playShoot() => throw StateError('音频不可用');

  @override
  void playHit() => throw StateError('音频不可用');

  @override
  void playLifeLost() => throw StateError('音频不可用');

  @override
  void playGameOver() => throw StateError('音频不可用');
}

/// 创建一个**已完成资源加载**的游戏实例。
///
/// 资源读取是真实异步 IO，必须放在 `tester.runAsync` 里，
/// 等待的是确定性的 `onLoad` 完成，而不是固定时长的 sleep。
Future<WarshipGame> createGame(
  WidgetTester tester, {
  GameConfig? config,
  GameAudio? audio,
}) async {
  final game = WarshipGame(
    config: config,
    audio: audio ?? RecordingGameAudio(),
  );
  addTearDown(game.close);
  await tester.runAsync(() => game.onLoad());
  return game;
}

/// 把游戏挂进完整的 Flutter 外壳（HUD / 遮罩 / 静音按钮）。
Future<WarshipGame> mountApp(
  WidgetTester tester, {
  GameConfig? config,
  GameAudio? audio,
}) async {
  final game = await createGame(tester, config: config, audio: audio);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: GameScreen(game: game),
    ),
  );
  await tester.pump();
  return game;
}

/// 确定性推进游戏若干帧（直接驱动 update，不依赖渲染帧）。
void stepGame(WarshipGame game, {int frames = 1, double dt = 1 / 60}) {
  for (var i = 0; i < frames; i++) {
    game.update(dt);
  }
}

/// 持续推进游戏直到满足 [until]，或达到帧数上限。
///
/// 返回实际推进的帧数；超时未满足时返回负值，便于断言给出清晰原因。
int stepUntil(
  WarshipGame game,
  bool Function() until, {
  int maxFrames = 20000,
  double dt = 1 / 60,
}) {
  for (var i = 0; i < maxFrames; i++) {
    if (until()) {
      return i;
    }
    game.update(dt);
  }
  return until() ? maxFrames : -1;
}

/// 构造一个"按下"事件。
KeyDownEvent keyDown(LogicalKeyboardKey logicalKey) => KeyDownEvent(
  physicalKey: physicalKeyFor(logicalKey),
  logicalKey: logicalKey,
  timeStamp: Duration.zero,
);

/// 构造一个"抬起"事件。
KeyUpEvent keyUp(LogicalKeyboardKey logicalKey) => KeyUpEvent(
  physicalKey: physicalKeyFor(logicalKey),
  logicalKey: logicalKey,
  timeStamp: Duration.zero,
);

/// 逻辑键 → 物理键的简单映射（控制器只读逻辑键，这里只为构造合法事件）。
PhysicalKeyboardKey physicalKeyFor(LogicalKeyboardKey logicalKey) {
  if (logicalKey == LogicalKeyboardKey.keyA) {
    return PhysicalKeyboardKey.keyA;
  }
  if (logicalKey == LogicalKeyboardKey.keyD) {
    return PhysicalKeyboardKey.keyD;
  }
  if (logicalKey == LogicalKeyboardKey.arrowLeft) {
    return PhysicalKeyboardKey.arrowLeft;
  }
  if (logicalKey == LogicalKeyboardKey.arrowRight) {
    return PhysicalKeyboardKey.arrowRight;
  }
  if (logicalKey == LogicalKeyboardKey.space) {
    return PhysicalKeyboardKey.space;
  }
  return PhysicalKeyboardKey.keyZ;
}

/// 在 flutter_test 中把 Flame 自身的加载流程推进到完成。
///
/// 【为什么需要交替 pump 与 runAsync】
/// 当游戏是通过 GameWidget 挂载时，是 Flame（而不是我们）在 fake-async 域里
/// 发起 onLoad 的。此时：
///   * 只 pump        → 真实资源 IO 永远不完成；
///   * 只 runAsync    → 续体排在 fake-async 域里，没有帧就不会执行。
/// 所以必须交替：runAsync 让真实 IO 完成，pump 让续体得以推进。
///
/// 注意这里仍然是"等到真的就绪为止"，而不是"睡够固定时长就当加载完了"。
Future<void> settleGameLoad(
  WidgetTester tester,
  WarshipGame game, {
  int maxRounds = 40,
}) async {
  for (var round = 0; round < maxRounds && !game.isWorldBuilt; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

/// 从组件树里取出真实创建的游戏实例（用于应用级冒烟测试）。
WarshipGame gameFromTree(WidgetTester tester) {
  final widget = tester.widget<GameWidget<WarshipGame>>(
    find.byType(GameWidget<WarshipGame>),
  );
  return widget.game!;
}
