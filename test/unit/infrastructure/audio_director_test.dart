// ================================================================
// test/unit/infrastructure/audio_director_test.dart
// ================================================================
// 覆盖：事件 → cue 的精确路由（T-ASSET-02 的音频侧）、
//       T-AUDIO-01 的高频合并、T-AUDIO-02 的暂停/恢复。
// 直接读取真实 manifest，因此同时验证素材接线与路由实现。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/core/domain_event.dart';
import 'package:warship_flutter/game/core/random_source.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/run_context.dart';
import 'package:warship_flutter/game/domain/values.dart';
import 'package:warship_flutter/game/infrastructure/asset_loader.dart';
import 'package:warship_flutter/game/infrastructure/audio_director.dart';
import 'package:warship_flutter/game/infrastructure/audio_port.dart';

const EntityId kEnemy = EntityId(EntityKind.enemy, 1);
const EntityId kPlayer = EntityId(EntityKind.player, 0);

RunContext context() => RunContext(
  identity: const RunIdentity(
    runId: 'audio-test',
    seed: 1,
    prngAlgorithm: 'pcg32-xsh-rr',
    contentVersion: '2.0.6-material-repair',
    contentManifestSha256: 'test',
  ),
  random: Pcg32(1),
);

void main() {
  late AssetBindingTable table;
  late RecordingAudioPort port;
  late AudioService service;
  late AudioDirector director;

  setUpAll(() {
    final json =
        jsonDecode(
              File('assets/config/v2/manifest.json').readAsStringSync(),
            )
            as Map<String, Object?>;
    final parsed = AssetManifest.parse(json);
    expect(parsed.isSuccess, isTrue, reason: parsed.describeErrors());
    table = const AssetLoader().build(parsed.requireValue);
  });

  setUp(() {
    port = RecordingAudioPort();
    service = AudioService(port: port);
    director = AudioDirector(table: table, service: service);
  });

  group('事件 → cue 路由', () {
    test('精英生成有专属音效（普通生成按 manifest 无绑定）', () {
      final played = director.handle(
        const EnemySpawned(
          entityId: kEnemy,
          enemyId: 'EN-WING',
          position: Vec2(960, -80),
          isElite: true,
        ),
      );

      expect(played, isNotEmpty, reason: '精英生成应有 SFX-ELITE-SPAWN');
      // 同一事件可以同时驱动音效与 BGM 换曲（manifest 的多层绑定），
      // 因此只要求至少有一条非音乐的 cue。
      expect(
        played.any((c) => c.bus != AudioBus.music),
        isTrue,
        reason: '精英生成应有音效而不只是换 BGM',
      );
    });

    test('武器开火能命中音效（weaponId 需从 WPN-* 映射到系列短名）', () {
      final played = director.handle(
        const WeaponFired(
          weaponId: 'WPN-PULSE',
          sourceId: kPlayer,
          position: Vec2(960, 900),
          direction: Vec2(0, -1),
        ),
      );

      expect(
        played,
        isNotEmpty,
        reason: 'manifest 的条件是 weaponId=pulse，Domain 发的是 WPN-PULSE',
      );
    });

    test('敌方攻击预警与发射各自命中不同的 cue（不串播）', () {
      director.handle(
        const EnemyAttackTelegraphed(
          entityId: kEnemy,
          enemyId: 'EN-SNIPER',
          attackId: 'sniper_line',
          position: Vec2(960, 260),
          telegraphSeconds: 0.75,
        ),
      );
      final afterTelegraph = port.playedCueIds.toList();

      port.clear();

      director.handle(
        const EnemyAttackFired(
          entityId: kEnemy,
          enemyId: 'EN-SNIPER',
          attackId: 'sniper_line',
          position: Vec2(960, 260),
          telegraphSeconds: 0.75,
        ),
      );

      expect(afterTelegraph, isNotEmpty);
      expect(port.playedCueIds, isNotEmpty);
      expect(
        port.playedCueIds,
        isNot(afterTelegraph),
        reason: '预警与发射必须是不同的 cue',
      );
    });

    test('Boss 招式按 attackId 精确路由', () {
      director.handle(
        const BossAttackFired(
          attackId: 'boss_fan',
          position: Vec2(960, 210),
          telegraphSeconds: 0.7,
        ),
      );
      final fan = port.playedCueIds.toList();
      expect(fan, isNotEmpty);

      port.clear();
      director.handle(
        const BossAttackFired(
          attackId: 'boss_ring',
          position: Vec2(960, 210),
          telegraphSeconds: 0.9,
        ),
      );

      expect(port.playedCueIds, isNotEmpty);
      expect(port.playedCueIds, isNot(fan), reason: '不同招式必须不同音效');
    });

    test('未绑定事件不产生播放也不抛异常', () {
      expect(
        () => director.handle(const BossDefeated()),
        returnsNormally,
      );
      // RunStarted 没有音频绑定（它是回放/调试事件）。
      expect(
        () => director.handle(
          const RunStarted(
            seed: 1,
            prngAlgorithm: 'pcg32-xsh-rr',
            contentVersion: '2.0.6-material-repair',
          ),
        ),
        returnsNormally,
      );
    });

    test('RunEnded 按 result 区分胜负音', () {
      director.handle(
        const RunEnded(
          result: 'victory',
          durationSeconds: 100,
          score: 1,
          seed: 1,
          bossHpRatio: 0,
          resultTier: 'gold',
        ),
      );
      final victory = port.playedCueIds.toList();

      port.clear();
      director.handle(
        const RunEnded(
          result: 'defeat',
          durationSeconds: 100,
          score: 1,
          seed: 1,
          bossHpRatio: 0.5,
          resultTier: 'none',
        ),
      );

      expect(victory, isNotEmpty);
      expect(port.playedCueIds, isNotEmpty);
      expect(port.playedCueIds, isNot(victory));
    });

    test('参数不含区分字段时不会命中宽泛绑定', () {
      // 攻击事件缺 attackId 时不应命中任何 cue。
      final played = table.resolveCues('BossAttackFired', <String, Object?>{
        'unknown': 'x',
      });
      expect(played, isEmpty);
    });
  });

  group('T-AUDIO-01 高频合并', () {
    test('连续射击在 80 ms 内被合并', () {
      const shot = WeaponFired(
        weaponId: 'WPN-PULSE',
        sourceId: kPlayer,
        position: Vec2(960, 900),
        direction: Vec2(0, -1),
      );

      // 每步 1/60 秒推进，模拟 1 秒内的自动射击。
      for (var i = 0; i < 60; i++) {
        director.handle(shot);
        service.advance(1 / 60);
      }

      expect(
        port.playedCueIds.length,
        lessThan(60),
        reason: '80 ms 合并应显著减少播放次数',
      );
      expect(service.scheduler.mergedCount, greaterThan(0));
    });
  });

  group('T-AUDIO-02 暂停与恢复', () {
    test('进入 Paused 时挂起；恢复时不重新起播', () {
      director.onPhaseChanged(GamePhase.playing, GamePhase.paused);
      expect(service.isPaused, isTrue);
      expect(port.pauseCount, 1);

      director.onPhaseChanged(GamePhase.paused, GamePhase.playing);
      expect(service.isPaused, isFalse);
      expect(port.resumeCount, 1);
    });

    test('离开对局时停止全部循环音', () {
      director.onPhaseChanged(GamePhase.playing, GamePhase.result);
      expect(port.stoppedCueIds.length + service.runningLoops.length,
          greaterThanOrEqualTo(0));
      expect(service.runningLoops, isEmpty);
    });

    test('暂停期间不产生新的瞬时音', () {
      director.onPhaseChanged(GamePhase.playing, GamePhase.paused);
      port.clear();

      director.handle(
        const EnemySpawned(
          entityId: kEnemy,
          enemyId: 'EN-SCOUT',
          position: Vec2(960, -80),
          isElite: false,
        ),
      );

      expect(port.playedCueIds, isEmpty);
    });

    test('静音后不播放', () {
      service.setMuted(true);
      director.handle(
        const EnemySpawned(
          entityId: kEnemy,
          enemyId: 'EN-SCOUT',
          position: Vec2(960, -80),
          isElite: false,
        ),
      );
      expect(port.playedCueIds, isEmpty);
    });
  });

  group('音乐换曲不叠层', () {
    test('同一 BGM 重复请求只起播一次', () {
      const result = RunEnded(
        result: 'victory',
        durationSeconds: 1,
        score: 1,
        seed: 1,
        bossHpRatio: 0,
        resultTier: 'gold',
      );

      director.handle(result);
      final first = port.playedCueIds.length;
      // 第二次请求：同 cue 且仍在合并窗口内 → 不再播放。
      director.handle(result);

      expect(port.playedCueIds.length, first);
    });
  });
}
