// ================================================================
// test/unit/game_config_test.dart —— 配置派生量
// ================================================================
// 覆盖规格 §3.1（不可变配置）与 §3.2「无论尺寸多小，规则边界不得为负数」。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/game_config.dart';

void main() {
  group('GameConfig 派生量', () {
    test('默认逻辑画布为 800×600', () {
      const config = GameConfig();
      expect(config.logicalWidth, 800);
      expect(config.logicalHeight, 600);
    });

    test('默认舰队为 7 列 × 5 行（与既有实现一致）', () {
      const config = GameConfig();
      expect(config.fleetColumns, 7);
      expect(config.fleetRows, 5);
      expect(config.fleetColumns * config.fleetRows, 35);
    });

    test('飞船水平上界为 736，且位置在画布内', () {
      const config = GameConfig();
      expect(config.shipMaxX, 800 - 64);
      expect(config.shipStartY, 600 - 48 - 20);
    });

    test('无论如何配置，shipMaxX 都不会为负数', () {
      // 规格 §3.2：固定画布保证边界不为负；这里连"画布比飞船还窄"
      // 的极端配置也一并覆盖，确保 clamp 的上下界永远合法。
      const narrow = GameConfig(logicalWidth: 10, shipWidth: 64);
      expect(narrow.shipMaxX, 0, reason: '上界必须被夹到 0，而不是 -54');

      const exactly = GameConfig(logicalWidth: 64, shipWidth: 64);
      expect(exactly.shipMaxX, 0);
    });

    test('画布小于一个敌人时，舰队仍至少有 1 行 1 列', () {
      const tiny = GameConfig(logicalWidth: 10, logicalHeight: 10);
      expect(tiny.fleetColumns, 1);
      expect(tiny.fleetRows, 1);
    });

    test('所有默认值与规格 §3.1 的参数表一致', () {
      const config = GameConfig();
      expect(config.shipSpeed, 420);
      expect(config.bulletSpeed, 520);
      expect(config.alienBaseSpeed, 90);
      expect(config.alienSpeedIncrement, 10);
      expect(config.alienDropDistance, 30);
      expect(config.shootCooldown, 0.28);
      expect(config.alienPoints, 50);
      expect(config.initialLives, 3);
      expect(config.shipBottomMargin, 20);
      // 规格 §3.3：单帧步长上限推荐 1/20 s
      expect(config.maxStepSeconds, closeTo(0.05, 1e-9));
    });

    test('配置是不可变的（const 构造，字段全 final）', () {
      const config = GameConfig();
      // 这里只需要能通过编译：没有 setter 即证明不可变。
      expect(config.alienWidth, 48);
      expect(config.alienHeight, 40);
      expect(config.bulletWidth, 4);
      expect(config.bulletHeight, 12);
    });
  });
}
