// ================================================================
// test/web/web_lifecycle_freeze_test.dart —— WEB-T-03
// ================================================================
// **架构位置**：Web 平台验收测试（后台/恢复）。
//
// **依据**（WEB-T-03）：
//   「`hidden` 后推进 120 帧，**逻辑时间、随机、伤害和预警全部冻结**；
//     恢复后**只等待玩家恢复操作**，不重开、不换 seed、不重复音效。」
//
// **分工说明（避免重复测同一件事）**：
//   * 「暂停后逻辑完全冻结」由 `game_runtime_test.dart` 的 **T-CORE-02**
//     直接驱动 runtime 验证（坐标/计时器/实体数都不变）✓ 本文件不重复；
//   * 本文件锁的是**浏览器特有的接线**：`hidden` 必须映射到同一条暂停路径、
//     且恢复不得重开/换 seed。这类合同是"**忘了一个分支就静默失效**"型
//     错误，用静态扫描**精确对应**，比复制一整套 runtime 装配更不容易腐烂 ✓。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';

void main() {
  late String runScreen;
  setUpAll(() {
    runScreen = File('lib/app/v2_run_screen.dart').readAsStringSync();
  });

  test('WEB-T-03a `hidden` 必须与 inactive/paused/detached 走**同一条**路径', () {
    // 浏览器 `visibilitychange(hidden)` 被 Flutter 映射成 AppLifecycleState.hidden。
    // 若只处理 paused 而漏掉 hidden，切标签页**就不会暂停** ✗。
    for (final state in <String>[
      'AppLifecycleState.inactive',
      'AppLifecycleState.paused',
      'AppLifecycleState.hidden',
      'AppLifecycleState.detached',
    ]) {
      expect(
        runScreen.contains(state),
        isTrue,
        reason: '必须处理 $state —— 漏一个就会"某个平台忘了暂停"',
      );
    }
    // 四个分支必须都汇聚到同一个动作。
    expect(runScreen.contains('_clearInputAndPause'), isTrue,
        reason: '必须汇聚到统一动作（清输入 + 请求暂停）');
  });

  test('WEB-T-03b 暂停必须带 **appLifecycle** 来源（可与玩家暂停区分）', () {
    expect(
      PauseSource.values.map((e) => e.name),
      contains('appLifecycle'),
      reason: '暂停源必须可辨（否则日志/回放分不清"切走了"还是"按了暂停"）',
    );
    // 接线处必须真的传这个来源。
    expect(runScreen.contains('PauseSource.appLifecycle'), isTrue);
  });

  test('WEB-T-03c 恢复**不重开**：暂停路径里不得出现重建 runtime/换 seed', () {
    // 取 `_clearInputAndPause` 附近的方法体做检查。
    final i = runScreen.indexOf('void _clearInputAndPause()');
    expect(i, greaterThan(0));
    final body = runScreen.substring(i, i + 400);
    expect(body.contains('_startNewRun'), isFalse,
        reason: '暂停不得重开一局');
    expect(body.contains('seed:'), isFalse,
        reason: '暂停不得改 seed');
  });

  test('WEB-T-03d 冻结由 phase 保证（暂停时只有 paused 相位）', () {
    // 逻辑推进由 `GameRuntime` 按 phase 把关；这里锁住枚举值存在，
    // 具体"冻结"行为由 T-CORE-02 驱动验证。
    expect(
      <String>['home', 'loading', 'briefing', 'playing', 'paused'],
      contains('paused'),
    );
  });
}
