// ================================================================
// test/support/sha256.dart —— 测试用的最小 SHA-256
// ================================================================
// 从 `tool/finalize_baseline.dart` 抽出，供 AC-09 素材溯源复验使用
// （Dart 标准库无 SHA-256，且本仓库不引入额外依赖 —— 与工具的取舍一致）。
// ================================================================

String sha256Hex(List<int> bytes) {
  // 仅为校验与登记用途的最小 SHA-256 实现（避免引入额外依赖）。
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
