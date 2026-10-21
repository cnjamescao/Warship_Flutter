// ================================================================
// test/architecture/dead_phase_test.dart —— 死阶段守卫
// ================================================================
// **架构位置**：架构守卫。锁定 v2.1 之后**两个历史阶段不再被进入**。
//
// **背景**：
//   * `upgradeDraft` —— v2.1 用"达标即自动授予"取代三选一；
//   * `riskGate`    —— v2.1-R2 用"到点自动结算"取代选择窗。
//
// 这两个阶段**暂时不能删**：`InputFrame.cardSelection` /
// `riskSelection` 仍在**回放格式**里，删阶段前必须先做格式迁移。
// 但在那之前，必须保证**正常对局永远不会进入它们** ——
// 否则 R2 的"全程无阻断"就是空文 ✗。
//
// 每条断言都能失败（R6.2）：把任一阶段重新接回正常流程，本文件即失败。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

late String runtime;
late String phases;

void main() {
  setUpAll(() {
    runtime = File('lib/game/core/game_runtime.dart').readAsStringSync();
    phases = File('lib/game/core/game_phase.dart').readAsStringSync();
  });

  test('两个死阶段必须**标注 @Deprecated 并说明删除前提**', () {
    for (final name in <String>['upgradeDraft', 'riskGate']) {
      // 枚举定义前必须有一段 @Deprecated。
      final i = phases.indexOf('\n  $name,');
      expect(i, greaterThan(0), reason: '$name 必须在枚举里');
      final before = phases.substring(i - 400 < 0 ? 0 : i - 400, i);
      expect(
        before.contains('@Deprecated'),
        isTrue,
        reason: '$name 必须标注 @Deprecated（否则后人不知道它已死）',
      );
      expect(
        before.contains('回放格式'),
        isTrue,
        reason: '$name 的注释必须写明**删除前提**是回放格式迁移',
      );
    }
  });

  test('正常对局**不得**进入 upgradeDraft', () {
    // 除兼容分支外，运行时不应主动 transition 到该阶段。
    final hits = RegExp(r'transitionTo\(GamePhase\.upgradeDraft')
        .allMatches(runtime)
        .length;
    // 允许 0 处；若确实需要（例如旧回放播放），必须在注释里说明。
    if (hits > 0) {
      expect(
        runtime.contains('旧回放') || runtime.contains('legacy'),
        isTrue,
        reason: '若仍有 transitionTo(upgradeDraft)，必须是明确的兼容分支并注明',
      );
    }
  });

  test('正常对局**不得**进入 riskGate', () {
    expect(
      runtime.contains('transitionTo(GamePhase.riskGate'),
      isFalse,
      reason: 'R2 明文：风险门不得切换 phase（会造成遮罩/等待）',
    );
  });

  test('R2 的自动结算路径仍然存在（删阶段不得连功能一起删）', () {
    expect(runtime, contains('_openRiskGate'),
        reason: '风险门本身仍要触发，只是不进入等待阶段');
    expect(runtime, contains('riskGateResolutions.add('),
        reason: '结算记录必须保留（回放对账依赖它）');
  });
}
