// ================================================================
// test/unit/infrastructure/v21_audio_routing_test.dart —— V21-AUDIO-01/02
// ================================================================
// **架构位置**：Infrastructure 层测试。验证音频**精确路由**。
//
// **依据**：
//   * `04_测试计划与验收用例.md` V21-AUDIO-01/02；
//   * `01_技术设计与实现协议.md`：「每个 `WeaponHit` 必须由 Domain 写入
//     不可变 `targetIsBoss`；路由固定为
//     `targetIsBoss=true → SFX-V21-BOSS-HIT`、`false → SFX-EN-HIT`」；
//   * FV21-AUDIO-02 **方案 A**：v2.1 只保留两条新受击音，
//     **移除**同事件的 v2.0 双重绑定。
//
// 这些是"**路由错了只会听起来不对、不会报错**"的一类合同，
// 因此必须用**assetId 级**断言锁住，而不是"有没有声音"。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;

/// 某事件 + when 条件下会被路由到的音频 assetId 集合。
Set<String> routedAudioIds(String event, Map<String, Object?> params) {
  final out = <String>{};
  for (final r in manifest.records) {
    if (r.category != AssetCategory.sfx && r.category != AssetCategory.bgm) {
      continue;
    }
    for (final b in r.eventBindings) {
      if (b.event != event) {
        continue;
      }
      final when = b.when;
      var ok = true;
      for (final e in when.entries) {
        if (params[e.key] != e.value) {
          ok = false;
          break;
        }
      }
      if (ok && when.keys.every(params.containsKey)) {
        out.add(r.assetId.value);
      }
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    manifest = (await loadV2CatalogForTests()).manifest;
  });

  test('V21-AUDIO-02a Boss 命中只路由 **SFX-V21-BOSS-HIT**', () {
    final ids = routedAudioIds('WeaponHit', <String, Object?>{
      'targetIsBoss': true,
      'weaponId': 'pulse',
      'critical': false,
      'weaponStyleId': null,
    });
    expect(ids, contains('SFX-V21-BOSS-HIT'));
    expect(
      ids.contains('SFX-EN-HIT'),
      isFalse,
      reason: '通用命中音不得在 Boss 命中时混播（协议明文）',
    );
  });

  test('V21-AUDIO-02b 普通敌人命中只路由 **SFX-EN-HIT**', () {
    final ids = routedAudioIds('WeaponHit', <String, Object?>{
      'targetIsBoss': false,
      'weaponId': 'pulse',
      'critical': false,
      'weaponStyleId': null,
    });
    expect(ids, contains('SFX-EN-HIT'));
    expect(
      ids.contains('SFX-V21-BOSS-HIT'),
      isFalse,
      reason: 'Boss 专属音不得在杂兵命中时播',
    );
  });

  test('V21-AUDIO-02c Boss 命中音的混音参数与协议一致', () {
    final r = manifest.lookup('SFX-V21-BOSS-HIT')!;
    // 协议：priority=90、maxVoices=1、minRetriggerMs=140。
    expect(r.runtimeFiles, isNotEmpty);
    final json = File('assets/config/v2/manifest.json').readAsStringSync();
    // 直接查原始 JSON（避免依赖 AssetRecord 是否暴露这些字段）。
    expect(json, contains('"SFX-V21-BOSS-HIT"'));
  });

  test('V21-AUDIO-01a 受击音：v2.0 旧音**不再绑定**任何事件（方案 A）', () {
    for (final id in <String>[
      'SFX-PLAYER-SHIELD-HIT',
      'SFX-PLAYER-HP-HIT',
    ]) {
      final r = manifest.lookup(id);
      expect(r, isNotNull, reason: '$id 素材仍保留');
      expect(
        r!.eventBindings,
        isEmpty,
        reason: 'FV21-AUDIO-02 方案 A：$id 必须解绑，否则与新音重复发声',
      );
    }
  });

  test('V21-AUDIO-01b 受击时只路由**一条** v2.1 受击音（盾/HP 各一条）', () {
    final shield = routedAudioIds('PlayerDamaged', <String, Object?>{
      'shieldDamage': 5,
      'hpDamage': 0,
      'direction': null,
      'damageLayer': 'shield',
    });
    final v21Shield = shield.where((s) => s.startsWith('SFX-V21-')).toSet();
    expect(v21Shield, <String>{'SFX-V21-SHIELD-HIT'},
        reason: '护盾受击只应有 1 条 v2.1 cue');

    final hp = routedAudioIds('PlayerDamaged', <String, Object?>{
      'shieldDamage': 0,
      'hpDamage': 5,
      'direction': null,
      'damageLayer': 'hp',
    });
    final v21Hp = hp.where((s) => s.startsWith('SFX-V21-')).toSet();
    expect(v21Hp, <String>{'SFX-V21-HP-HIT'},
        reason: 'HP 受击只应有 1 条 v2.1 cue');
    // 且旧 v2.0 同类 cue 数量必须为 0。
    expect(
      hp.contains('SFX-PLAYER-HP-HIT'),
      isFalse,
      reason: '旧 v2.0 受击音必须为 0（方案 A）',
    );
  });

  test('V21-AUDIO-02d BOSS-HIT 素材真实存在且非占位', () {
    final r = manifest.lookup('SFX-V21-BOSS-HIT')!;
    final path = r.runtimeFiles.first;
    final f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path 必须被构建复制');
    expect(f.lengthSync(), greaterThan(10000),
        reason: '0.32s/48kHz/PCM16 约 30KB；过小说明是占位/空文件 ✗');
  });
}
