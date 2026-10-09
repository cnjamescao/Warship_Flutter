// ================================================================
// game_config.dart —— 不可变游戏配置
// ================================================================
//
// 规格要求（Warship产品设计.md §3.1）：
//   「所有规则常量置于不可变 GameConfig；不得散落在 update 或组件构造函数中。」
//
// 这里集中了全部"手感数值"与尺寸常量。好处：
//   1. 调参只需改一处；
//   2. 测试可以注入不同的配置（例如验证极端尺寸下的行为）；
//   3. 编译期常量，零运行时开销。
// ================================================================

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show immutable;

/// 全部规则与表现常量。
///
/// 使用 `const GameConfig()` 得到默认配置；
/// 测试或调参时可传入自定义实例。
@immutable
class GameConfig {
  const GameConfig({
    this.logicalWidth = 800,
    this.logicalHeight = 600,
    this.shipWidth = 64,
    this.shipHeight = 48,
    this.alienWidth = 48,
    this.alienHeight = 40,
    this.bulletWidth = 4,
    this.bulletHeight = 12,
    this.shipSpeed = 420,
    this.bulletSpeed = 520,
    this.alienBaseSpeed = 90,
    this.alienSpeedIncrement = 10,
    this.alienDropDistance = 30,
    this.shootCooldown = 0.28,
    this.alienPoints = 50,
    this.initialLives = 3,
    this.shipBottomMargin = 20,
    this.maxStepSeconds = 1 / 20,
    this.worldBackgroundColor = const Color(0xFFE6E6E6),
    this.letterboxColor = const Color(0xFFB0B0B0),
    this.bulletColor = const Color(0xFF000000),
  });

  // ------------------------------------------------------------
  // 逻辑画布
  // ------------------------------------------------------------
  // 规格 §3.2：游戏规则永远在 800×600 logical px 内运行。
  // 真实窗口尺寸只决定显示用的 viewport，不能改变实体坐标或碰撞边界。
  // 因此下面这些尺寸是【常量】，而不是从画布测量的结果。
  // ------------------------------------------------------------
  final double logicalWidth;
  final double logicalHeight;

  // ------------------------------------------------------------
  // 实体尺寸（logical px）
  // ------------------------------------------------------------
  final double shipWidth;
  final double shipHeight;
  final double alienWidth;
  final double alienHeight;
  final double bulletWidth;
  final double bulletHeight;

  // ------------------------------------------------------------
  // 运动与节奏
  // ------------------------------------------------------------
  final double shipSpeed; // 飞船横向速度 px/s
  final double bulletSpeed; // 子弹上升速度 px/s
  final double alienBaseSpeed; // 敌人初始横向速度 px/s
  final double alienSpeedIncrement; // 每清空一波的加速量 px/s
  final double alienDropDistance; // 敌人触边后的下移距离 px
  final double shootCooldown; // 射击冷却 s
  final double alienPoints; // 单个敌人分值
  final int initialLives; // 初始生命
  final double shipBottomMargin; // 飞船距屏幕底部距离 px

  /// 单帧最大模拟步长（秒）。
  ///
  /// 规格 §3.3：帧时间必须被限制，避免系统卡顿、窗口恢复或断点调试后
  /// 出现一个巨大的 dt，导致实体瞬移穿过边界或直接触底掉命。
  /// 1/20 s = 50ms，等价于最低 20fps 的模拟步长。
  final double maxStepSeconds;

  // ------------------------------------------------------------
  // 表现
  // ------------------------------------------------------------
  final Color worldBackgroundColor; // 逻辑画布背景
  final Color letterboxColor; // 逻辑画布之外的留边（viewport 保持比例）
  final Color bulletColor;

  // ------------------------------------------------------------
  // 派生量
  // ------------------------------------------------------------

  /// 飞船水平位置的上界。
  ///
  /// 规格 §5.2 要求"无论尺寸多小，规则边界不得为负数"。
  /// 固定逻辑画布下该值恒为 736，`max` 只是防御性下限：
  /// 即使有人传入一个比飞船还窄的配置，clamp 的上界也不会小于下界
  /// （否则 `double.clamp` 会抛异常）。
  double get shipMaxX {
    final value = logicalWidth - shipWidth;
    return value > 0 ? value : 0;
  }

  /// 飞船初始纵向位置。
  double get shipStartY => logicalHeight - shipHeight - shipBottomMargin;

  /// 舰队横向可用空间内能放下的列数（至少 1 列）。
  ///
  /// 算法与既有实现一致：每个敌人占 2 倍宽度（一个敌人 + 一个间隙）。
  int get fleetColumns {
    final available = logicalWidth - 2 * alienWidth;
    final columns = (available / (2 * alienWidth)).floor();
    return columns < 1 ? 1 : columns;
  }

  /// 舰队纵向可用空间内能放下的行数（至少 1 行）。
  ///
  /// 预留 3 行敌人高度 + 飞船高度 + 飞船底边距，
  /// 保证最下一行敌人不会一开始就贴着飞船。
  int get fleetRows {
    final available =
        logicalHeight - 3 * alienHeight - shipHeight - shipBottomMargin;
    final rows = (available / (2 * alienHeight)).floor();
    return rows < 1 ? 1 : rows;
  }
}
