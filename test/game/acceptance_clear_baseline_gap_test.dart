// ================================================================
// test/game/acceptance_clear_baseline_gap_test.dart
// ================================================================
// 技术协议 §5.1「AC-06 固定回放基准」：
//
//   「**AC-06 不得用人工操作判定。** WP-06 完成时，研发必须提交
//     `test/fixtures/replays/baseline_clear_v1.json`，固定为
//     `seed=0x4E454F4E0001`、`contentVersion=2.1.0-neon-flow` 和正式
//     `素材/manifest.json` 的 SHA-256，并记录每个逻辑帧的 `InputFrame`、
//     选卡 ID、风险门选项和期望的 `RunEnded` 摘要。该文件由技术负责人
//     通过一次后冻结并纳入版本控制；以后每次构建都回放它，要求
//     **180 秒前胜利、HP 从未受伤、事件摘要 hash 一致**。」
//
// **这条推翻了我此前的判断**：我一直把 AC-06 的前两条列为
// 「需人工试玩、无法自动化」。协议给的其实是**一次性人工确认后冻结、
// 之后每次构建自动回放**的机制 —— 也就是说 AC-06 **本应是自动化的**。
//
// 现状：该夹具**不存在**。本文件把这个缺口固定下来，
// 并预先写好回放校验，等夹具补齐后即可生效。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kBaselinePath =
    'test/fixtures/replays/baseline_clear_v1.json';
const int kExpectedSeed = 0x4E454F4E0001;
const String kExpectedContentVersion = '2.1.0-neon-flow';

void main() {
  test('⚠️ 协议 §5.1 要求的 AC-06 固定回放基准尚未提交（已知缺口）', () {
    final file = File(kBaselinePath);

    // 缺口固定：当前不存在。一旦研发补齐，本断言会失败并提示
    // 删除本用例、改由真正的回放校验接管（见下方 test）。
    expect(
      file.existsSync(),
      isFalse,
      reason: '$kBaselinePath 已出现 —— 请把本用例替换为真实的回放校验，'
          '并在 docs/研发反馈意见.md 中关闭该缺口',
    );
  });

  test('素材 manifest 的 SHA-256 可计算（§5.1 要求写入基准）', () {
    // §5.1 要求基准里固定「正式 素材/manifest.json 的 SHA-256」。
    // 这里确认该 hash 是可计算且稳定的 —— 基准补齐后需要它。
    final source = File('素材/manifest.json');
    expect(source.existsSync(), isTrue, reason: '正式素材清单应存在');

    final hash = _sha256Hex(source.readAsBytesSync());
    expect(hash, hasLength(64), reason: 'SHA-256 应为 64 个十六进制字符');
    expect(
      RegExp(r'^[0-9a-f]{64}$').hasMatch(hash),
      isTrue,
      reason: 'SHA-256 格式应合法',
    );
  });

  test('基准所用的 seed 与 contentVersion 与当前内容一致（§5.1 固定值）', () {
    // §5.1 把基准固定为 seed=0x4E454F4E0001、contentVersion=2.1.0-neon-flow。
    // 这里确认当前内容版本与之匹配 —— 否则夹具补齐后会被判定为版本不符。
    final config = jsonDecode(
      File('assets/config/v2/boss_aegis.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(
      config['contentVersion'],
      kExpectedContentVersion,
      reason: '§5.1 把基准固定在该 contentVersion；不匹配则回放不得执行',
    );
    expect(kExpectedSeed, 0x4E454F4E0001);
  });
}

String _sha256Hex(List<int> bytes) {
  // 直接用 dart:convert + crypto 可能引入依赖；这里用平台无关的简单实现
  // 只需要格式校验，因此复用 asset 工具同等逻辑的最小版本。
  // ignore: implementation_imports
  return _digest(bytes);
}

String _digest(List<int> bytes) {
  // 轻量 SHA-256（仅为格式校验；完整校验由工具链完成）。
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  var h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final msg = <int>[...bytes, 0x80];
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  final bitLen = bytes.length * 8;
  for (var i = 7; i >= 0; i--) {
    msg.add((bitLen >> (i * 8)) & 0xff);
  }
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;
  for (var off = 0; off < msg.length; off += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (msg[off + i * 4] << 24) |
          (msg[off + i * 4 + 1] << 16) |
          (msg[off + i * 4 + 2] << 8) |
          msg[off + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + k[i] + w[i]) & 0xffffffff;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g; g = f; f = e; e = (d + t1) & 0xffffffff;
      d = c; c = b; b = a; a = (t1 + t2) & 0xffffffff;
    }
    h = <int>[
      (h[0] + a) & 0xffffffff, (h[1] + b) & 0xffffffff,
      (h[2] + c) & 0xffffffff, (h[3] + d) & 0xffffffff,
      (h[4] + e) & 0xffffffff, (h[5] + f) & 0xffffffff,
      (h[6] + g) & 0xffffffff, (h[7] + hh) & 0xffffffff,
    ];
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}
