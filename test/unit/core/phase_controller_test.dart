// ================================================================
// test/unit/core/phase_controller_test.dart —— 相位状态机
// ================================================================
// 覆盖：T-CORE-01（合法迁移）、T-CORE-02（冻结语义）、
//       技术架构 §3.1 的暂停/恢复合同（统一命令 + 幂等 + 不自动继续）
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/game_phase.dart';
import 'package:warship_flutter/game/core/phase_controller.dart';

void main() {
  group('T-CORE-01 合法状态迁移', () {
    test('标准开局链路 Home→Loading→Briefing→Playing 全部允许', () {
      final controller = PhaseController();

      expect(controller.phase, GamePhase.home);
      expect(controller.transitionTo(GamePhase.loading, reason: 'start'), isNotNull);
      expect(controller.transitionTo(GamePhase.briefing, reason: 'ready'), isNotNull);
      expect(controller.transitionTo(GamePhase.playing, reason: 'countdown'), isNotNull);
      expect(controller.phase, GamePhase.playing);
    });

    test('Loading 失败只能回 Home', () {
      final controller = PhaseController();
      controller.transitionTo(GamePhase.loading, reason: 'start');

      expect(controller.transitionTo(GamePhase.playing, reason: 'skip'), isNull);
      expect(controller.lastRejection, isNotNull);
      expect(controller.transitionTo(GamePhase.home, reason: 'failed'), isNotNull);
      expect(controller.phase, GamePhase.home);
    });

    test('Home 不能直达 Playing 或 Result', () {
      final controller = PhaseController();

      expect(controller.transitionTo(GamePhase.playing, reason: 'cheat'), isNull);
      expect(controller.transitionTo(GamePhase.result, reason: 'cheat'), isNull);
      expect(controller.phase, GamePhase.home);
    });

    test('Playing 可以进入草案、风险门、暂停与结算', () {
      for (final target in <GamePhase>[
        GamePhase.upgradeDraft,
        GamePhase.riskGate,
        GamePhase.paused,
        GamePhase.result,
      ]) {
        final controller = PhaseController(initialPhase: GamePhase.playing);
        expect(
          controller.transitionTo(target, reason: 'test'),
          isNotNull,
          reason: '${target.name} 应当可由 Playing 进入',
        );
      }
    });

    test('Result 只能重开或返回首页', () {
      final controller = PhaseController(initialPhase: GamePhase.result);

      expect(controller.transitionTo(GamePhase.playing, reason: 'cheat'), isNull);
      expect(controller.transitionTo(GamePhase.loading, reason: 'restart'), isNotNull);
    });

    test('迁移事件携带 from/to/reason，供回放与调试消费', () {
      final controller = PhaseController();
      final event = controller.transitionTo(GamePhase.loading, reason: 'start');

      expect(event, isNotNull);
      expect(event!.eventType, 'PhaseChanged');
      expect(event.from, 'home');
      expect(event.to, 'loading');
      expect(event.reason, 'start');
    });

    test('迁移到当前相位是幂等空操作，不产生重复事件', () {
      final controller = PhaseController(initialPhase: GamePhase.playing);

      expect(controller.transitionTo(GamePhase.playing, reason: 'noop'), isNull);
      expect(controller.lastRejection, isNull, reason: '这不是"非法"，而是"无需迁移"');
    });
  });

  group('T-CORE-02 冻结语义', () {
    test('只有 Playing 推进逻辑与接受战斗输入', () {
      for (final phase in GamePhase.values) {
        expect(
          phase.advancesLogic,
          phase == GamePhase.playing,
          reason: '${phase.name} 的 advancesLogic 判定错误',
        );
      }
    });

    test('草案、风险门、暂停冻结全部逻辑时钟', () {
      expect(GamePhase.upgradeDraft.freezesAllClocks, isTrue);
      expect(GamePhase.riskGate.freezesAllClocks, isTrue);
      expect(GamePhase.paused.freezesAllClocks, isTrue);

      expect(GamePhase.playing.freezesAllClocks, isFalse);
      expect(GamePhase.briefing.freezesAllClocks, isFalse);
      expect(GamePhase.home.freezesAllClocks, isFalse);
    });

    test('非 Playing 状态不接受战斗输入', () {
      expect(GamePhase.upgradeDraft.acceptsCombatInput, isFalse);
      expect(GamePhase.riskGate.acceptsCombatInput, isFalse);
      expect(GamePhase.paused.acceptsCombatInput, isFalse);
      expect(GamePhase.playing.acceptsCombatInput, isTrue);
    });
  });

  group('暂停命令合同', () {
    test('三种平台来源提交同一个命令，行为一致', () {
      for (final source in PauseSource.values) {
        final controller = PhaseController(initialPhase: GamePhase.playing);
        final event = controller.requestPause(source);

        expect(event, isNotNull, reason: '${source.name} 必须能暂停');
        expect(controller.phase, GamePhase.paused);
        expect(
          event!.reason,
          'pause:${source.name}',
          reason: '只记录来源标签，不改变行为',
        );
      }
    });

    test('重复暂停请求是幂等的，不产生第二条事件', () {
      final controller = PhaseController(initialPhase: GamePhase.playing);

      expect(controller.requestPause(PauseSource.appLifecycle), isNotNull);
      // 平台可能连续上报失焦。
      expect(controller.requestPause(PauseSource.windowBlur), isNull);
      expect(controller.requestPause(PauseSource.browserHidden), isNull);
      expect(controller.phase, GamePhase.paused);
    });

    test('恢复不会自动发生，必须显式请求', () {
      final controller = PhaseController(initialPhase: GamePhase.playing);
      controller.requestPause(PauseSource.browserHidden);

      // 模拟"页面重新可见"：没有调用 requestResume 就仍然暂停。
      expect(controller.phase, GamePhase.paused);
      expect(controller.isPaused, isTrue);

      final resumed = controller.requestResume();
      expect(resumed, isNotNull);
      expect(controller.phase, GamePhase.playing);
      expect(resumed!.reason, 'resume:user');
    });

    test('非 Playing 状态下暂停请求被拒绝（因为逻辑本就冻结）', () {
      for (final phase in <GamePhase>[
        GamePhase.home,
        GamePhase.loading,
        GamePhase.briefing,
        GamePhase.upgradeDraft,
        GamePhase.riskGate,
        GamePhase.result,
      ]) {
        final controller = PhaseController(initialPhase: phase);
        expect(
          controller.requestPause(PauseSource.userRequest),
          isNull,
          reason: '${phase.name} 不应进入暂停',
        );
        expect(controller.phase, phase);
      }
    });

    test('未暂停时请求恢复被拒绝', () {
      final controller = PhaseController(initialPhase: GamePhase.playing);
      expect(controller.requestResume(), isNull);
      expect(controller.lastRejection, isNotNull);
    });

    test('暂停菜单可以重新开始或返回首页', () {
      final restart = PhaseController(initialPhase: GamePhase.paused);
      expect(restart.transitionTo(GamePhase.loading, reason: 'restart'), isNotNull);

      final quit = PhaseController(initialPhase: GamePhase.paused);
      expect(quit.transitionTo(GamePhase.home, reason: 'quit'), isNotNull);
    });
  });

  group('复位', () {
    test('resetToHome 清空相位与拒绝记录', () {
      final controller = PhaseController(initialPhase: GamePhase.playing);
      controller.transitionTo(GamePhase.briefing, reason: 'illegal');

      controller.resetToHome();

      expect(controller.phase, GamePhase.home);
      expect(controller.lastRejection, isNull);
    });
  });
}
