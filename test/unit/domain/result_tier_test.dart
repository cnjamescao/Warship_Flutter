// ================================================================
// test/unit/domain/result_tier_test.dart —— 结算奖牌算法
// ================================================================
// 覆盖一处**已裁决的文档冲突**（产品基线 §8 vs 技术协议 §3.1），
// 裁决依据是交付清单 §8 的优先级：产品基线 → 技术协议 → …
// 完整裁决记录见 lib/game/domain/result_tier.dart 文件头。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/domain/result_tier.dart';

void main() {
  group('胜利', () {
    test('胜利一律 gold（与两份文档一致）', () {
      for (final ratio in <double?>[null, 1.0, 0.5, 0.34, 0.0]) {
        expect(
          resultTierFor(victory: true, bossHpRatio: ratio),
          ResultTier.gold,
          reason: 'bossHpRatio=$ratio 时胜利仍应为 gold',
        );
      }
    });
  });

  group('失败', () {
    test('曾把 Boss 打进 P3（<0.35）为 silver', () {
      for (final ratio in <double>[0.34, 0.2, 0.05, 0.0]) {
        expect(
          resultTierFor(victory: false, bossHpRatio: ratio),
          ResultTier.silver,
          reason: 'bossHpRatio=$ratio 应判 silver',
        );
      }
    });

    test('Boss 仍在 P3 之前（>=0.35）为 bronze', () {
      for (final ratio in <double>[0.35, 0.5, 0.7, 1.0]) {
        expect(
          resultTierFor(victory: false, bossHpRatio: ratio),
          ResultTier.bronze,
          reason: 'bossHpRatio=$ratio 应判 bronze',
        );
      }
    });

    test('Boss 尚未出现（null）为 bronze，不是 none', () {
      expect(
        resultTierFor(victory: false, bossHpRatio: null),
        ResultTier.bronze,
        reason: '产品基线 §8 规定「其余为 Bronze」，铜牌是兜底',
      );
    });

    test('阈值边界 0.35 归 bronze（严格小于才算进 P3）', () {
      expect(
        resultTierFor(victory: false, bossHpRatio: 0.35),
        ResultTier.bronze,
      );
      expect(
        resultTierFor(victory: false, bossHpRatio: 0.3499999),
        ResultTier.silver,
      );
    });

    test('**不产生 none**（产品基线优先于技术协议的结果）', () {
      // 技术协议 §3.1 对「失败且存活 <120 秒」给 none；
      // 产品基线 §8 说「其余为 Bronze」。按交付清单 §8，产品基线优先。
      final produced = <ResultTier>{};
      for (var i = 0; i <= 100; i++) {
        produced.add(
          resultTierFor(victory: false, bossHpRatio: i / 100),
        );
      }
      expect(produced, isNot(contains(ResultTier.none)));
      expect(produced, <ResultTier>{ResultTier.bronze, ResultTier.silver});
    });
  });

  group('契约', () {
    test('ResultTier 的取值与素材声明的 4 个状态一一对应', () {
      expect(
        ResultTier.values.map((t) => t.id).toSet(),
        <String>{'gold', 'silver', 'bronze', 'none'},
        reason: 'UI-RESULT-MEDAL 声明的状态是 bronze/silver/gold/none',
      );
    });

    test('是纯函数：同样入参必然同样出参（协议要求重放可复现）', () {
      for (var i = 0; i <= 50; i++) {
        final ratio = i / 50;
        expect(
          resultTierFor(victory: false, bossHpRatio: ratio),
          resultTierFor(victory: false, bossHpRatio: ratio),
        );
      }
    });
  });
}
