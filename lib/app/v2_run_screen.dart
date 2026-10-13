// ================================================================
// lib/app/v2_run_screen.dart —— v2.0 对局屏幕（Flame + Flutter HUD）
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §6
//   「所有 UI 覆盖层必须在 Flutter 层；World 不承担升级卡、风险门、
//     暂停面板和结算按钮。」
//
// 产品基线 §8 的 HUD 固定区位：
//   左上 HP/护盾；顶部中间 Boss/倒计时；右上暂停和连击；
//   底部中间经验/LV；右下冲刺。
// 安全区：x = 48..1872，y = 36..1044（产品基线 §2）。
// ================================================================

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/core/game_phase.dart';
import '../game/core/game_runtime.dart';
import '../game/core/phase_controller.dart';
import '../game/core/render_snapshot.dart';
import '../game/presentation/input_gateway.dart';
import '../game/presentation/warship_v2_game.dart';

/// HUD 安全区（逻辑坐标）。
const Rect kHudSafeArea = Rect.fromLTRB(48, 36, 1872, 1044);

/// v2.0 对局屏幕。
class V2RunScreen extends StatefulWidget {
  const V2RunScreen({super.key, required this.runtime, required this.input});

  final GameRuntime runtime;
  final KeyboardInputGateway input;

  @override
  State<V2RunScreen> createState() => _V2RunScreenState();
}

class _V2RunScreenState extends State<V2RunScreen> with WidgetsBindingObserver {
  final FocusNode _focusNode = FocusNode(debugLabel: 'warship-v2');
  late final WarshipV2Game _game;

  RenderSnapshot _snapshot = RenderSnapshot.empty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _game = WarshipV2Game(
      runtime: widget.runtime,
      input: widget.input,
      onSnapshot: _onSnapshot,
    );
  }

  void _onSnapshot(RenderSnapshot snapshot) {
    // 只在有意义的字段变化时触发重建，避免每帧 60 次 setState 造成浪费。
    final previous = _snapshot;
    final changed =
        previous.hud == null ||
        snapshot.hud == null ||
        previous.hud!.hp != snapshot.hud!.hp ||
        previous.hud!.shield != snapshot.hud!.shield ||
        previous.hud!.xp != snapshot.hud!.xp ||
        previous.hud!.score != snapshot.hud!.score ||
        previous.hud!.dashCharges != snapshot.hud!.dashCharges ||
        previous.hud!.comboCount != snapshot.hud!.comboCount ||
        previous.phase != snapshot.phase;
    if (!changed) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _snapshot = snapshot);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 技术架构 §3.1：inactive/paused/detached 与浏览器 hidden 提交同一个
    // PauseRequested 命令；恢复不自动继续。
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _clearInputAndPause();
    }
  }

  void _clearInputAndPause() {
    widget.input.clear();
    final event = widget.runtime.phases.requestPause(PauseSource.appLifecycle);
    if (event != null) {
      widget.runtime.bus.emit(event, widget.runtime.runtime);
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.input.clear();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      widget.input.onKeyDown(key);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      widget.input.onKeyUp(key);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = ViewportMath(viewportSize: constraints.biggest);
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                GameWidget<WarshipV2Game>(game: _game),
                if (_snapshot.hud != null)
                  _HudOverlay(
                    hud: _snapshot.hud!,
                    phase: _snapshot.phase,
                    viewport: viewport,
                    onPause: _clearInputAndPause,
                    onResume: () {
                      widget.runtime.phases.requestResume();
                      setState(() {});
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// HUD 覆盖层。所有坐标都从逻辑安全区换算到屏幕空间。
class _HudOverlay extends StatelessWidget {
  const _HudOverlay({
    required this.hud,
    required this.phase,
    required this.viewport,
    required this.onPause,
    required this.onResume,
  });

  final HudView hud;
  final String phase;
  final ViewportMath viewport;
  final VoidCallback onPause;
  final VoidCallback onResume;

  /// 逻辑坐标 → 屏幕坐标。
  Offset _toScreen(double x, double y) {
    final origin = viewport.origin;
    final scale = viewport.scale;
    return Offset(origin.dx + x * scale, origin.dy + y * scale);
  }

  @override
  Widget build(BuildContext context) {
    final scale = viewport.scale;
    if (scale <= 0) {
      return const SizedBox.shrink();
    }
    final isPaused = phase == GamePhase.paused.name;

    return Stack(
      children: <Widget>[
        // 左上：HP / 护盾
        _at(
          kHudSafeArea.left,
          kHudSafeArea.top,
          _VitalsPanel(hud: hud, scale: scale),
        ),
        // 顶部中间：倒计时
        _atCentered(
          kHudSafeArea.center.dx,
          kHudSafeArea.top,
          _TimerPanel(hud: hud, scale: scale),
        ),
        // 右上：连击 + 暂停
        _atRightTop(
          kHudSafeArea.right,
          kHudSafeArea.top,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (hud.comboCount > 0)
                _SmallBadge(
                  text: 'x${hud.comboMultiplier.toStringAsFixed(1)}',
                  color: const Color(0xFFFFC24B),
                  scale: scale,
                ),
              SizedBox(width: 12 * scale),
              _IconButton(
                icon: isPaused ? Icons.play_arrow : Icons.pause,
                scale: scale,
                onTap: isPaused ? onResume : onPause,
              ),
            ],
          ),
        ),
        // 底部中间：经验 / Lv
        _atCentered(
          kHudSafeArea.center.dx,
          kHudSafeArea.bottom,
          _XpPanel(hud: hud, scale: scale),
          alignBottom: true,
        ),
        // 右下：冲刺
        _atRightBottom(
          kHudSafeArea.right,
          kHudSafeArea.bottom,
          _DashIndicator(hud: hud, scale: scale),
        ),
        if (isPaused) _PauseOverlay(onResume: onResume, scale: scale),
      ],
    );
  }

  Widget _at(double x, double y, Widget child) {
    final offset = _toScreen(x, y);
    return Positioned(left: offset.dx, top: offset.dy, child: child);
  }

  Widget _atCentered(
    double x,
    double y,
    Widget child, {
    bool alignBottom = false,
  }) {
    final offset = _toScreen(x, y);
    return Positioned(
      left: 0,
      right: 0,
      top: alignBottom ? null : offset.dy,
      bottom: alignBottom ? (viewport.viewportSize.height - offset.dy) : null,
      child: Center(child: child),
    );
  }

  Widget _atRightTop(double x, double y, Widget child) {
    final offset = _toScreen(x, y);
    return Positioned(
      right: viewport.viewportSize.width - offset.dx,
      top: offset.dy,
      child: child,
    );
  }

  Widget _atRightBottom(double x, double y, Widget child) {
    final offset = _toScreen(x, y);
    return Positioned(
      right: viewport.viewportSize.width - offset.dx,
      bottom: viewport.viewportSize.height - offset.dy,
      child: child,
    );
  }
}

class _VitalsPanel extends StatelessWidget {
  const _VitalsPanel({required this.hud, required this.scale});

  final HudView hud;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Bar(
          label: 'HP',
          value: hud.hpRatio,
          text: '${hud.hp}/${hud.hpMax}',
          color: const Color(0xFF3FE0FF),
          critical: hud.hpVisualState != 'normal',
          scale: scale,
        ),
        SizedBox(height: 8 * scale),
        _Bar(
          label: 'SHIELD',
          value: hud.shieldRatio,
          text: '${hud.shield}/${hud.shieldMax}',
          color: const Color(0xFF7C6BFF),
          critical: hud.shieldVisualState == 'critical',
          scale: scale,
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.label,
    required this.value,
    required this.text,
    required this.color,
    required this.critical,
    required this.scale,
  });

  final String label;
  final double value;
  final String text;
  final Color color;
  final bool critical;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final width = 320 * scale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '$label  $text',
          style: TextStyle(
            color: critical ? const Color(0xFFFF5C8A) : Colors.white70,
            fontSize: 16 * scale,
            fontWeight: critical ? FontWeight.bold : FontWeight.w500,
            letterSpacing: 1.2,
          ),
        ),
        SizedBox(height: 4 * scale),
        Container(
          width: width,
          height: 10 * scale,
          decoration: BoxDecoration(
            color: const Color(0x33FFFFFF),
            borderRadius: BorderRadius.circular(5 * scale),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: critical ? const Color(0xFFFF5C8A) : color,
                  borderRadius: BorderRadius.circular(5 * scale),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TimerPanel extends StatelessWidget {
  const _TimerPanel({required this.hud, required this.scale});

  final HudView hud;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final remaining = (190 - hud.combatSeconds).clamp(0, 190).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          remaining.toString().padLeft(3, '0'),
          style: TextStyle(
            color: Colors.white,
            fontSize: 34 * scale,
            fontWeight: FontWeight.bold,
            letterSpacing: 3,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        if (hud.objectiveWarning)
          Text(
            '敌人正在逃逸',
            style: TextStyle(
              color: const Color(0xFFFFB03A),
              fontSize: 15 * scale,
              fontWeight: FontWeight.bold,
            ),
          ),
      ],
    );
  }
}

class _XpPanel extends StatelessWidget {
  const _XpPanel({required this.hud, required this.scale});

  final HudView hud;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 420 * scale,
          height: 8 * scale,
          decoration: BoxDecoration(
            color: const Color(0x33FFFFFF),
            borderRadius: BorderRadius.circular(4 * scale),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: (hud.xp / 345).clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC24B),
                  borderRadius: BorderRadius.circular(4 * scale),
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: 6 * scale),
        Text(
          'Lv ${hud.upgradeLevel}   SCORE ${hud.score}',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 15 * scale,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

class _DashIndicator extends StatelessWidget {
  const _DashIndicator({required this.hud, required this.scale});

  final HudView hud;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < hud.dashMaxCharges; i++)
          Padding(
            padding: EdgeInsets.only(left: 8 * scale),
            child: Container(
              width: 22 * scale,
              height: 22 * scale,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < hud.dashCharges
                    ? const Color(0xFF3FE0FF)
                    : const Color(0x333FE0FF),
                border: Border.all(
                  color: const Color(0xAA3FE0FF),
                  width: 2 * scale,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({
    required this.text,
    required this.color,
    required this.scale,
  });

  final String text;
  final Color color;
  final double scale;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: color,
      fontSize: 22 * scale,
      fontWeight: FontWeight.bold,
    ),
  );
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.scale,
    required this.onTap,
  });

  final IconData icon;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 触控目标 ≥88×88（产品基线 §2）。
    final size = 56 * scale;
    return Semantics(
      button: true,
      label: '暂停',
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0x33FFFFFF),
            borderRadius: BorderRadius.circular(10 * scale),
            border: Border.all(color: const Color(0x55FFFFFF)),
          ),
          child: Icon(icon, color: Colors.white, size: 26 * scale),
        ),
      ),
    );
  }
}

class _PauseOverlay extends StatelessWidget {
  const _PauseOverlay({required this.onResume, required this.scale});

  final VoidCallback onResume;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xCC05030F),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '已暂停',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 42 * scale,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 24 * scale),
              FilledButton(
                onPressed: onResume,
                child: Text('继续', style: TextStyle(fontSize: 20 * scale)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
