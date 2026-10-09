// ================================================================
// tool/generate_audio.dart —— 游戏音效生成器（可复现资产）
// ================================================================
//
// 为什么要自己合成音效？
//   1. 授权干净：不引入任何第三方音频素材的版权问题，仓库可自由分发。
//   2. 体积极小：四个音效总计约 40KB。
//   3. 风格统一：方波 + 噪声 + 指数衰减，正好是复古 chiptune 味道。
//   4. 可复现：任何人执行 `dart run tool/generate_audio.dart`
//      都能得到完全一致的 wav 文件（噪声使用固定随机种子）。
//
// 用法：
//   dart run tool/generate_audio.dart
//
// 产物（写入 assets/audio/）：
//   shoot.wav       射击：高频快速下滑的方波"啾"声
//   hit.wav         击毁敌人：噪声爆裂 + 低音冲击
//   life_lost.wav   掉命：明显下滑的警示音
//   game_over.wav   游戏结束：三连下行音阶
//
// 音频规格：22050 Hz / 单声道 / 16-bit PCM —— 复古音效足够，
// 且避免采样率过高导致文件变大。
// ================================================================

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const int kSampleRate = 22050;

void main() {
  final outDir = Directory('assets/audio');
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  final assets = <String, List<double>>{
    // 射击：1200Hz → 520Hz，80ms，衰减快 —— 短促、清脆、不刺耳
    'shoot.wav': _sweep(
      fromHz: 1200,
      toHz: 520,
      seconds: 0.08,
      decay: 18,
      volume: 0.35,
    ),
    // 击毁：噪声与低方波混合，150ms —— 有"炸开"的质感
    'hit.wav': _sweep(
      fromHz: 420,
      toHz: 90,
      seconds: 0.15,
      decay: 14,
      volume: 0.45,
      noiseMix: 0.55,
    ),
    // 掉命：260Hz → 70Hz，420ms，衰减慢 —— 明确的负面反馈
    'life_lost.wav': _sweep(
      fromHz: 260,
      toHz: 70,
      seconds: 0.42,
      decay: 5,
      volume: 0.45,
      noiseMix: 0.15,
    ),
    // 结束：三连下行音阶，每音 180ms —— 收束感
    'game_over.wav': _sequence(
      const [392.0, 311.1, 196.0],
      noteSeconds: 0.18,
      decay: 6,
      volume: 0.42,
    ),
  };

  for (final entry in assets.entries) {
    final file = File('${outDir.path}/${entry.key}');
    file.writeAsBytesSync(_encodeWav(entry.value));
    stdout.writeln(
      '✓ ${file.path}  '
      '(${(entry.value.length / kSampleRate * 1000).round()} ms, '
      '${file.lengthSync()} bytes)',
    );
  }
  stdout.writeln('完成：共 ${assets.length} 个音效。');
}

/// 方波：复古音效的基础波形，比正弦波更有"电子感"。
double _square(double phase) => (phase % 1.0) < 0.5 ? 1.0 : -1.0;

/// 生成一段频率扫描（滑音）波形。
///
/// [fromHz] 起始频率，[toHz] 结束频率，[seconds] 时长。
/// [decay] 指数衰减速度，越大衰减越快（听感越"短促"）。
/// [noiseMix] 噪声混合比例，0 = 纯方波，1 = 纯噪声。
List<double> _sweep({
  required double fromHz,
  required double toHz,
  required double seconds,
  required double decay,
  required double volume,
  double noiseMix = 0.0,
}) {
  final n = (seconds * kSampleRate).round();
  final out = List<double>.filled(n, 0);
  // 固定随机种子 —— 保证每次生成的噪声完全一致（可复现）
  final rng = Random(20261009);
  var phase = 0.0;

  for (var i = 0; i < n; i++) {
    final t = i / n;
    // 频率随时间线性滑动
    final f = fromHz + (toHz - fromHz) * t;
    phase += f / kSampleRate;
    var sample = _square(phase);
    if (noiseMix > 0) {
      final noise = rng.nextDouble() * 2 - 1;
      sample = sample * (1 - noiseMix) + noise * noiseMix;
    }
    out[i] = sample * exp(-decay * t) * volume;
  }
  _applyEdgeFades(out);
  return out;
}

/// 生成一串连续音符（用于结束音）。
List<double> _sequence(
  List<double> freqs, {
  required double noteSeconds,
  required double decay,
  required double volume,
}) {
  final out = <double>[];
  for (final f in freqs) {
    out.addAll(
      _sweep(
        fromHz: f,
        toHz: f,
        seconds: noteSeconds,
        decay: decay,
        volume: volume,
      ),
    );
  }
  _applyEdgeFades(out);
  return out;
}

/// 在首尾各加约 3ms 淡入淡出，消除波形突变造成的"咔哒"爆音。
void _applyEdgeFades(List<double> samples) {
  final fade = (0.003 * kSampleRate).round().clamp(1, samples.length ~/ 2);
  for (var i = 0; i < fade; i++) {
    final g = i / fade;
    samples[i] *= g;
    samples[samples.length - 1 - i] *= g;
  }
}

/// 把归一化浮点样本编码为 16-bit PCM 单声道 WAV。
Uint8List _encodeWav(List<double> samples) {
  const bitsPerSample = 16;
  const channels = 1;
  final byteRate = kSampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;
  final dataBytes = samples.length * 2;

  final bytes = BytesBuilder();
  void ascii(String s) => bytes.add(s.codeUnits);
  void u32(int v) =>
      bytes.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) =>
      bytes.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));

  ascii('RIFF');
  u32(36 + dataBytes); // 后续所有字节数
  ascii('WAVE');

  ascii('fmt ');
  u32(16); // PCM 格式块长度
  u16(1); // 音频格式：1 = PCM
  u16(channels);
  u32(kSampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);

  ascii('data');
  u32(dataBytes);

  final pcm = Int16List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    // 先做软限幅，防止叠加后溢出产生刺耳失真
    final v = samples[i].clamp(-1.0, 1.0);
    pcm[i] = (v * 32767).round();
  }
  bytes.add(pcm.buffer.asUint8List());

  return bytes.toBytes();
}
