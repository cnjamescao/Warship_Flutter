// ================================================================
// lib/game/core/random_source.dart —— 确定性随机源
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §5
//   「选择可复现 PRNG（例如 PCG32/Xoshiro 系列），将算法名和 seed 写入
//     RunStarted；禁止依赖 Dart 默认 Random 的跨版本序列。」
//
// 产品基线 §3.2：一局只使用一个确定性 PRNG；
// 同一 seed + 同一输入事件序列，波次、升级候选、风险门结果必须相同。
//
// 设计：接口只声明**原语**（algorithm / seed / nextUint32），
// 派生抽样作为扩展方法提供。原因是 Dart 的 `implements` 要求实现
// 接口的每一个成员（包括带默认体的成员），把便利方法放进接口会让
// 每个实现类都被迫重复实现它们。
// ================================================================

/// 确定性随机源契约：只要求三个成员。
abstract interface class RandomSource {
  /// PRNG 算法名，写入 `RunStarted` 供回放校验。
  String get algorithm;

  /// 原始 32 位无符号种子。
  int get seed;

  /// 下一个 32 位无符号整数（0 ≤ x < 2^32）。
  int nextUint32();
}

/// 建立在 [RandomSource.nextUint32] 之上的抽样便利方法。
///
/// 所有上层抽样（加权无放回、范围取值）都必须经过这里，
/// 以保证"同一 seed ⇒ 同一序列"这一可回放前提。
extension RandomSourceSampling on RandomSource {
  /// 下一个 `[0, 1)` 双精度浮点。
  double nextDouble() => nextUint32() / 4294967296.0; // 2^32

  /// 返回 `[0, maxExclusive)` 的整数。[maxExclusive] 必须为正。
  int nextInt(int maxExclusive) {
    assert(maxExclusive > 0, 'maxExclusive 必须为正');
    return nextUint32() % maxExclusive;
  }

  /// 返回 `[minInclusive, maxInclusive]` 的整数。
  int nextIntInRange(int minInclusive, int maxInclusive) {
    assert(maxInclusive >= minInclusive);
    return minInclusive + nextInt(maxInclusive - minInclusive + 1);
  }

  /// 返回 `[min, max)` 的双精度浮点。
  double nextDoubleInRange(double min, double max) =>
      min + nextDouble() * (max - min);
}

/// PCG32（XSH-RR 变体）确定性伪随机数生成器。
///
/// 选择理由：
///   * 状态只有 64 位 + 固定增量，序列完全由种子决定，跨平台/跨版本稳定；
///   * 统计质量足以支撑抽卡与掉落，且实现极小、无外部依赖；
///   * 便于在测试中直接构造相同序列。
///
/// 注意：本实现刻意不使用 `dart:math` 的 `Random`，因为其序列不保证跨版本一致。
class Pcg32 implements RandomSource {
  /// 以 [seed] 与可选的流标识 [sequence] 初始化。
  Pcg32(int seed, {int sequence = 0xDA3E39CB94B95BDB})
    : _state = 0,
      _inc = ((sequence << 1) | 1) & _mask64,
      _seed = seed & _mask64 {
    nextUint32();
    _state = (_state + _seed) & _mask64;
    nextUint32();
  }

  static const int _mask64 = 0xFFFFFFFFFFFFFFFF;
  static const int _multiplier = 6364136223846793005;

  int _state;
  final int _inc;
  final int _seed;

  @override
  String get algorithm => 'pcg32-xsh-rr';

  @override
  int get seed => _seed;

  @override
  int nextUint32() {
    final oldState = _state;
    _state = (oldState * _multiplier + _inc) & _mask64;
    final xorShifted = ((oldState >> 18) ^ oldState) >> 27;
    final rot = (oldState >> 59) & 31;
    final result =
        ((xorShifted >> rot) | (xorShifted << ((-rot) & 31))) & 0xFFFFFFFF;
    return result;
  }
}

/// 固定序列的随机源，仅供测试使用。
///
/// 它按顺序吐出预先给定的值，因此测试可以精确断言抽样结果，
/// 而不必关心 PRNG 的内部实现。
class ScriptedRandomSource implements RandomSource {
  ScriptedRandomSource(this._values, {this.seed = 0})
    : assert(_values.isNotEmpty, '至少需要一个脚本值');

  final List<int> _values;
  int _cursor = 0;

  @override
  final int seed;

  @override
  String get algorithm => 'scripted';

  @override
  int nextUint32() {
    final value = _values[_cursor % _values.length];
    _cursor++;
    return value & 0xFFFFFFFF;
  }
}
