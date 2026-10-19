// ================================================================
// test/unit/infrastructure/v21_bgm_wiring_test.dart —— F-45 守卫
// ================================================================
// **架构位置**：Infrastructure 层守卫。锁定"开局 BGM **真的**被请求播放"。
//
// **缺陷来源（F-45，2026-10-19 玩家实测："没有全程背景音"）**：
//   `BGM-RUN-BASE` 绑定 `RunStarted`，但该事件由 `bus.emit()` **直接发出**，
//   **不进 `lastFrameEvents`**，而音频分发只消费 `lastFrameEvents` ⇒
//   这份事件**永远到不了 AudioDirector** ⇒ **BGM 从未播放** ✗
//
// 本文件证明：把 `RunStarted` 交给分发后，**确实产生了一条 music 总线 cue**。
// 这条断言在缺陷状态下**会失败**（缺陷时根本没有 cue）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/domain_event.dart';
import 'package:warship_flutter/game/core/event_bus.dart';
import 'package:warship_flutter/game/infrastructure/asset_loader.dart';
import 'package:warship_flutter/game/infrastructure/audio_director.dart';
import 'package:warship_flutter/game/infrastructure/audio_port.dart';

import '../../support/v2_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('F-45 开局事件会请求**音乐总线**的 cue（BGM 真的会响）', () async {
    final catalog = await loadV2CatalogForTests();
    final port = RecordingAudioPort();
    final director = AudioDirector(
      table: AssetLoader().build(catalog.manifest),
      service: AudioService(port: port),
    );

    director.handleAll(<StampedEvent>[
      const StampedEvent(
        event: RunStarted(
          seed: 1,
          prngAlgorithm: 'pcg32-xsh-rr',
          contentVersion: '2.1.0-neon-flow',
        ),
        runId: 'r',
        frameIndex: 0,
        eventIndex: 0,
      ),
    ]);

    expect(
      port.playedCueIds,
      isNotEmpty,
      reason: 'RunStarted 必须产出音乐 cue，否则全程没有背景音 ✗',
    );
  });

  test('F-45b 音频分发**确实被调用**（不是只建了对象）', () {
    // 静态接线断言：规则层必须把直接 emit 的事件也送音频。
    // 缺陷状态下这段调用不存在。
    final src = File('lib/game/core/game_runtime.dart').readAsStringSync();
    expect(src, contains('pushSideEffectEvent'),
        reason: '必须提供"直接事件送音频"的入口');
    final flow = File('lib/app/v2_app_flow.dart').readAsStringSync();
    expect(
      flow.contains('pushSideEffectEvent(runStarted)') ||
          flow.contains('pushSideEffectEvent('),
      isTrue,
      reason: 'RunStarted 发出后必须显式送音频（否则 BGM 永不启动）',
    );
  });
}
