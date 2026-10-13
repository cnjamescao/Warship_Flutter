// ================================================================
// lib/game/presentation/input_gateway.dart —— 输入 → InputFrame
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §2.1
//   `InputGateway`：键鼠/触摸/焦点事件 → `InputFrame`；
//   **不保留已失焦按键**。
//
// 产品基线 §4.1 的跨平台映射：
//   移动  WASD / 方向键（触摸为拖动）
//   冲刺  Space 或 Shift
//   暂停  Esc
//   选卡  1 / 2 / 3
// ================================================================

import 'package:flutter/services.dart';

import '../core/input_frame.dart';
import '../domain/values.dart';

/// 键盘输入网关。
///
/// 用**按键集合**而不是布尔状态：同时按多个方向键时不会互相覆盖，
/// 松掉其中一个仍能继续沿另一个方向移动。
class KeyboardInputGateway {
  final Set<LogicalKeyboardKey> _pressed = <LogicalKeyboardKey>{};

  /// 本帧是否请求了一次冲刺（边沿触发，读取后清零）。
  bool _dashEdge = false;

  /// 本帧是否请求了暂停。
  bool _pauseEdge = false;

  int? _cardSelection;

  Set<LogicalKeyboardKey> get pressedKeys =>
      Set<LogicalKeyboardKey>.unmodifiable(_pressed);

  bool get hasPressedKeys => _pressed.isNotEmpty;

  /// 处理一次按键按下。返回 true 表示该键被游戏消费。
  bool onKeyDown(LogicalKeyboardKey key) {
    final wasPressed = _pressed.contains(key);
    _pressed.add(key);

    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) {
      if (!wasPressed) {
        _dashEdge = true;
      }
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (!wasPressed) {
        _pauseEdge = true;
      }
      return true;
    }
    if (key == LogicalKeyboardKey.digit1) {
      _cardSelection = 0;
      return true;
    }
    if (key == LogicalKeyboardKey.digit2) {
      _cardSelection = 1;
      return true;
    }
    if (key == LogicalKeyboardKey.digit3) {
      _cardSelection = 2;
      return true;
    }
    return isMovementKey(key);
  }

  void onKeyUp(LogicalKeyboardKey key) {
    _pressed.remove(key);
  }

  /// 失焦时清空全部按键。
  ///
  /// 技术架构 §3.2：「GameScreen.dispose 负责…清空输入」。
  /// 不清空的话，玩家切回窗口时战机会一直朝一个方向飘。
  void clear() {
    _pressed.clear();
    _dashEdge = false;
    _pauseEdge = false;
    _cardSelection = null;
  }

  static bool isMovementKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.keyW ||
      key == LogicalKeyboardKey.keyA ||
      key == LogicalKeyboardKey.keyS ||
      key == LogicalKeyboardKey.keyD ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight;

  /// 取出并消费本帧的输入快照。
  InputFrame consume({
    Vec2? touchTarget,
    Vec2? selfPosition,
    double? touchMaxDistance,
  }) {
    var direction = _keyboardDirection();

    // 触摸拖动优先于键盘（移动端没有键盘）。
    if (touchTarget != null && selfPosition != null) {
      final delta = touchTarget - selfPosition;
      final reach = touchMaxDistance ?? 1.0;
      if (delta.length > reach * 0.08) {
        direction = delta;
      } else {
        direction = Vec2.zero;
      }
    }

    final frame = InputFrame(
      moveDirection: direction,
      dashRequested: _dashEdge,
      pauseRequested: _pauseEdge,
      cardSelection: _cardSelection,
    );
    _dashEdge = false;
    _pauseEdge = false;
    _cardSelection = null;
    return frame;
  }

  Vec2 _keyboardDirection() {
    var x = 0.0;
    var y = 0.0;
    if (_pressed.contains(LogicalKeyboardKey.keyA) ||
        _pressed.contains(LogicalKeyboardKey.arrowLeft)) {
      x -= 1;
    }
    if (_pressed.contains(LogicalKeyboardKey.keyD) ||
        _pressed.contains(LogicalKeyboardKey.arrowRight)) {
      x += 1;
    }
    if (_pressed.contains(LogicalKeyboardKey.keyW) ||
        _pressed.contains(LogicalKeyboardKey.arrowUp)) {
      y -= 1; // 逻辑世界 Y 轴向下
    }
    if (_pressed.contains(LogicalKeyboardKey.keyS) ||
        _pressed.contains(LogicalKeyboardKey.arrowDown)) {
      y += 1;
    }
    if (x == 0 && y == 0) {
      return Vec2.zero;
    }
    return Vec2(x, y);
  }
}
