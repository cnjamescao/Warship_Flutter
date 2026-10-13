// ================================================================
// test/unit/core/game_clock_test.dart —— 固定步进时钟
// ================================================================
// 覆盖：Spec/02_技术/v2.0/04_测试计划与验收用例.md 的 T-CORE-03
//   「渲染 dt=500 ms → 最多 3 步逻辑、无穿墙/多次伤害，记录性能告警」
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/game_clock.dart';

void main() {
  group('固定步长', () {
    test('恰好一帧的渲染 dt 只跑一步', () {
      final clock = GameClock();
      expect(clock.accumulate(GameClock.fixedStepSeconds), 1);
      clock.consumeStep();
      expect(clock.frameIndex, 1);
      expect(clock.elapsedSeconds, closeTo(GameClock.fixedStepSeconds, 1e-9));
    });

    test('不足一步的余量会累积到下一帧', () {
      final clock = GameClock();
      final half = GameClock.fixedStepSeconds / 2;
      expect(clock.accumulate(half), 0);
      expect(clock.accumulate(half), 1);
      expect(clock.pendingAccumulatorSeconds, closeTo(0, 1e-9));
    });

    test('两倍步长在一帧内跑两步', () {
      final clock = GameClock();
      expect(clock.accumulate(GameClock.fixedStepSeconds * 2), 2);
    });
  });

  group('T-CORE-03 巨帧保护', () {
    test('dt=500ms 被 clamp 到 50ms，因此最多 3 步', () {
      final clock = GameClock();
      final steps = clock.accumulate(0.5);
      expect(
        steps,
        GameClock.maxStepsPerRenderFrame,
        reason: '0.5s 必须先被 clamp 到 0.05s（=3 步），不得追算 30 步',
      );
    });

    test('clamp 生效时记录性能告警（这是真正的监控指标）', () {
      final clock = GameClock();

      clock.accumulate(0.016); // 正常帧
      expect(clock.clampedRenderFrameCount, 0);

      clock.accumulate(0.5); // 巨帧
      expect(clock.clampedRenderFrameCount, 1);

      clock.accumulate(0.05); // 刚好等于上限，不算超预算
      expect(clock.clampedRenderFrameCount, 1);
    });

    test('因为 50ms 恰好是 3 步，兜底的丢步计数器不会触发', () {
      // 这条断言把"两层保护的分工"固定下来：
      // clamp 是实际生效的那道，步数上限只是兜底。
      // 如果将来有人调大 clamp 或调小步长，这条会失败并提醒他复核。
      final clock = GameClock();
      clock.accumulate(10.0);

      expect(clock.droppedStepCount, 0);
      expect(
        GameClock.maxRenderDeltaSeconds,
        closeTo(GameClock.fixedStepSeconds * GameClock.maxStepsPerRenderFrame, 1e-12),
        reason: '50ms clamp 必须恰好等于 3 个逻辑步，两层保护才是自洽的',
      );
    });

    test('连续巨帧不会累积出无限步数', () {
      final clock = GameClock();
      var totalSteps = 0;
      for (var i = 0; i < 100; i++) {
        totalSteps += clock.accumulate(5.0);
      }
      expect(
        totalSteps,
        100 * GameClock.maxStepsPerRenderFrame,
        reason: '每帧都被 clamp+限步，绝不追算',
      );
      expect(clock.clampedRenderFrameCount, 100, reason: '100 帧全部超预算');
    });
  });

  group('帧号与逻辑时间', () {
    test('advanceAndRun 逐步推进帧号并回调', () {
      final clock = GameClock();
      final visited = <int>[];
      final steps = clock.advanceAndRun(
        GameClock.fixedStepSeconds * 3,
        visited.add,
      );

      expect(steps, 3);
      expect(visited, <int>[1, 2, 3]);
      expect(clock.elapsedSeconds, closeTo(3 * GameClock.fixedStepSeconds, 1e-9));
    });

    test('非正 dt 不推进', () {
      final clock = GameClock();
      expect(clock.accumulate(0), 0);
      expect(clock.accumulate(-1), 0);
      expect(clock.frameIndex, 0);
    });

    test('reset 回到开局状态', () {
      final clock = GameClock();
      clock.advanceAndRun(1.0, (_) {});
      expect(clock.frameIndex, greaterThan(0));

      clock.reset();

      expect(clock.frameIndex, 0);
      expect(clock.elapsedSeconds, 0);
      expect(clock.droppedStepCount, 0);
      expect(clock.pendingAccumulatorSeconds, 0);
    });
  });

  group('契约常量', () {
    test('逻辑步长为 1/60 秒、最大补偿 50ms、单帧最多 3 步', () {
      expect(GameClock.fixedStepSeconds, closeTo(1 / 60, 1e-12));
      expect(GameClock.maxRenderDeltaSeconds, closeTo(0.05, 1e-12));
      expect(GameClock.maxStepsPerRenderFrame, 3);
    });
  });
}
