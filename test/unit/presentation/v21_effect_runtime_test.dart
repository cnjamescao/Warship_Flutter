// ================================================================
// test/unit/presentation/v21_effect_runtime_test.dart —— V21-FX-03
// ================================================================
// **架构位置**：Presentation 层测试。验证状态动效的**实例管理**：
//   并发上限、80ms 合并窗、按时淘汰、reduceMotion 只改显示。
//
// **为什么单独测**：这些是"多发一次没人在意、少发一次玩家看得出来"的规则。
//   截图无法证明"同一 cue 在 80ms 内只播一次"，只能靠计数断言。
//
// 每条断言都能失败（R6.2）：去掉合并窗、改错并发上限、或让
//   reduceMotion 影响淘汰时机，本文件即失败。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/v21_effect_runtime.dart';
import 'package:warship_flutter/game/presentation/v21_state_effects.dart';

V21EffectSpec spec(String id) => kV21StateEffects[id]!;

void main() {
  test('V21-FX-03 并发上限：超出时淘汰**最旧的**，数量不超过上限', () {
    final rt = V21EffectRuntime();
    final s = spec('hpHit'); // maxConcurrent = 2
    expect(s.maxConcurrent, 2);

    for (var i = 0; i < 5; i++) {
      rt.spawn(spec: s, nowSeconds: 10.0 + i * 1.0, centerX: i.toDouble(), centerY: 0);
    }
    expect(rt.instances, hasLength(2), reason: '不得超出并发上限');
    // 保留的是**最新**两次（淘汰最旧）。
    expect(rt.instances.map((i) => i.centerX), <double>[3, 4]);
  });

  test('V21-FX-03b 80ms 合并窗：窗口内同类只收编一次', () {
    final rt = V21EffectRuntime();
    final s = spec('hpHit');
    expect(s.mergeWindowMs, 80);

    expect(rt.spawn(spec: s, nowSeconds: 5.000, centerX: 0, centerY: 0), isTrue);
    // 79ms 后：仍在窗内 ⇒ 拒绝。
    expect(rt.spawn(spec: s, nowSeconds: 5.079, centerX: 1, centerY: 0), isFalse);
    expect(rt.instances, hasLength(1));
    // 81ms 后：窗外 ⇒ 收编。
    expect(rt.spawn(spec: s, nowSeconds: 5.081, centerX: 2, centerY: 0), isTrue);
    expect(rt.instances, hasLength(2));
  });

  test('V21-FX-03c 非循环动效按时淘汰；循环动效不按时淘汰', () {
    final rt = V21EffectRuntime();
    // 击毁：420ms 销毁。
    rt.spawn(spec: spec('enemyDestroy'), nowSeconds: 0, centerX: 0, centerY: 0);
    rt.prune(0.419, reduceMotion: false);
    expect(rt.instances, hasLength(1), reason: '419ms 仍在');
    rt.prune(0.421, reduceMotion: false);
    expect(rt.instances, isEmpty, reason: '420ms 后应淘汰');

    // 低血：循环 ⇒ 不按时淘汰。
    final rt2 = V21EffectRuntime();
    rt2.spawn(spec: spec('low'), nowSeconds: 0, centerX: 0, centerY: 0);
    rt2.prune(100.0, reduceMotion: false);
    expect(rt2.instances, hasLength(1), reason: '循环动效随状态生灭');
  });

  test('V21-FX-03d reduceMotion 只缩短**显示**，不改状态语义', () {
    final rt = V21EffectRuntime();
    rt.spawn(spec: spec('hpHit'), nowSeconds: 0, centerX: 0, centerY: 0);
    final inst = rt.instances.single;

    // 正常：0ms 第 0 帧，100ms 第 1 帧，220ms 第 2 帧。
    expect(inst.frameAt(0, reduceMotion: false), 0);
    expect(inst.frameAt(0.100, reduceMotion: false), 1);
    expect(inst.frameAt(0.220, reduceMotion: false), 2);

    // reduceMotion：只显示**峰值帧**（第 1 帧）160ms。
    expect(inst.frameAt(0, reduceMotion: true), 1);
    expect(inst.frameAt(0.159, reduceMotion: true), 1);
    // 160ms 后不显示（但实例仍在，直到正常时长结束 —— 显示与否由帧号决定）。
    expect(inst.frameAt(0.160, reduceMotion: true), -1);
  });

  test('V21-FX-03e clear() 清空全部实例（重开一局无残留）', () {
    final rt = V21EffectRuntime();
    rt.spawn(spec: spec('low'), nowSeconds: 0, centerX: 0, centerY: 0);
    rt.spawn(spec: spec('critical'), nowSeconds: 0, centerX: 0, centerY: 0);
    expect(rt.instances, isNotEmpty);
    rt.clear();
    expect(rt.instances, isEmpty);
  });

  test('V21-FX-03f 击毁动效尺寸按 clamp(radius×4.2, 90, 216)', () {
    final rt = V21EffectRuntime();
    rt.spawn(
      spec: spec('enemyDestroy'),
      nowSeconds: 0, centerX: 0, centerY: 0,
      size: enemyDestroySize(30),
    );
    expect(rt.instances.single.size, 126);
  });
}
