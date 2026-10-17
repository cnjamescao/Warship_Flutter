// ================================================================
// test/unit/presentation/v21_state_effects_test.dart —— V21-FX-01/03
// ================================================================
// **架构位置**：Presentation 层测试。验证 v2.1 状态动效的**时序模型**
// （冻结表 §5.1）。
//
// **为什么用纯模型测而不是截图**：动效的"帧对不对、几时销毁、并发几个、
// reduceMotion 下怎么缩"都是**可计算的性质**。截图只能看出"某一瞬间长得
// 对不对"，看不出**时序**。而时序错位恰恰是玩家能感觉到、却难以复现的缺陷。
//
// 每条断言都能失败（R6.2）：改错任一帧间隔、销毁时长、并发上限或
// reduceMotion 行为，本文件即失败。
// ================================================================

import 'dart:ui' show BlendMode;

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/v21_state_effects.dart';

void main() {
  test('V21-FX-01 五类动效全部登记，Asset ID 与素材规范一致', () {
    expect(kV21StateEffects.keys.toSet(), <String>{
      'shieldHit', 'hpHit', 'low', 'critical', 'enemyDestroy',
    });
    expect(kV21StateEffects['shieldHit']!.assetId, 'GFX-V21-PLAYER-SHIELD-HIT');
    expect(kV21StateEffects['hpHit']!.assetId, 'GFX-V21-PLAYER-HP-HIT');
    expect(kV21StateEffects['low']!.assetId, 'GFX-V21-PLAYER-LOW');
    expect(kV21StateEffects['critical']!.assetId, 'GFX-V21-PLAYER-CRITICAL');
    expect(kV21StateEffects['enemyDestroy']!.assetId, 'GFX-V21-ENEMY-DESTROY');
  });

  test('V21-FX-01b 帧数与帧间隔与冻结表 §5.1 逐项一致', () {
    // 护盾：4 帧 0/67/134/201ms，267ms 销毁。
    final shield = kV21StateEffects['shieldHit']!;
    expect(shield.frameCount, 4);
    expect(shield.frameOffsetsMs, <int>[0, 67, 134, 201]);
    expect(shield.totalMs, 267);
    expect(shield.loop, isFalse);

    // HP 受击：3 帧 0/100/220ms，320ms。
    final hp = kV21StateEffects['hpHit']!;
    expect(hp.frameOffsetsMs, <int>[0, 100, 220]);
    expect(hp.totalMs, 320);

    // 低血：3 帧 0/300/600ms，1200ms 循环。
    final low = kV21StateEffects['low']!;
    expect(low.frameOffsetsMs, <int>[0, 300, 600]);
    expect(low.totalMs, 1200);
    expect(low.loop, isTrue);

    // 濒危：3 帧 0/200/400ms，800ms 循环。
    final crit = kV21StateEffects['critical']!;
    expect(crit.frameOffsetsMs, <int>[0, 200, 400]);
    expect(crit.totalMs, 800);
    expect(crit.loop, isTrue);

    // 击毁：3 帧 0/140/280ms，420ms。
    final die = kV21StateEffects['enemyDestroy']!;
    expect(die.frameOffsetsMs, <int>[0, 140, 280]);
    expect(die.totalMs, 420);
  });

  test('V21-FX-01c blend 与并发上限与冻结表 §5.1 一致', () {
    expect(kV21StateEffects['shieldHit']!.blendMode, BlendMode.screen);
    expect(kV21StateEffects['hpHit']!.blendMode, BlendMode.plus);
    expect(kV21StateEffects['low']!.blendMode, BlendMode.screen);
    expect(kV21StateEffects['critical']!.blendMode, BlendMode.plus);
    expect(kV21StateEffects['enemyDestroy']!.blendMode, BlendMode.plus);

    expect(kV21StateEffects['shieldHit']!.maxConcurrent, 2);
    expect(kV21StateEffects['hpHit']!.maxConcurrent, 2);
    expect(kV21StateEffects['hpHit']!.mergeWindowMs, 80);
    expect(kV21StateEffects['low']!.maxConcurrent, 1);
    expect(kV21StateEffects['critical']!.maxConcurrent, 1);
    expect(kV21StateEffects['enemyDestroy']!.maxConcurrent, 12);
  });

  test('V21-FX-03 frameAt 逐帧正确且非循环按时销毁', () {
    final die = kV21StateEffects['enemyDestroy']!;
    expect(die.frameAt(-1), -1);
    expect(die.frameAt(0), 0);
    expect(die.frameAt(139), 0);
    expect(die.frameAt(140), 1, reason: '第 2 帧起于 140ms');
    expect(die.frameAt(280), 2);
    expect(die.frameAt(419), 2);
    expect(die.frameAt(420), -1, reason: '420ms 应已销毁');
  });

  test('V21-FX-03b 循环动效按周期取模，永不销毁', () {
    final low = kV21StateEffects['low']!;
    expect(low.frameAt(0), 0);
    expect(low.frameAt(300), 1);
    expect(low.frameAt(600), 2);
    expect(low.frameAt(1199), 2);
    // 一轮结束回到第 0 帧（**不是**销毁）。
    expect(low.frameAt(1200), 0);
    expect(low.frameAt(1500), 1);
  });

  test('V21-FX-03c reduceMotion：受击保留峰值帧 160ms', () {
    for (final id in <String>['shieldHit', 'hpHit', 'enemyDestroy']) {
      final s = kV21StateEffects[id]!;
      expect(s.reduceMotionHoldMs, 160, reason: '$id 峰值帧时长');
      expect(s.reduceMotionFrameAt(0), 1, reason: '$id 应显示峰值帧');
      expect(s.reduceMotionFrameAt(159), 1);
      // 160ms 后不再显示（**状态、碰撞、伤害、时钟完全不变**）。
      expect(s.reduceMotionFrameAt(160), -1, reason: '$id 应在 160ms 后消失');
    }
  });

  test('V21-FX-03d reduceMotion：低血/濒危只闪现第一帧', () {
    final low = kV21StateEffects['low']!;
    // 每 1.2s 仅闪现 120ms。
    expect(low.reduceMotionFlashPeriodMs, 1200);
    expect(low.reduceMotionFlashMs, 120);
    expect(low.reduceMotionFrameAt(0), 0, reason: '闪现期显示第一帧');
    expect(low.reduceMotionFrameAt(119), 0);
    expect(low.reduceMotionFrameAt(120), -1, reason: '闪现结束应隐藏');
    expect(low.reduceMotionFrameAt(1199), -1);
    expect(low.reduceMotionFrameAt(1200), 0, reason: '下一周期再闪现');

    final crit = kV21StateEffects['critical']!;
    expect(crit.reduceMotionFlashPeriodMs, 800);
    expect(crit.reduceMotionFlashMs, 120);
  });

  test('V21-FX-02 击毁动效尺寸按 clamp(radius×4.2, 90, 216)', () {
    expect(enemyDestroySize(0), 90, reason: '下限 90');
    expect(enemyDestroySize(10), 90, reason: '42 → 夹到 90');
    expect(enemyDestroySize(30), 126, reason: '30×4.2 = 126');
    expect(enemyDestroySize(100), 216, reason: '上限 216');
  });
}
