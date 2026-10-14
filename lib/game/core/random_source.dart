import 'package:fixnum/fixnum.dart';

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
/// ### 为什么用 `Int64` 而不是 Dart 的 `int`
///
/// PCG32 是**无符号 64 位**算法。Dart 的 `int` 在 VM 上是**有符号** 64 位，
/// 在 Web 上是 double（**只有 53 位安全**）。两个后果：
///
/// 1. **Web 编译直接失败** —— `0xDA3E39CB94B95BDB`、`6364136223846793005`
///    这类字面量 JS 无法精确表示，`dart2js` 编译期就报错；
/// 2. **算法名不副实** —— XSH-RR 要求**逻辑右移**，而 Dart 对负数的 `>>`
///    是**算术右移**（符号扩展），状态高位为 1 时输出偏离标准。
///
/// 因此这里全程使用 `package:fixnum` 的 `Int64`：
/// * 它是精确的 64 位值，VM 与 Web 行为一致；
/// * `shiftRightUnsigned` 提供逻辑右移；
/// * 与 Python 参照实现逐值对照过（见 `test/unit/core/pcg32_reference_test.dart`）。
///
/// ### 常量为何写成两个 32 位半字
///
/// 即便是 `static const`，字面量本身也会让 JS 编译失败。所以所有 64 位常量
/// 都由两个小于 2^32 的半字拼出 —— 全程不出现超过 2^53 的整数字面量。
///
/// 注意：本实现刻意不使用 `dart:math` 的 `Random`，因为其序列不保证跨版本一致。
class Pcg32 implements RandomSource {
  /// 以 [seed] 与可选的流标识 [sequence] 初始化。
  ///
  /// [sequence] 只用于区分同一 seed 下的不同流；不传时使用默认流。
  Pcg32(int seed, {int? sequence})
    : _seed = seed,
      _inc = _buildIncrement(sequence) {
    nextUint32();
    _state = _state + Int64(seed);
    nextUint32();
  }

  // 6364136223846793005 = 0x5851F42D4C957F2D
  static final Int64 _multiplier =
      (Int64(0x5851F42D) << 32) | Int64(0x4C957F2D);

  // 0xDA3E39CB94B95BDB（默认流标识）
  static final Int64 _defaultSequence =
      (Int64(0xDA3E39CB) << 32) | Int64(0x94B95BDB);

  static final Int64 _mask32 = Int64(0xFFFFFFFF);

  static Int64 _buildIncrement(int? sequence) {
    final base = sequence == null ? _defaultSequence : Int64(sequence);
    return (base << 1) | Int64(1);
  }

  Int64 _state = Int64.ZERO;
  final Int64 _inc;
  final int _seed;

  @override
  String get algorithm => 'pcg32-xsh-rr';

  @override
  int get seed => _seed;

  @override
  int nextUint32() {
    final oldState = _state;
    // 无符号 64 位回绕由 Int64 保证。
    _state = oldState * _multiplier + _inc;

    // XSH：先异或再取无符号右移；R R：按高位决定的位数做循环右移。
    final shifted =
        (oldState.shiftRightUnsigned(18) ^ oldState).shiftRightUnsigned(27);
    final xorshifted = shifted & _mask32;
    final rot = (oldState.shiftRightUnsigned(59) & Int64(31)).toInt();

    final rotated = xorshifted.shiftRightUnsigned(rot) |
        (xorshifted << ((32 - rot) & 31));
    return (rotated & _mask32).toInt();
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
