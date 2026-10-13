// ================================================================
// test/unit/infrastructure/audio_progress_test.dart
// ================================================================
// 覆盖 P0/P1：T-AUDIO-01（cue 合并与最大并发）、T-AUDIO-02（暂停、
// 失焦、死亡、重开时持续音正确挂起/停止、恢复不叠音）、
// T-STORE-01（空存档、损坏存档、旧 schema、写入失败）。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/infrastructure/audio_port.dart';
import 'package:warship_flutter/game/infrastructure/progress_store.dart';

AudioCue cue({
  String id = 'cue.test',
  AudioBus bus = AudioBus.sfx,
  int maxVoices = 4,
  int minRetriggerMs = 0,
  bool loop = false,
  int priority = 0,
}) => AudioCue(
  cueId: id,
  assetId: 'SFX-TEST',
  bus: bus,
  maxVoices: maxVoices,
  minRetriggerMs: minRetriggerMs,
  loop: loop,
  priority: priority,
);

void main() {
  group('T-AUDIO-01 限频与并发', () {
    test('高频 cue 在 80 ms 窗口内被合并', () {
      final scheduler = AudioScheduler();
      final pulse = cue(id: 'cue.sfx.player.pulse');

      expect(scheduler.decide(pulse, nowMs: 0), AudioDecision.play);
      scheduler.recordPlayed(pulse, nowMs: 0);

      // 每帧 1/60 秒 ≈ 16.7 ms，80 ms 内应合并。
      expect(
        scheduler.decide(pulse, nowMs: 16.7),
        AudioDecision.mergedIntoPrevious,
      );
      expect(
        scheduler.decide(pulse, nowMs: 70),
        AudioDecision.mergedIntoPrevious,
      );
      // 超过窗口后放行。
      expect(scheduler.decide(pulse, nowMs: 81), AudioDecision.play);
    });

    test('每秒 20 次射击不会产生 20 次播放', () {
      final service = AudioService(port: RecordingAudioPort());
      final pulse = cue(id: 'cue.sfx.player.pulse', maxVoices: 8);

      // 模拟 1 秒、20 次请求（每 50 ms 一次）。
      // 每发脉冲音效都很短，播完即释放发声数 —— 不模拟"播完"的话，
      // 第 9 次会先撞上 maxVoices 的并发上限而不是合并窗口。
      for (var i = 0; i < 20; i++) {
        service.request(pulse);
        service.scheduler.recordFinished(pulse.cueId);
        service.advance(0.05);
      }

      final port = service.port as RecordingAudioPort;
      expect(
        port.playedCueIds.length,
        lessThan(20),
        reason: '80 ms 合并应显著降低播放次数',
      );
      expect(port.playedCueIds.length, greaterThanOrEqualTo(10));
    });

    test('同 cue 达到最大并发时被挡下', () {
      final scheduler = AudioScheduler();
      final hit = cue(id: 'cue.sfx.en.hit', maxVoices: 2);

      scheduler.recordPlayed(hit, nowMs: 0);
      scheduler.recordPlayed(hit, nowMs: 200);
      expect(scheduler.activeVoicesOf(hit.cueId), 2);

      expect(
        scheduler.decide(hit, nowMs: 400),
        AudioDecision.voiceLimitReached,
      );

      scheduler.recordFinished(hit.cueId);
      expect(scheduler.decide(hit, nowMs: 400), AudioDecision.play);
    });

    test('Warning 总线不受最大并发限制（安全信息必须可闻）', () {
      final scheduler = AudioScheduler();
      final warn = cue(
        id: 'cue.boss.fan.warn',
        bus: AudioBus.warning,
        maxVoices: 1,
      );

      scheduler.recordPlayed(warn, nowMs: 0);
      expect(
        scheduler.decide(warn, nowMs: 500),
        AudioDecision.play,
        reason: 'Warning 永远不被并发上限挡掉',
      );
    });

    test('minRetriggerMs 生效，但持续音不受限', () {
      final scheduler = AudioScheduler();
      final lowShield = cue(id: 'cue.player.low.shield', minRetriggerMs: 8000);

      scheduler.recordPlayed(lowShield, nowMs: 0);
      expect(
        scheduler.decide(lowShield, nowMs: 5000),
        AudioDecision.throttled,
      );
      expect(scheduler.decide(lowShield, nowMs: 8100), AudioDecision.play);

      final laser = cue(id: 'cue.player.laser.loop', loop: true, minRetriggerMs: 5000);
      scheduler.recordPlayed(laser, nowMs: 0);
      expect(
        scheduler.decide(laser, nowMs: 100),
        AudioDecision.play,
        reason: '持续音不受最小重触发间隔约束',
      );
    });

    test('总线优先级：Warning > UI > SFX > Music', () {
      expect(AudioBus.warning.priority, greaterThan(AudioBus.ui.priority));
      expect(AudioBus.ui.priority, greaterThan(AudioBus.sfx.priority));
      expect(AudioBus.sfx.priority, greaterThan(AudioBus.music.priority));
    });
  });

  group('T-AUDIO-02 暂停与持续音', () {
    test('暂停挂起持续音；恢复不重新起播（不叠层）', () {
      final port = RecordingAudioPort();
      final service = AudioService(port: port);
      final laser = cue(id: 'cue.player.laser.loop', loop: true);

      service.request(laser);
      expect(service.runningLoops, contains('cue.player.laser.loop'));
      expect(port.activeLoops, contains('cue.player.laser.loop'));
      expect(port.playedCueIds.length, 1);

      service.pause();
      expect(service.isPaused, isTrue);
      expect(port.pauseCount, 1);

      // 暂停期间不产生新的瞬时音。
      expect(
        service.request(cue(id: 'cue.sfx.en.hit')),
        AudioDecision.throttled,
      );

      service.resume();
      expect(port.resumeCount, 1);
      expect(
        port.playedCueIds.length,
        1,
        reason: '恢复不得重新起播已在播的持续音',
      );
      expect(port.activeLoops, contains('cue.player.laser.loop'));
    });

    test('重复暂停/恢复是幂等的', () {
      final port = RecordingAudioPort();
      final service = AudioService(port: port);

      service.pause();
      service.pause();
      expect(port.pauseCount, 1);

      service.resume();
      service.resume();
      expect(port.resumeCount, 1);
    });

    test('持续音的结束事件会停止它并释放并发', () {
      final port = RecordingAudioPort();
      final service = AudioService(port: port);
      final laser = cue(id: 'cue.player.laser.loop', loop: true);

      service.request(laser);
      service.endLoop('cue.player.laser.loop');

      expect(port.stoppedCueIds, contains('cue.player.laser.loop'));
      expect(service.runningLoops, isEmpty);
      expect(service.scheduler.activeVoicesOf('cue.player.laser.loop'), 0);
    });

    test('结束未在播的持续音是安全的', () {
      final service = AudioService(port: RecordingAudioPort());
      expect(() => service.endLoop('never.started'), returnsNormally);
    });

    test('重新开始时停止全部循环音', () {
      final port = RecordingAudioPort();
      final service = AudioService(port: port);

      service.request(cue(id: 'cue.bgm.run', bus: AudioBus.music, loop: true));
      service.request(cue(id: 'cue.player.laser.loop', loop: true));
      expect(service.runningLoops.length, 2);

      service.stopAllLoops();

      expect(service.runningLoops, isEmpty);
      expect(port.activeLoops, isEmpty);
    });

    test('静音后不再发声', () {
      final port = RecordingAudioPort();
      final service = AudioService(port: port);

      service.setMuted(true);
      service.request(cue(id: 'cue.sfx.ui.tap', bus: AudioBus.ui));

      expect(port.playedCueIds, isEmpty);
      expect(service.isMuted, isTrue);
    });

    test('音频底层抛异常时静默继续，不冒泡', () {
      final service = AudioService(port: const _ThrowingAudioPort());
      expect(
        () => service.request(cue(id: 'cue.boom')),
        returnsNormally,
      );
    });

    test('限频使用逻辑时间而非墙上时钟（可复现）', () {
      final a = AudioService(port: RecordingAudioPort());
      final b = AudioService(port: RecordingAudioPort());
      final pulse = cue(id: 'cue.sfx.player.pulse');

      for (var i = 0; i < 10; i++) {
        a.request(pulse);
        b.request(pulse);
        a.advance(0.0167);
        b.advance(0.0167);
      }

      expect(
        (a.port as RecordingAudioPort).playedCueIds,
        (b.port as RecordingAudioPort).playedCueIds,
        reason: '同样的逻辑时间推进应产生同样的播放序列',
      );
    });
  });

  group('T-STORE-01 存档', () {
    test('空存档使用安全默认值且不阻塞', () async {
      final store = ProgressStore(store: InMemoryKeyValueStore());

      final result = await store.load();

      expect(result.usedDefaults, isTrue);
      expect(result.settings, const GameSettings());
      expect(result.records.highScore, 0);
      expect(result.records.bestClearSeconds, isNull);
      expect(result.error, isNull);
    });

    test('读写往返：设置与记录都能持久化', () async {
      final backing = InMemoryKeyValueStore();
      final store = ProgressStore(store: backing);

      await store.saveSettings(
        const GameSettings(musicEnabled: false, reduceMotion: true),
      );
      await store.saveRecords(
        const GameRecords(highScore: 12345, bestClearSeconds: 87.5),
      );

      final reloaded = await ProgressStore(store: backing).load();

      expect(reloaded.settings.musicEnabled, isFalse);
      expect(reloaded.settings.reduceMotion, isTrue);
      expect(reloaded.settings.sfxEnabled, isTrue, reason: '未写入的键取默认');
      expect(reloaded.records.highScore, 12345);
      expect(reloaded.records.bestClearSeconds, closeTo(87.5, 1e-9));
    });

    test('固定的 7 个键名不被改写', () async {
      final backing = InMemoryKeyValueStore();
      final store = ProgressStore(store: backing);
      await store.saveSettings(const GameSettings());
      await store.saveRecords(const GameRecords(highScore: 1));

      expect(
        backing.snapshot.keys.toSet(),
        <String>{
          ProgressKeys.musicEnabled,
          ProgressKeys.sfxEnabled,
          ProgressKeys.reduceMotion,
          ProgressKeys.hapticsEnabled,
          ProgressKeys.schemaVersion,
          ProgressKeys.highScore,
        },
      );
    });

    test('损坏存档退化为默认值且不抛异常', () async {
      final store = ProgressStore(
        store: InMemoryKeyValueStore(<String, String>{
          ProgressKeys.schemaVersion: 'not-a-number',
          ProgressKeys.highScore: 'garbage',
          ProgressKeys.musicEnabled: 'yes-please',
        }),
      );

      final result = await store.load();

      expect(result.records.highScore, 0, reason: '无法解析的分数按 0');
      expect(
        result.settings.musicEnabled,
        isFalse,
        reason: '只有字符串 "true" 才算开启',
      );
    });

    test('读取失败退化为默认值并记录错误', () async {
      final store = ProgressStore(store: const FailingKeyValueStore());

      final result = await store.load();

      expect(result.usedDefaults, isTrue);
      expect(result.error, isNotNull);
      expect(result.settings, const GameSettings());
    });

    test('写入失败不抛异常，只返回 false 并记录错误', () async {
      final store = ProgressStore(store: const FailingKeyValueStore());

      final ok = await store.saveSettings(const GameSettings());

      expect(ok, isFalse);
      expect(store.lastError, isNotNull);
    });

    test('高版本 schema 只读：不覆盖未知字段', () async {
      final backing = InMemoryKeyValueStore(<String, String>{
        ProgressKeys.schemaVersion: '${ProgressKeys.currentSchemaVersion + 5}',
        ProgressKeys.highScore: '777',
        'settings.futureFlag': 'keep-me',
      });
      final store = ProgressStore(store: backing);

      final result = await store.load();
      expect(result.readOnly, isTrue);

      final wrote = await store.saveRecords(
        const GameRecords(highScore: 999),
      );

      expect(wrote, isFalse);
      expect(
        backing.snapshot[ProgressKeys.highScore],
        '777',
        reason: '只读模式下不得改写已有记录',
      );
      expect(backing.snapshot['settings.futureFlag'], 'keep-me');
    });

    test('记录只增不减', () {
      const records = GameRecords(highScore: 100, bestClearSeconds: 90);

      expect(records.withScore(50).highScore, 100, reason: '更低分不覆盖');
      expect(records.withScore(200).highScore, 200);

      expect(
        records.withClearTime(95).bestClearSeconds,
        90,
        reason: '更慢的通关时间不覆盖',
      );
      expect(records.withClearTime(80).bestClearSeconds, 80);
    });
  });
}

/// 每次播放都抛异常的端口。
class _ThrowingAudioPort implements AudioPort {
  const _ThrowingAudioPort();

  @override
  void play(AudioCue cue) => throw StateError('audio device exploded');
  @override
  void stop(String cueId) => throw StateError('stop failed');
  @override
  void stopBus(AudioBus bus) => throw StateError('stopBus failed');
  @override
  void pauseAll() => throw StateError('pause failed');
  @override
  void resumeAll() => throw StateError('resume failed');
  @override
  void setMuted(bool muted) => throw StateError('mute failed');
  @override
  bool get isMuted => false;
}
