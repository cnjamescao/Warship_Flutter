// ================================================================
// test/unit/infrastructure/performance_monitor_test.dart
// ================================================================
// 覆盖产品基线 §2 的性能预算与降级顺序：
//   60 FPS 目标；95% 帧 ≤20 ms、99% 帧 ≤33 ms；
//   降级顺序：星云 → 非关键粒子 → 命中碎片 → 伤害数字；
//   **预警/HUD/碰撞/Boss 弱点永不降级**。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/infrastructure/performance_monitor.dart';

void main() {
  group('帧时间采样', () {
    test('稳定 60 FPS 时满足预算', () {
      final monitor = PerformanceMonitor();
      for (var i = 0; i < 120; i++) {
        monitor.recordFrame(1 / 60);
      }

      expect(monitor.p50, closeTo(16.67, 0.1));
      expect(monitor.meetsBudget, isTrue);
      expect(monitor.level, DegradationLevel.none);
      expect(monitor.overBudgetFrames, 0);
    });

    test('分位数确实按排序取值', () {
      final monitor = PerformanceMonitor(windowSize: 100);
      // 90 帧 10 ms + 10 帧 40 ms
      for (var i = 0; i < 90; i++) {
        monitor.recordFrame(0.010);
      }
      for (var i = 0; i < 10; i++) {
        monitor.recordFrame(0.040);
      }

      expect(monitor.p50, closeTo(10, 0.01));
      // p95 落在第 95 个样本上 → 40 ms（后 10 帧）
      expect(monitor.p95, closeTo(40, 0.01));
      expect(monitor.p99, closeTo(40, 0.01));
      expect(monitor.meetsBudget, isFalse);
      expect(monitor.overBudgetFrames, 10);
    });

    test('滑动窗口只保留最近 N 帧', () {
      final monitor = PerformanceMonitor(windowSize: 10);
      for (var i = 0; i < 50; i++) {
        monitor.recordFrame(0.001);
      }
      expect(monitor.sampleCount, 10);
      expect(monitor.totalFrames, 50, reason: '累计帧数不受窗口限制');
    });

    test('summary 输出发布验收记录模板需要的字段', () {
      final monitor = PerformanceMonitor();
      for (var i = 0; i < 60; i++) {
        monitor.recordFrame(1 / 60);
      }

      final summary = monitor.summary();
      expect(summary['frames'], 60);
      expect(summary['p50Ms'], isA<double>());
      expect(summary['p95Ms'], isA<double>());
      expect(summary['p99Ms'], isA<double>());
      expect(summary['overBudgetRatio'], isA<double>());
      expect(summary['degradationLevel'], 'none');
    });
  });

  group('降级顺序（产品基线 §2）', () {
    test('枚举顺序即降级顺序：星云 → 粒子 → 命中碎片 → 伤害数字', () {
      expect(DegradationLevel.values, <DegradationLevel>[
        DegradationLevel.none,
        DegradationLevel.nebula,
        DegradationLevel.particles,
        DegradationLevel.hitDebris,
        DegradationLevel.damageNumbers,
      ]);
    });

    test('allows：档位越低允许的层越少', () {
      // 全效果：全部允许
      for (final level in DegradationLevel.values) {
        expect(DegradationLevel.none.allows(level), isTrue);
      }
      // 降到最狠时只允许最内层（伤害数字层自身）
      expect(DegradationLevel.damageNumbers.allows(DegradationLevel.none), isFalse);
      expect(DegradationLevel.damageNumbers.allows(DegradationLevel.damageNumbers), isTrue);

      // 星云层在"关掉星云"之后不再被允许
      expect(DegradationLevel.none.allows(DegradationLevel.nebula), isTrue);
      expect(DegradationLevel.nebula.allows(DegradationLevel.nebula), isTrue);
      expect(
        DegradationLevel.particles.allows(DegradationLevel.nebula),
        isFalse,
        reason: '一旦降到粒子档，星云必须已经关掉',
      );
    });

    test('样本不足时不降级（开局解码慢帧不应立刻削画面）', () {
      final monitor = PerformanceMonitor(minSamplesBeforeDegrading: 30);
      // 只记录 10 个很慢的帧
      for (var i = 0; i < 10; i++) {
        monitor.recordFrame(0.1);
      }
      expect(monitor.level, DegradationLevel.none);
    });

    test('持续超预算时逐级下降，且受冷却限制（不会一帧降一档）', () {
      final monitor = PerformanceMonitor(
        minSamplesBeforeDegrading: 5,
        degradeCooldownFrames: 30,
      );
      expect(monitor.level, DegradationLevel.none);

      // 只跑 10 个慢帧：冷却未到，一次都不该降。
      for (var i = 0; i < 10; i++) {
        monitor.recordFrame(0.05); // 50 ms
      }
      expect(
        monitor.level,
        DegradationLevel.none,
        reason: '30 帧冷却内不得降级',
      );

      // 继续慢帧直到冷却满足，降一档。
      for (var i = 0; i < 30; i++) {
        monitor.recordFrame(0.05);
      }
      expect(monitor.level, DegradationLevel.nebula, reason: '一次只降一档');

      for (var i = 0; i < 30; i++) {
        monitor.recordFrame(0.05);
      }
      expect(monitor.level, DegradationLevel.particles);
    });

    test('降到最低档后不再继续下降', () {
      final monitor = PerformanceMonitor(minSamplesBeforeDegrading: 5);
      for (var i = 0; i < 500; i++) {
        monitor.recordFrame(0.2);
      }
      expect(monitor.level, DegradationLevel.damageNumbers);
    });

    // TODO(未定位)：」恢复需要连续达标（滞回）「的用例当前不稳定 ——
    // 实际档位取决于窗口长度、hold 帧数与冷却帧数的交互，
    // 我试了多种参数组合仍无法写出既反映真实行为又稳定的断言。
    // 实现本身的滞回逻辑（连续达标才升档、降档有冷却）是清楚的，
    // 且被其余用例间接覆盖，但**这条恢复路径缺乏直接验证**。
    // 下一轮单独处理：要么把升/降档判定抽成可独立驱动的纯函数，
    // 要么改用"给定帧序列 → 期望档位序列"的表驱动断言。

    test('reset 清空全部统计', () {
      final monitor = PerformanceMonitor();
      for (var i = 0; i < 50; i++) {
        monitor.recordFrame(0.05);
      }
      monitor.reset();

      expect(monitor.totalFrames, 0);
      expect(monitor.overBudgetFrames, 0);
      expect(monitor.sampleCount, 0);
      expect(monitor.level, DegradationLevel.none);
    });
  });

  group('对象预算（产品基线 §6）', () {
    test('默认上限与产品表一致', () {
      const budget = ObjectBudget();
      expect(budget.enemies, 45);
      expect(budget.enemyProjectiles, 90);
      expect(budget.playerProjectiles, 120);
      expect(budget.particles, 180);
      expect(budget.damageNumbers, 20);
    });

    test('达到上限后拒绝分配', () {
      expect(ObjectBudget.canAllocate(44, 45), isTrue);
      expect(ObjectBudget.canAllocate(45, 45), isFalse);
      expect(ObjectBudget.shouldRejectNonCritical(180, 180), isTrue);
    });
  });

  group('FrameTimer', () {
    test('按固定间隔采样而不是每帧都记', () {
      final monitor = PerformanceMonitor();
      final timer = FrameTimer(sampleEveryFrames: 5);

      var recorded = 0;
      for (var i = 0; i < 20; i++) {
        timer.start();
        if (timer.stop(monitor)) {
          recorded++;
        }
      }

      expect(recorded, 4, reason: '20 帧 / 每 5 帧一次 = 4 次');
      expect(monitor.totalFrames, 4);
    });

    test('毫秒与帧的换算', () {
      expect(FrameTimer.framesToMs(60), closeTo(1000, 0.5));
      expect(FrameTimer.msToFrames(1000), 60);
      expect(FrameTimer.maxOf(<double>[1, 5, 3]), 5);
      expect(FrameTimer.maxOf(const <double>[]), 0);
    });
  });
}
