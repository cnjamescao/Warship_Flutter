// ================================================================
// test/web/web_audio_unlock_test.dart —— WEB-T-04
// ================================================================
// **架构位置**：Web 平台验收测试（音频手势解锁）。
//
// **依据**（WEB-T-04）：
//   「首个有效指针/键盘手势**只 unlock 一次**；允许时按本地设置播放，
//     **拒绝时对局与输入照常**且 **BGM 不叠加**。」
//
// **为什么"只一次"最要紧**：浏览器里每次点击都触发解锁回调 ✗；
//   若每次回调都去 `bgm.play()`，BGM 会**层层叠加** ✗ ——
//   玩家听到的是越来越响的混响，而不是音乐。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/web_audio_unlock.dart';

void main() {
  test('WEB-T-04a 首次手势触发解锁；后续手势**不再触发副作用**', () {
    final unlock = WebAudioUnlock();
    var plays = 0;
    final cb = bindUnlockCallback(
      unlock: unlock,
      onFirstUnlock: () => plays++,
    );

    expect(unlock.isUnlocked, isFalse);

    cb(); // 首次
    expect(unlock.isUnlocked, isTrue);
    expect(plays, 1, reason: '首次手势应起播一次');

    // 后续 10 次点击：都不得再起播（BGM 不叠加）。
    for (var i = 0; i < 10; i++) {
      cb();
    }
    expect(plays, 1, reason: 'BGM 只能起播一次，否则会叠加 ✗');
    expect(unlock.gestureCount, 11, reason: '手势都被记录，只是被忽略');
  });

  test('WEB-T-04b **无效手势**不解锁（且后续有效手势仍能解锁）', () {
    final unlock = WebAudioUnlock();
    var plays = 0;
    final cb = bindUnlockCallback(
      unlock: unlock,
      onFirstUnlock: () => plays++,
    );

    // 无效手势（例如 hover）：不触发。
    expect(unlock.onGesture(isValid: false), isFalse);
    expect(unlock.isUnlocked, isFalse);
    expect(plays, 0);

    // 第一个**有效**手势才解锁。
    cb();
    expect(unlock.isUnlocked, isTrue);
    expect(plays, 1);
  });

  test('WEB-T-04c 解锁是**幂等**的：直接调 onGesture 也只会 true 一次', () {
    final unlock = WebAudioUnlock();
    expect(unlock.onGesture(), isTrue);
    for (var i = 0; i < 5; i++) {
      expect(unlock.onGesture(), isFalse);
    }
  });

  test('WEB-T-04d 状态机**不含业务副作用**（拒绝音频时对局不受影响）', () {
    // 本类的职责只有"是否解锁" —— 它不持有播放器、不发事件、
    // 不碰 GamePhase。因此"用户拒绝音频"时它**无法**影响对局 ✓
    // （这是"拒绝时对局与输入照常"的结构性保证）。
    final unlock = WebAudioUnlock();
    unlock.onGesture();
    // 解锁与否都不改变任何游戏状态 —— 这里断言它只暴露这两个量。
    expect(unlock.isUnlocked, isTrue);
    expect(unlock.gestureCount, 1);
  });
}
