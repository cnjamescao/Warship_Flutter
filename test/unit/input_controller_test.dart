// ================================================================
// test/unit/input_controller_test.dart —— 输入契约
// ================================================================
// 覆盖规格 §2.2 与验收项 T04（别名组合）、T05（清空输入）。
// 这里正是旧实现的缺陷所在：A 与 ← 共用同一个 bool，
// 先松开任意一个就会中断动作。
// ================================================================

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/input_controller.dart';

import '../support/game_harness.dart';

void main() {
  late InputController input;

  setUp(() => input = InputController());

  group('单键', () {
    test('A 或 ← 都能触发左移', () {
      input = InputController()
        ..handleKeyEvent(keyDown(LogicalKeyboardKey.keyA));
      expect(input.moveLeft, isTrue);
      expect(input.horizontalAxis, -1);

      input = InputController()
        ..handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      expect(input.moveLeft, isTrue);
    });

    test('D 或 → 都能触发右移', () {
      input = InputController()
        ..handleKeyEvent(keyDown(LogicalKeyboardKey.keyD));
      expect(input.moveRight, isTrue);
      expect(input.horizontalAxis, 1);

      input = InputController()
        ..handleKeyEvent(keyDown(LogicalKeyboardKey.arrowRight));
      expect(input.moveRight, isTrue);
    });

    test('空格触发射击，抬起后停止', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      expect(input.shoot, isTrue);
      input.handleKeyEvent(keyUp(LogicalKeyboardKey.space));
      expect(input.shoot, isFalse);
    });
  });

  group('T04 别名组合（旧实现的核心缺陷）', () {
    test('A + ← 同时按下时，先松开 A 仍保持左移', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.keyA));
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      expect(input.moveLeft, isTrue);

      input.handleKeyEvent(keyUp(LogicalKeyboardKey.keyA));
      expect(
        input.moveLeft,
        isTrue,
        reason: '← 仍然按着，左移不能被别名 key-up 打断',
      );

      input.handleKeyEvent(keyUp(LogicalKeyboardKey.arrowLeft));
      expect(input.moveLeft, isFalse, reason: '两个键都松开后才停止');
    });

    test('A + ← 同时按下时，先松开 ← 仍保持左移', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.keyA));
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));

      input.handleKeyEvent(keyUp(LogicalKeyboardKey.arrowLeft));
      expect(input.moveLeft, isTrue, reason: 'A 仍然按着');

      input.handleKeyEvent(keyUp(LogicalKeyboardKey.keyA));
      expect(input.moveLeft, isFalse);
    });

    test('D + → 同时按下时，先松开 D 仍保持右移', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.keyD));
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowRight));

      input.handleKeyEvent(keyUp(LogicalKeyboardKey.keyD));
      expect(input.moveRight, isTrue);

      input.handleKeyEvent(keyUp(LogicalKeyboardKey.arrowRight));
      expect(input.moveRight, isFalse);
    });
  });

  group('方向组合', () {
    test('左右同时按住时水平速度为 0', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowRight));
      expect(input.horizontalAxis, 0, reason: '两个方向必须严格抵消');
      expect(input.moveLeft, isTrue);
      expect(input.moveRight, isTrue);
    });

    test('左右同按后松开一侧，立即恢复另一侧的方向', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowRight));
      expect(input.horizontalAxis, 0);

      input.handleKeyEvent(keyUp(LogicalKeyboardKey.arrowRight));
      expect(input.horizontalAxis, -1);
    });

    test('左右交替按下不会产生位置漂移（轴值只由键集合决定）', () {
      // 左 → 右 → 左：每次都从集合重新推导，而不是累加
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowRight));
      input.handleKeyEvent(keyUp(LogicalKeyboardKey.arrowLeft));
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      expect(input.horizontalAxis, 0);
      expect(input.heldKeys.length, 2);
    });
  });

  group('按键消费', () {
    test('未声明的键不被消费', () {
      expect(
        input.handleKeyEvent(keyDown(LogicalKeyboardKey.keyZ)),
        isFalse,
        reason: '未列出的键必须返回 false，交还引擎',
      );
      expect(input.hasAnyInput, isFalse);
    });

    test('已声明的键被消费', () {
      expect(input.handleKeyEvent(keyDown(LogicalKeyboardKey.keyA)), isTrue);
      expect(input.handleKeyEvent(keyDown(LogicalKeyboardKey.space)), isTrue);
    });

    test('重复事件不会破坏长按状态', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      input.handleKeyEvent(
        KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: const Duration(milliseconds: 100),
        ),
      );
      expect(input.shoot, isTrue, reason: 'KeyRepeatEvent 不得清掉长按状态');
      expect(input.heldKeys, contains(LogicalKeyboardKey.space));
    });

    test('暂停键不是持续动作，也不会被记入 held 集合', () {
      // 暂停是"边沿触发"的开关，由游戏层在 onKeyEvent 里处理，
      // 不能当成按住型动作，否则长按会反复切换。
      expect(InputController.isPauseKey(LogicalKeyboardKey.escape), isTrue);
      expect(InputController.isPauseKey(LogicalKeyboardKey.keyP), isTrue);

      expect(InputController.isActionKey(LogicalKeyboardKey.escape), isFalse);
      expect(InputController.isActionKey(LogicalKeyboardKey.keyP), isFalse);

      expect(input.handleKeyEvent(keyDown(LogicalKeyboardKey.escape)), isFalse);
      expect(input.handleKeyEvent(keyDown(LogicalKeyboardKey.keyP)), isFalse);
      expect(input.hasAnyInput, isFalse);
      expect(input.heldKeys, isEmpty);
    });
  });

  group('T05 清空输入', () {
    test('clear 之后所有动作都停止', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.space));
      expect(input.hasAnyInput, isTrue);

      input.clear();

      expect(input.moveLeft, isFalse);
      expect(input.shoot, isFalse);
      expect(input.horizontalAxis, 0);
      expect(input.hasAnyInput, isFalse);
    });

    test('清空后残留的 key-up 不会抛出异常', () {
      input.handleKeyEvent(keyDown(LogicalKeyboardKey.arrowLeft));
      input.clear();
      expect(
        () => input.handleKeyEvent(keyUp(LogicalKeyboardKey.arrowLeft)),
        returnsNormally,
      );
      expect(input.moveLeft, isFalse);
    });
  });
}
