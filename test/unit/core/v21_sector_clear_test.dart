// ================================================================
// test/unit/core/v21_sector_clear_test.dart —— V21-CLEAR-01
// ================================================================
// **架构位置**：Core 层测试。验证 v2.1 清场胜利的**四条件**
// （技术协议 §3.2、蓝图 §4.1）。
//
// **为什么必须逐条件测**：清场是 v2.1 新增的**第二条胜利路径**。
// 任一条件漏判都会造成"提前胜利"（例如 Boss 还没来就判清场），
// 而这类缺陷**不会报错**，只会让玩家莫名其妙地赢。
//
// 每条断言都能失败（R6.2）：去掉任一条件，对应用例即失败。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/game_runtime.dart';

/// 构造一个**四条件全部满足**的快照；各用例只破坏一个维度。
ThreatSnapshot cleared({
  bool directorCompleted = true,
  bool hasFutureBossPlan = false,
  int enemyCount = 0,
  int enemyProjectileCount = 0,
  int hazardCount = 0,
  int pendingAttackCount = 0,
  bool bossAlive = false,
}) => ThreatSnapshot(
  directorCompleted: directorCompleted,
  hasFutureBossPlan: hasFutureBossPlan,
  enemyCount: enemyCount,
  enemyProjectileCount: enemyProjectileCount,
  hazardCount: hazardCount,
  pendingAttackCount: pendingAttackCount,
  bossAlive: bossAlive,
);

void main() {
  test('V21-CLEAR-01 四条件全满足 → 判为清场', () {
    expect(cleared().isEmpty, isTrue);
  });

  group('V21-CLEAR-02 任一条件不满足都必须**不**判清场', () {
    test('Director 未跑完', () {
      expect(cleared(directorCompleted: false).isEmpty, isFalse);
    });

    test('还有未来的 Boss 行（关键：否则会在 Boss 出现前获胜）', () {
      expect(cleared(hasFutureBossPlan: true).isEmpty, isFalse);
    });

    test('场上仍有敌人', () {
      expect(cleared(enemyCount: 1).isEmpty, isFalse);
    });

    test('仍有敌弹', () {
      expect(cleared(enemyProjectileCount: 1).isEmpty, isFalse);
    });

    test('仍有危险区', () {
      expect(cleared(hazardCount: 1).isEmpty, isFalse);
    });

    test('仍有待执行攻击（预警已发出但未到期）', () {
      expect(cleared(pendingAttackCount: 1).isEmpty, isFalse);
    });

    test('Boss 仍存活', () {
      expect(cleared(bossAlive: true).isEmpty, isFalse);
    });
  });

  test('V21-CLEAR-03 四条件的关系是**与**，不是或', () {
    // 只有一项满足时绝不清场。
    for (final s in <ThreatSnapshot>[
      cleared(directorCompleted: false, hasFutureBossPlan: true),
      cleared(enemyCount: 3, bossAlive: true),
      cleared(hazardCount: 2, pendingAttackCount: 1),
    ]) {
      expect(s.isEmpty, isFalse, reason: s.toString());
    }
  });

  test('V21-CLEAR-04 失败时快照可读（诊断信息完整）', () {
    // 清场判定的失败必须能说明"卡在哪个条件上"。
    final s = cleared(enemyCount: 2, pendingAttackCount: 1);
    expect(s.toString(), contains('enemies=2'));
    expect(s.toString(), contains('pending=1'));
  });
}
