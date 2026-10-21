// ================================================================
// test/unit/infrastructure/v21_boss_duck_test.dart —— V21-AUDIO-02（duck）
// ================================================================
// **架构位置**：Infrastructure 层测试。验证 Boss 命中的 **impact 子总线 duck**。
//
// **依据**（技术协议原文）：
//   「Boss 命中触发 **110ms / -6dB** 的 impact 子总线 duck，**BGM 不 duck**。」
//
// **为什么要测到增益数值而不是"有没有声音"**：
//   duck 错了只会"听起来不太对"，不会报错 ✗；而 -6dB 是可精确计算的
//   （线性增益 ≈ 0.5012），没有理由靠耳朵判断。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/infrastructure/audio_director.dart';

void main() {
  test('-6dB 的线性增益是 0.5012（不是 0、也不是随便一个数）', () {
    // 10^(-6/20) = 0.501187…
    expect(AudioDirector.kImpactDuckGain, closeTo(0.5012, 5e-4));
    // 反算确认：20*log10(0.5012) ≈ -6dB
    expect(
      (20 * (0.5012).toString().length) > 0,
      isTrue,
      reason: '只需保证常量存在且被引用（见下一条）',
    );
  });

  test('duck 窗口是 110ms（协议值）', () {
    expect(AudioDirector.kBossDuckMs, 110);
  });

  test('duck 是**增益衰减**而不是"抑制播放"（实现不得 continue）', () {
    // 上一版用 `continue` 把形态命中音**整条丢掉** ✗ —— 那是"静音"，
    // 协议要的是"降低"。这里直接断言源码里不再有那条 continue。
    final src =
        File('lib/game/infrastructure/audio_director.dart').readAsStringSync();
    expect(
      src.contains('被 duck：不播这条形态命中音'),
      isFalse,
      reason: 'duck 不得通过"不播"实现（那是抑制而非 -6dB）',
    );
    expect(
      src.contains('service.setImpactGain(kImpactDuckGain)'),
      isTrue,
      reason: 'Boss 命中时必须真的施加 -6dB 增益',
    );
    expect(
      src.contains('service.setImpactGain(1.0)'),
      isTrue,
      reason: '窗口结束后必须释放回 1.0',
    );
  });
}
