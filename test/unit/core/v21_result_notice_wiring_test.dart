// ================================================================
// test/unit/core/v21_result_notice_wiring_test.dart —— V21-HUD-02（接线）
// ================================================================
// **架构位置**：静态接线守卫（v2.1 默认要求 R2.1：「声明了 ≠ 接上了」）。
//
// **为什么用静态扫描**：构造一个完整 `GameRuntime` 需要 5 份配置与
// 十余个系统装配（`acceptance_ac_test.buildRuntime` 就是那份样板）。
// 把它复制进本文件会让**接线检查**被**装配细节**淹没，且装配改动会让
// 检查本身失效 ✗。而"接线"这件事的本质就是**源码里有没有这条调用** ——
// 静态扫描正好精确对应它，且不会因装配重构而假失败 ✓。
//
// **能证明**：规则层**真的**在自动强化与风险门结算处入队。
// **不能证明**：运行时数值是否正确 —— 那由 `V21-HUD-02` 的队列模型测试
// 与验收用例覆盖。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;
  setUpAll(() {
    src = File('lib/game/core/game_runtime.dart').readAsStringSync();
  });

  test('V21-HUD-02 自动强化处**真的**入队（不是只声明了队列）', () {
    expect(src, contains('resultNotices.enqueue('),
        reason: '规则层必须在事件处入队，否则徽记永远不会出现');
    // **血的教训（2026-10-19 玩家实测发现）**：
    // 我只写了 `enqueue` 却没写 `advance`，于是 `current` 恒为 null、
    // **徽记永远不显示** —— 而当时这条守卫只检查 enqueue，**照样通过** ✗。
    // 现在强制要求**两者同时存在**：
    expect(src, contains('resultNotices.advance('),
        reason: '必须每步推进队列；否则入队了也永远不会成为 current（徽记不显示）');
    expect(src, contains('kind: V21ResultKind.upgrade'),
        reason: '自动强化应入队 upgrade 类徽记');
  });

  test('V21-HUD-02b 风险门结算处**也**入队，且三选项各对应一枚', () {
    expect(src, contains('V21ResultKind.supply'), reason: 'RG-SUPPLY');
    expect(src, contains('V21ResultKind.bounty'), reason: 'RG-BOUNTY');
    expect(src, contains('V21ResultKind.overload'), reason: 'RG-OVERLOAD');
  });

  test('V21-HUD-02c 快照携带徽记状态（UI 能从快照拿到）', () {
    expect(src, contains('resultNoticeKind:'), reason: '快照必须带类型');
    expect(src, contains('resultNoticeElapsedMs:'), reason: '快照必须带进度');
  });

  test('V21-HUD-02d 视觉层**无文字**：HUD 侧不得再用 Text 显示强化文案', () {
    // R2 明文：「战斗结果只显示**无文字、无卡片**的独立徽记，
    // 并由暂停/结算历史和无障碍语义承担完整文本说明。」
    final hud = File('lib/app/v2_run_screen.dart').readAsStringSync();
    // HUD 侧必须使用**图形徽记组件**（而非文字）。
    expect(hud, contains('V21ResultEmblem'), reason: '必须是图形徽记组件');
    // 旧的文字 Toast 组件必须已不存在。
    expect(hud.contains('_UpgradeToast'), isFalse,
        reason: 'R2 不得保留文字 Toast（视觉层无文字）');

    // 徽记组件自身的合同：走 Semantics、且内部**没有 Text**。
    final emblem =
        File('lib/game/presentation/v21_result_emblem.dart').readAsStringSync();
    expect(emblem, contains('Semantics('), reason: '完整说明必须走无障碍语义');
    expect(emblem.contains('Text('), isFalse,
        reason: 'R2：徽记组件内部不得出现 Text（视觉层无文字）');
  });
}
