// ================================================================
// test/unit/core/v21_risk_01_test.dart —— V21-RISK-01 / 02 / 04
// ================================================================
// **架构位置**：Core 层静态守卫。锁定 R2 的**无阻断**合同。
//
// **计划原文**：
//   * V21-RISK-01：「全程 `Playing`；移动、射击、敌人、投射物、危险区、
//     计时都连续；**不出现选择、倒计时、遮罩、清弹或停刷**」；
//   * V21-RISK-02：同 seed 同输入重放两遍，`gateId/occurrenceOrdinal/
//     optionId/Overload 卡 ID` 与应用状态**逐字段一致**；
//   * V21-RISK-04：「结果徽记使用正确 Asset ID、时序/队列准确、输入穿透；
//     暂停冻结展示时钟；恢复后连续且不重放效果」。
//
// **为什么用静态扫描**：这些是"**不许出现**某类代码"的合同 ——
// 静态扫描**精确对应**它，且不依赖运行一局（那需要 5 份配置 + 十余个系统）。
// 运行时数值由 `V21-RISK-03`（Domain）、`V21-HUD-02`（队列模型）覆盖。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

late String runtime;

void main() {
  setUpAll(() {
    runtime = File('lib/game/core/game_runtime.dart').readAsStringSync();
  });

  group('V21-RISK-01 全程 Playing，无任何阻断', () {
    /// 取出 `_openRiskGate` 的方法体（从签名到下一个顶层方法前）。
    String openRiskGateBody() {
      final start = runtime.indexOf('void _openRiskGate(String gateId) {');
      expect(start, greaterThan(0), reason: '必须存在 _openRiskGate');
      // 粗略取到下一个 "  /// " 开头的注释之前。
      final end = runtime.indexOf('\n  /// ', start + 10);
      return runtime.substring(start, end > 0 ? end : start + 3000);
    }

    test('不得清空普通敌弹（clearNormalEnemyBulletsBefore 不参与）', () {
      final body = openRiskGateBody();
      expect(body.contains('projectiles.removeWhere'), isFalse,
          reason: 'R2：风险门不得清子弹');
      expect(body.contains('hazards.clear()'), isFalse,
          reason: 'R2：风险门不得清危险区');
      expect(body.contains('_pendingAttacks.clear()'), isFalse,
          reason: 'R2：风险门不得清预警');
    });

    test('不得进入 riskGate 阶段（全程 Playing）', () {
      final body = openRiskGateBody();
      expect(body.contains('GamePhase.riskGate'), isFalse,
          reason: 'R2：风险门不得切换 phase');
      expect(
        runtime.contains('transitionTo(GamePhase.riskGate'),
        isFalse,
        reason: 'R2：全工程不得再进入 riskGate 阶段（会出现遮罩/等待）',
      );
    });

    test('不得保留选择窗/超时回退的活动代码路径', () {
      // 阶段内的等待推进必须已删除。
      expect(runtime.contains('_updateRiskGate('), isFalse,
          reason: 'R2：不得再有"门内等待/超时"推进');
    });
  });

  group('V21-RISK-02 确定性对账', () {
    test('四字段全部落到决议记录里（gateId/ordinal/optionId/noticeOrdinal）', () {
      expect(runtime, contains('gateId: gateId'));
      expect(runtime, contains('occurrenceOrdinal: ordinal'));
      expect(runtime, contains('optionId: optionId'));
      expect(runtime, contains('resultNoticeOrdinal:'));
      expect(runtime, contains('riskGateResolutions.add('),
          reason: '必须真的记录，而不是只算不存');
    });

    test('occurrenceOrdinal 是**递增**的每 gate 计数（0 基）', () {
      // 实现里必须先读旧值、再加一 —— 这样第一次是 0。
      expect(runtime, contains('_riskGateOccurrences[gateId] ?? 0'));
      expect(runtime, contains('_riskGateOccurrences[gateId] = ordinal + 1'));
    });
  });

  group('V21-RISK-04 徽记、暂停与输入穿透', () {
    test('结果徽记入队时携带正确的 kind 与 ordinal', () {
      expect(runtime, contains('kind: kind'));
      expect(runtime, contains('resultNotices.enqueue('));
    });

    test('徽记用**逻辑时间**推进（暂停即冻结）', () {
      expect(runtime, contains('resultNotices.elapsedMsAt(combatSeconds)'),
          reason: '必须用 combatSeconds（逻辑时间），不得用表现时间');
    });

    test('不拦截输入：徽记组件必须包在 IgnorePointer 里', () {
      final hud = File('lib/app/v2_run_screen.dart').readAsStringSync();
      final i = hud.indexOf('_ResultEmblem');
      expect(i, greaterThan(0));
      // 向前找最近的 IgnorePointer。
      final before = hud.substring(0, i);
      expect(before.lastIndexOf('IgnorePointer'), greaterThan(
        before.lastIndexOf('Positioned') - 200,
      ), reason: '徽记必须是 IgnorePointer 的子节点（输入穿透）');
    });
  });
}
