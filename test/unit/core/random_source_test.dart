// ================================================================
// test/unit/core/random_source_test.dart —— 确定性随机源
// ================================================================
// 覆盖：Spec/02_技术/v2.0/04_测试计划与验收用例.md 的 T-CORE-04
//   「同一 seed + 同一输入序列重放两次，结果完全相同」
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/random_source.dart';

void main() {
  group('PCG32 确定性', () {
    test('同一 seed 产生完全相同的序列', () {
      List<int> draw(int seed) {
        final rng = Pcg32(seed);
        return List<int>.generate(16, (_) => rng.nextUint32());
      }

      expect(draw(0x4E454F4E0001), draw(0x4E454F4E0001));
    });

    test('不同 seed 产生不同序列', () {
      final a = Pcg32(1);
      final b = Pcg32(2);
      final seqA = List<int>.generate(8, (_) => a.nextUint32());
      final seqB = List<int>.generate(8, (_) => b.nextUint32());

      expect(seqA, isNot(seqB));
    });

    test('输出为 32 位无符号整数', () {
      final rng = Pcg32(12345);
      for (var i = 0; i < 500; i++) {
        final value = rng.nextUint32();
        expect(value, greaterThanOrEqualTo(0));
        expect(value, lessThan(0x100000000));
      }
    });

    test('算法名与 seed 可用于写入 RunStarted', () {
      final rng = Pcg32(0x4E454F4E0001);
      expect(rng.algorithm, 'pcg32-xsh-rr');
      expect(rng.seed, 0x4E454F4E0001);
    });

    test('nextDouble 落在 [0,1)', () {
      final rng = Pcg32(999);
      for (var i = 0; i < 500; i++) {
        final value = rng.nextDouble();
        expect(value, greaterThanOrEqualTo(0));
        expect(value, lessThan(1));
      }
    });

    test('nextInt 落在 [0,max)', () {
      final rng = Pcg32(7);
      for (var i = 0; i < 500; i++) {
        final value = rng.nextInt(6);
        expect(value, inInclusiveRange(0, 5));
      }
    });

    test('nextIntInRange 落在闭区间内', () {
      final rng = Pcg32(7);
      for (var i = 0; i < 500; i++) {
        expect(rng.nextIntInRange(3, 9), inInclusiveRange(3, 9));
      }
    });

    test('nextDoubleInRange 落在 [min,max)', () {
      final rng = Pcg32(7);
      for (var i = 0; i < 500; i++) {
        final value = rng.nextDoubleInRange(2.0, 5.0);
        expect(value, greaterThanOrEqualTo(2.0));
        expect(value, lessThan(5.0));
      }
    });
  });

  group('ScriptedRandomSource（测试夹具）', () {
    test('按脚本顺序返回值并循环', () {
      final rng = ScriptedRandomSource(<int>[10, 20, 30]);
      expect(rng.nextUint32(), 10);
      expect(rng.nextUint32(), 20);
      expect(rng.nextUint32(), 30);
      expect(rng.nextUint32(), 10, reason: '脚本耗尽后循环，便于固定断言');
    });

    test('可用于驱动加权抽样而无需关心 PRNG 内部实现', () {
      // nextInt(100) 直接取模；脚本给 0 就必然落在第一段权重里。
      final rng = ScriptedRandomSource(<int>[0]);
      expect(rng.nextInt(100), 0);
    });
  });
}
