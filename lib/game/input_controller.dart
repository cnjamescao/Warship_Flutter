// ================================================================
// input_controller.dart —— 键盘输入控制器
// ================================================================
//
// 规格要求（Warship产品设计.md §2.2 输入契约）：
//   * 「输入控制器必须按"当前按下键集合"计算动作，
//      不能让其中一个别名 key-up 覆盖另一个仍按下的键。」
//   * 「左右同时按住时速度为 0。」
//   * 「窗口/Flutter 焦点丢失、进入非 playing、重开和销毁时必须清空全部输入。」
//   * 「未列出的键不得被消费。」
//
// 旧实现的问题是：`A` 与 `←` 共用一个 bool。
// 两个键同时按下后，先松开任意一个就会把动作置为 false，
// 尽管另一个键仍然按着 —— 这就是"别名覆盖"缺陷。
//
// 这里的修法是维护一个【按键集合】，
// 动作则由"集合中是否包含该动作的任一绑定键"实时推导出来。
// ================================================================

import 'package:flutter/services.dart';

/// 抽象动作，与具体按键解耦。
enum GameAction { moveLeft, moveRight, shoot }

/// 把物理按键翻译成游戏动作。
class InputController {
  /// 左移的绑定键（任一按下即左移）。
  ///
  /// 注意：`LogicalKeyboardKey` 重写了 `==` / `hashCode`，
  /// 因此不能放进 `const` 集合（编译错误 const_set_element_not_primitive_equality），
  /// 这里使用 `static final` + 不可修改视图。
  static final Set<LogicalKeyboardKey> leftKeys =
      Set<LogicalKeyboardKey>.unmodifiable(<LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.keyA,
      ]);

  /// 右移的绑定键。
  static final Set<LogicalKeyboardKey> rightKeys =
      Set<LogicalKeyboardKey>.unmodifiable(<LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.keyD,
      ]);

  /// 射击的绑定键。
  static final Set<LogicalKeyboardKey> shootKeys =
      Set<LogicalKeyboardKey>.unmodifiable(<LogicalKeyboardKey>[
        LogicalKeyboardKey.space,
      ]);

  /// 暂停 / 恢复的绑定键。
  ///
  /// 注意：暂停**不**放进 [isActionKey]。
  /// 它不是"按住持续生效"的动作，而是"按下瞬间切换一次"的**边沿事件**；
  /// 如果把它当成 held 状态，长按就会疯狂来回切换。
  /// 因此边沿由游戏层在 `onKeyEvent` 中处理，本控制器只负责声明绑定关系。
  static final Set<LogicalKeyboardKey> pauseKeys =
      Set<LogicalKeyboardKey>.unmodifiable(<LogicalKeyboardKey>[
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.keyP,
      ]);

  /// 该键是否为暂停键。
  static bool isPauseKey(LogicalKeyboardKey key) => pauseKeys.contains(key);

  /// 当前真正处于按下状态的键（按【单个键】记录，而不是按动作记录）。
  final Set<LogicalKeyboardKey> _held = <LogicalKeyboardKey>{};

  /// 当前按下的键（只读快照，主要用于测试与调试）。
  Set<LogicalKeyboardKey> get heldKeys => Set<LogicalKeyboardKey>.unmodifiable(_held);

  // ------------------------------------------------------------
  // 动作状态：每次读取都从键集合重新推导
  // ------------------------------------------------------------
  bool get moveLeft => _held.any(leftKeys.contains);
  bool get moveRight => _held.any(rightKeys.contains);
  bool get shoot => _held.any(shootKeys.contains);

  /// 水平输入：-1 向左，+1 向右，**同时按住时为 0**。
  ///
  /// 用"相减"而不是"两次赋值"，保证左右同按时位移严格为 0，
  /// 不会因为帧内处理顺序产生位置漂移。
  double get horizontalAxis =>
      (moveRight ? 1.0 : 0.0) - (moveLeft ? 1.0 : 0.0);

  bool get hasAnyInput => _held.isNotEmpty;

  /// 该键是否属于已声明的动作。
  static bool isActionKey(LogicalKeyboardKey key) =>
      leftKeys.contains(key) || rightKeys.contains(key) || shootKeys.contains(key);

  /// 处理一个键盘事件。
  ///
  /// 返回 `true` 表示事件已被本控制器消费（调用方应回 `KeyEventResult.handled`）；
  /// 返回 `false` 表示这不是我们关心的键，应放行给引擎
  /// （规格：未列出的键不得被消费）。
  bool handleKeyEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (!isActionKey(key)) {
      return false;
    }
    if (event is KeyDownEvent) {
      _held.add(key);
    } else if (event is KeyUpEvent) {
      _held.remove(key);
    }
    // KeyRepeatEvent 不需要处理：键本来就已经在按下集合里，
    // 如果在这里做任何"添加"或"移除"，都会破坏长按状态。
    return true;
  }

  /// 清空全部输入状态。
  ///
  /// 必须在以下时机调用，否则会出现"粘键"：
  ///   * 窗口 / Flutter 焦点丢失（用户切走时可能收不到 KeyUpEvent）；
  ///   * 进入 menu / gameOver；
  ///   * 重开一局；
  ///   * 游戏销毁。
  void clear() => _held.clear();
}
