// ================================================================
// test/unit/core/pcg32_reference_test.dart
// ================================================================
// **与权威参照逐值对照**，而不只是"自己和自己一致"。
//
// 背景（真实的两个缺陷）：
//   * 项目**无法编译为 Web** —— PCG32 用了 64 位字面量，JS 无法精确表示；
//   * 更隐蔽的是，**原实现并不是它自报的 `pcg32-xsh-rr`** ——
//     XSH-RR 要求逻辑右移，而 Dart 对负数的 `>>` 是算术右移。
//
// 此前的确定性测试只验证"同种子两次一致"，**验证不出"是否等于标准算法"**。
// 本文件用 Python（任意精度整数）实现的 PCG32 参照值做交叉校验。
//
// 参照值的生成方式（Python）：
//   MASK=(1<<64)-1; MULT=6364136223846793005
//   state=0; inc=((0xDA3E39CB94B95BDB<<1)|1)&MASK
//   next(); state=(state+seed)&MASK; next()   # 两次预热
//   next(): old=state; state=(old*MULT+inc)&MASK
//           x=(((old>>18)^old)>>27)&0xFFFFFFFF; r=(old>>59)&31
//           return ((x>>r)|(x<<((-r)&31)))&0xFFFFFFFF
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/random_source.dart';

/// 权威参照值（seed = 0x4E454F4E0001）。
const List<int> kReferenceSeed1 = <int>[
  3964690459,
  723184244,
  1893306317,
  542306440,
  409935723,
];

void main() {
  test('前 5 个输出与 Python 权威参照逐值一致', () {
    final rng = Pcg32(0x4E454F4E0001);
    final got = <int>[for (var i = 0; i < 5; i++) rng.nextUint32()];
    expect(
      got,
      kReferenceSeed1,
      reason: '实现必须等于标准 pcg32-xsh-rr，而不是"另一个确定性序列"',
    );
  });

  test('输出始终落在 uint32 范围内', () {
    final rng = Pcg32(12345);
    for (var i = 0; i < 2000; i++) {
      final v = rng.nextUint32();
      expect(v, greaterThanOrEqualTo(0));
      expect(v, lessThan(1 << 32));
    }
  });

  test('不同种子产生不同序列，同种子可复现', () {
    List<int> take(int seed) {
      final r = Pcg32(seed);
      return <int>[for (var i = 0; i < 8; i++) r.nextUint32()];
    }

    expect(take(1), take(1), reason: '同种子必须可复现');
    expect(take(1), isNot(take(2)), reason: '不同种子应不同');
  });

  test('自报的算法名与实际一致（pcg32-xsh-rr）', () {
    // 这条断言的意义：算法名会写进 `RunStarted` 并出现在回放里，
    // 若名不副实，回放就无法跨实现解释。
    expect(Pcg32(1).algorithm, 'pcg32-xsh-rr');
  });
}
