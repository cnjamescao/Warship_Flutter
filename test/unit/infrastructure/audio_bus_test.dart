// ================================================================
// test/unit/infrastructure/audio_bus_test.dart
// ================================================================
// 产品设计 §8 第 280 行要求「音效/音乐**独立**音量」。
//
// **背景（真实缺口）**：设置里有两个开关 `musicEnabled` / `sfxEnabled`，
// 但此前音频层只有一个合并的 `setMuted(!sfx && !music)` ——
// 只有两个都关才会静音，于是"关音乐留音效"时两者都还在响，
// 两个开关等于只有一个在起作用。本轮改为按总线独立判定，
// 本文件守住这个语义。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/infrastructure/audio_port.dart';

AudioCue cue(
  String id,
  AudioBus bus, {
  bool loop = false,
  int minRetriggerMs = 0,
}) => AudioCue(
  cueId: id,
  assetId: 'SFX-TEST',
  bus: bus,
  loop: loop,
  minRetriggerMs: minRetriggerMs,
);

void main() {
  test('默认所有总线启用', () {
    final service = AudioService(port: RecordingAudioPort());
    for (final bus in AudioBus.values) {
      expect(service.isBusEnabled(bus), isTrue, reason: '${bus.name} 默认应启用');
    }
  });

  test('关闭音乐总线后音乐 cue 被拒，音效仍正常', () {
    final port = RecordingAudioPort();
    final service = AudioService(port: port);

    service.setBusEnabled(AudioBus.music, false);

    expect(
      service.request(cue('music.main', AudioBus.music)),
      AudioDecision.busDisabled,
      reason: '音乐总线已关，不应播放',
    );
    expect(
      service.request(cue('hit.enemy', AudioBus.sfx)),
      AudioDecision.play,
      reason: '音效总线仍启用，应正常播放',
    );
    expect(port.playedCueIds, isNot(contains('music.main')));
    expect(port.playedCueIds, contains('hit.enemy'));
  });

  test('只关音效、留着音乐 —— 这正是旧实现出错的情形', () {
    final port = RecordingAudioPort();
    final service = AudioService(port: port);

    service.setBusEnabled(AudioBus.sfx, false);
    service.setBusEnabled(AudioBus.ui, false);
    service.setBusEnabled(AudioBus.warning, false);

    expect(
      service.request(cue('hit.enemy', AudioBus.sfx)),
      AudioDecision.busDisabled,
    );
    expect(
      service.request(cue('music.main', AudioBus.music)),
      AudioDecision.play,
      reason: '旧实现下 `!sfx && !music` 为 false，音乐也会被静音；现在应正常',
    );
    expect(port.playedCueIds, contains('music.main'));
    expect(port.playedCueIds, isNot(contains('hit.enemy')));
  });

  test('预警总线随音效开关，且关闭时不播放', () {
    final service = AudioService(port: RecordingAudioPort());
    service.setBusEnabled(AudioBus.warning, false);
    expect(
      service.request(cue('warn.attack', AudioBus.warning)),
      AudioDecision.busDisabled,
    );
  });

  test('关闭总线会停掉它正在循环的声音', () {
    final port = RecordingAudioPort();
    final service = AudioService(port: port);

    // 起一个音乐循环音。
    expect(
      service.request(cue('music.loop', AudioBus.music, loop: true)),
      AudioDecision.play,
    );
    expect(service.runningLoops, contains('music.loop'));

    service.setBusEnabled(AudioBus.music, false);

    expect(
      service.runningLoops,
      isNot(contains('music.loop')),
      reason: '关闭总线必须停掉循环音，否则会一直响',
    );
    // 实现调的是 stopBus（停整条总线），比逐个停 cue 更彻底。
    expect(port.stoppedBuses, contains(AudioBus.music));
  });

  test('重新启用后可以再次播放', () {
    final port = RecordingAudioPort();
    final service = AudioService(port: port);

    service.setBusEnabled(AudioBus.music, false);
    expect(
      service.request(cue('music.main', AudioBus.music)),
      AudioDecision.busDisabled,
    );

    service.setBusEnabled(AudioBus.music, true);
    expect(
      service.request(cue('music.main', AudioBus.music)),
      AudioDecision.play,
    );
  });

  test('关闭总线在暂停期间同样生效（判定顺序在暂停之前）', () {
    final service = AudioService(port: RecordingAudioPort());
    service.setBusEnabled(AudioBus.sfx, false);
    service.pause();

    expect(
      service.request(cue('hit.enemy', AudioBus.sfx)),
      AudioDecision.busDisabled,
      reason: '总线关闭应先于暂停判定，语义更明确',
    );
  });
}
