// ================================================================
// test/unit/infrastructure/v21_audio_path_test.dart —— F-44 守卫
// ================================================================
// **架构位置**：Infrastructure 层守卫。锁定"音频 cue 传的是**文件路径**"。
//
// **缺陷来源（F-44，2026-10-19 玩家实测）**：
//   玩家报"全程没有声音"。根因是 `AudioCue.assetId` 填的是 **Asset ID**
//   （`SFX-V21-...`），而 `FlameAudio.play()` 要的是**文件路径** ⇒
//   每次播放都抛异常，又被 `catch (_) {}` **静默吞掉** ⇒ 一声不响，
//   而且代码完全静默，排查时毫无线索。
//
// 本文件锁住三件事：
//   ① 代码确实**从 manifest 的 runtimeFiles 取路径**（不是 assetId）；
//   ② 该路径**去掉了** `FlameAudio` 自带前缀 `assets/audio/`；
//   ③ manifest 里的音频文件确实是 `.wav` 且位于 `assets/audio/` 下。
//
// 这比"有调用 play"强得多 —— 那条断言在缺陷存在时**照样通过** ✗。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

import '../../support/v2_harness.dart';

late AssetManifest manifest;
late String src;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    manifest = (await loadV2CatalogForTests()).manifest;
    src = File('lib/game/infrastructure/audio_director.dart').readAsStringSync();
  });

  test('F-44a 代码从 runtimeFiles 取路径，**不再**直接用 assetId', () {
    // 必须存在这条取值（修好之后的实现）。
    expect(
      src,
      contains('runtimeFiles'),
      reason: '必须从 manifest 的 runtimeFiles 取真实文件路径',
    );
    // 缺陷写法：`assetId: match.assetId.value`。
    expect(
      src.contains('assetId: match.assetId.value'),
      isFalse,
      reason: '不得把 Asset ID 直接当文件路径交给播放器（F-44 根因）✗',
    );
  });

  test('F-44b 路径去掉了 FlameAudio 的默认前缀 assets/audio/', () {
    expect(
      src,
      contains("const prefix = 'assets/audio/';"),
      reason: '必须裁掉 FlameAudio 自带的前缀，否则找不到文件 ✗',
    );
  });

  test('F-44c 播放失败**不再完全静默**（每个资源只警告一次）', () {
    // 架构 §7 要求"失败静默继续"（不能因音频崩战斗），
    // 但**完全静默**让 F-44 白查一轮 —— 现在至少留一行日志。
    expect(src, contains('[audio] 播放失败'), reason: '失败应留下可诊断的日志');
    expect(src, contains('_warned'), reason: '每个资源只警告一次，避免刷屏');
  });

  test('F-44d manifest 里的音频文件确实是 .wav 且在 assets/audio/ 下', () {
    var checked = 0;
    for (final r in manifest.records) {
      if (r.category != AssetCategory.sfx && r.category != AssetCategory.bgm) {
        continue;
      }
      for (final f in r.runtimeFiles) {
        checked++;
        expect(f, startsWith('assets/audio/'), reason: '${r.assetId.value} 路径');
        // 素材里**两种格式并存**（67 个 .mp3 + 12 个 .wav），
        // 我的第一版断言只允许 .wav —— **是测试写错**，不是 manifest 错 ✗。
        expect(
          f.endsWith('.wav') || f.endsWith('.mp3'),
          isTrue,
          reason: '${r.assetId.value} 应是 wav 或 mp3',
        );
      }
    }
    expect(checked, greaterThan(50), reason: '应有大量音频文件被检查');
  });
}
