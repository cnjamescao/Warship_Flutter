// ================================================================
// test/unit/presentation/viewport_alignment_test.dart —— F-27（P0）
// ================================================================
// 玩家实测（三条观察锁死了根因）：
//   1. 画布左上角在**屏幕中心** → 开局看不到飞船，要往上走才出现；
//   2. 最多只能向左移动到**屏幕中线** → 世界左边界映射到了屏幕中心；
//   3. 顶部 HUD 也不靠顶。
//
// 根因：`CameraComponent.withFixedResolution` 用的是默认 `Viewfinder()`，
// 而 Flame 的 `Viewfinder.position` 语义是「**被放到屏幕中心**的那个
// 世界坐标」，默认值 `Vector2.zero()` —— 世界原点因此落在屏幕中心。
//
// 说明：本文件**不驱动 `onLoad`**。`onLoad` 会 `add(camera)` 并需要
// 完整游戏循环，在 widget 测试里会挂住（我试过：跑满 10 分钟超时）。
// 因此把"取景器该瞄准哪里"抽成纯函数来测 —— 这既能守住不变量，
// 又不会留下一个会挂的用例。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/warship_v2_game.dart';

void main() {
  test('F-27 取景器瞄准逻辑世界中心，视口正好覆盖 (0,0)..(1920,1080)', () {
    final center = viewfinderCenterForWorld();

    expect(center.x, kLogicalWidth / 2);
    expect(center.y, kLogicalHeight / 2);

    // 世界原点在屏幕上的位置 = 取景器位置 - 视口尺寸/2。
    // 视口尺寸等于逻辑世界尺寸（FixedResolutionViewport），
    // 因此这个值必须是 (0,0) —— 否则就会重现玩家看到的错位。
    final originOnScreenX = center.x - kLogicalWidth / 2;
    final originOnScreenY = center.y - kLogicalHeight / 2;
    expect(
      originOnScreenX,
      closeTo(0, 0.001),
      reason: '世界原点必须映射到屏幕左上角 —— 否则开局看不到飞船，'
          '且"最多只能移动到屏幕中线"（F-27 的现场表现）',
    );
    expect(originOnScreenY, closeTo(0, 0.001));

    // 玩家出生点必须落在视口内。
    expect(center.x, greaterThan(0));
    expect(center.x, lessThan(kLogicalWidth));
  });
}
