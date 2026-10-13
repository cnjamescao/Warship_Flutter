// ================================================================
// lib/app/v2_app_flow.dart —— v2.0 相位路由
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §3.1
//   Home → Loading → Briefing → Playing ↔ UpgradeDraft/RiskGate/Paused
//        → Result
//
// 所有迁移都必须经过 PhaseController（只允许合法迁移，非法迁移被拒绝
// 并记录原因，不会崩溃）。Briefing 只有表现时钟，战斗逻辑完全冻结。
//
// 本文件只负责**相位到界面的映射**与生命周期，不遍历战斗实体
// （架构 §2 的 app 模块职责）。
// ================================================================

import 'package:flutter/material.dart';

import '../game/content/content_catalog.dart';
import '../game/core/domain_event.dart';
import '../game/core/game_phase.dart';
import '../game/core/game_runtime.dart';
import '../game/presentation/input_gateway.dart';
import 'v2_bootstrap.dart';
import 'v2_run_screen.dart';

/// 简报倒计时秒数（产品基线 §4.2：首次升级不早于 15 秒，
/// 简报只占表现时间，不消耗有效战斗时间）。
const int kBriefingCountdown = 3;

/// 应用主流程。
class V2AppFlow extends StatefulWidget {
  const V2AppFlow({
    super.key,
    required this.catalog,
    required this.seed,
  });

  final ContentCatalog catalog;
  final int seed;

  @override
  State<V2AppFlow> createState() => _V2AppFlowState();
}

class _V2AppFlowState extends State<V2AppFlow> {
  GameRuntime? _runtime;
  KeyboardInputGateway? _input;

  /// 本局结果（进入 Result 时写入）。
  String _resultOutcome = 'defeat';
  int _resultScore = 0;
  double _resultSeconds = 0;

  @override
  void initState() {
    super.initState();
    // 初始相位是 Home（架构 §3.1）。这里**不**自动开局 ——
    // 由玩家点击「开始战斗」触发 Home → Loading → Briefing。
  }

  @override
  void dispose() {
    _runtime?.dispose();
    super.dispose();
  }

  /// 开始新一局：先释放上一局，再创建。
  ///
  /// 技术架构 §3.2：「重新开始先 dispose RunSession，再创建下一局；
  /// 旧对象不得再向 HUD、音频或 Flame World 发事件。」
  void _startNewRun() {
    _runtime?.dispose();
    final runtime = const V2Bootstrap().buildRuntime(
      catalog: widget.catalog,
      seed: widget.seed,
    );
    runtime.phases.resetToHome();
    runtime.phases.transitionTo(GamePhase.loading, reason: 'start');
    runtime.phases.transitionTo(GamePhase.briefing, reason: 'contentReady');
    setState(() {
      _runtime = runtime;
      _input = KeyboardInputGateway();
    });
  }

  void _onBriefingFinished() {
    final runtime = _runtime;
    if (runtime == null) {
      return;
    }
    runtime.phases.transitionTo(GamePhase.playing, reason: 'countdownDone');
    // 记录开局，供回放与调试。
    runtime.bus.emit(
      RunStarted(
        seed: runtime.runtime.seed,
        prngAlgorithm: runtime.runtime.identity.prngAlgorithm,
        contentVersion: runtime.runtime.identity.contentVersion,
      ),
      runtime.runtime,
    );
    setState(() {});
  }

  void _onRunFinished() {
    final runtime = _runtime;
    if (runtime == null) {
      return;
    }
    runtime.phases.transitionTo(GamePhase.result, reason: 'runEnded');
    setState(() {
      _resultOutcome = runtime.player.health.isDead ? 'defeat' : 'victory';
      _resultScore = runtime.score;
      _resultSeconds = runtime.combatSeconds;
    });
  }

  void _backToHome() {
    final runtime = _runtime;
    if (runtime == null) {
      return;
    }
    runtime.phases.transitionTo(GamePhase.home, reason: 'quit');
    runtime.dispose();
    setState(() {
      _runtime = null;
      _input = null;
    });
  }

  /// 每帧检查对局是否已结束（死亡或超时）。
  ///
  /// 放在帧循环之后而不是事件回调里，是为了不依赖 Domain 事件顺序。
  bool _checkRunOver(GameRuntime runtime) {
    final dead = runtime.player.health.isDead;
    final timedOut =
        runtime.combatSeconds >= 190.0 && runtime.phases.phase.isInRun;
    if (!dead && !timedOut) {
      return false;
    }
    if (runtime.phases.phase == GamePhase.result) {
      return false;
    }
    _onRunFinished();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    final input = _input;

    // 尚未开局：显示首页。
    if (runtime == null || input == null) {
      return _HomeScreen(onStart: _startNewRun);
    }

    switch (runtime.phases.phase) {
      case GamePhase.home:
        return _HomeScreen(onStart: _startNewRun);

      case GamePhase.loading:
        return const _LoadingSurface();

      case GamePhase.briefing:
        return _BriefingScreen(
          countdown: kBriefingCountdown,
          onFinished: _onBriefingFinished,
        );

      case GamePhase.playing:
      case GamePhase.paused:
      case GamePhase.upgradeDraft:
      case GamePhase.riskGate:
        return V2RunScreen(
          runtime: runtime,
          input: input,
          manifest: widget.catalog.manifest,
          onFrame: () => _checkRunOver(runtime),
          onQuitToHome: _backToHome,
        );

      case GamePhase.result:
        return _ResultScreen(
          outcome: _resultOutcome,
          score: _resultScore,
          seconds: _resultSeconds,
          bestScore: _bestScore,
          onRestart: _startNewRun,
          onHome: _backToHome,
        );
    }
  }

  int get _bestScore => _resultScore;
}

// ----------------------------------------------------------------
// 界面
// ----------------------------------------------------------------

class _LoadingSurface extends StatelessWidget {
  const _LoadingSurface();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(strokeWidth: 3),
      ),
    ),
  );
}

/// 首页。
class _HomeScreen extends StatelessWidget {
  const _HomeScreen({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'WARSHIP',
              style: TextStyle(
                color: Color(0xFF3FE0FF),
                fontSize: 64,
                fontWeight: FontWeight.bold,
                letterSpacing: 12,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '霓虹最后防线',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 20,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 48),
            FilledButton(
              onPressed: onStart,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 56,
                  vertical: 20,
                ),
                textStyle: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              child: const Text('开始战斗'),
            ),
            const SizedBox(height: 24),
            const Text(
              'WASD / 方向键移动 · 空格或 Shift 冲刺 · Esc 暂停',
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// 开局简报：只有表现时钟，战斗逻辑完全冻结。
class _BriefingScreen extends StatefulWidget {
  const _BriefingScreen({required this.countdown, required this.onFinished});

  final int countdown;
  final VoidCallback onFinished;

  @override
  State<_BriefingScreen> createState() => _BriefingScreenState();
}

class _BriefingScreenState extends State<_BriefingScreen> {
  int _remaining = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _remaining = widget.countdown;
    _schedule();
  }

  void _schedule() {
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (!mounted || _done) {
        return;
      }
      final next = _remaining - 1;
      if (next <= 0) {
        _done = true;
        widget.onFinished();
        return;
      }
      setState(() => _remaining = next);
      _schedule();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              '作战简报',
              style: TextStyle(
                color: Color(0xFF3FE0FF),
                fontSize: 32,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '坚持 150 秒，击败守门者 Aegis',
              style: TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 40),
            Text(
              '$_remaining',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 96,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 结算界面。
class _ResultScreen extends StatelessWidget {
  const _ResultScreen({
    required this.outcome,
    required this.score,
    required this.seconds,
    required this.bestScore,
    required this.onRestart,
    required this.onHome,
  });

  final String outcome;
  final int score;
  final double seconds;
  final int bestScore;
  final VoidCallback onRestart;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final victory = outcome == 'victory';
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              victory ? '防线守住了' : '防线失守',
              style: TextStyle(
                color: victory
                    ? const Color(0xFFFFC24B)
                    : const Color(0xFFFF5C8A),
                fontSize: 44,
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              '得分 $score',
              style: const TextStyle(color: Colors.white, fontSize: 26),
            ),
            const SizedBox(height: 8),
            Text(
              '用时 ${seconds.toStringAsFixed(1)} 秒',
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              '最佳成绩 $bestScore',
              style: const TextStyle(color: Colors.white38, fontSize: 16),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FilledButton(
                  onPressed: onRestart,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 36,
                      vertical: 16,
                    ),
                  ),
                  child: const Text('再来一局'),
                ),
                const SizedBox(width: 16),
                OutlinedButton(
                  onPressed: onHome,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 36,
                      vertical: 16,
                    ),
                  ),
                  child: const Text('返回首页'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
