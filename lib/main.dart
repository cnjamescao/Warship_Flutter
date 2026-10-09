// ================================================================
// main.dart —— 应用入口与主界面（Flutter 外壳层）
// ================================================================
//
// 职责（规格 §4 架构表「GameScreen」一行）：
//   Flutter 布局、HUD / 遮罩、**焦点桥接**、创建与释放游戏。
//
// 相对旧实现的三处关键改动：
//   1. 【P2 生命周期】实现 dispose()，在其中调用 game.close()，
//      并注销生命周期观察者 —— 资源所有权唯一且明确。
//   2. 【P1 失焦】实现 WidgetsBindingObserver：
//      窗口失焦 / 应用切后台时立刻清空输入，杜绝"粘键"。
//   3. 【已批准新增】HUD 增加静音开关。
//
// 注意：这里**不**参与任何游戏规则。
// 逻辑画布、碰撞、计分全部在 game/ 目录下，UI 只做只读订阅。
// ================================================================

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'game/game_audio.dart';
import 'game/game_session.dart';
import 'game/warship_game.dart';

/// 程序入口。
void main() {
  runApp(const WarshipApp());
}

/// 应用根组件。
class WarshipApp extends StatelessWidget {
  const WarshipApp({super.key, this.audio});

  /// 允许注入音效实现（测试用）。为 null 时使用真实音频。
  final GameAudio? audio;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Warship',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: GameScreen(audio: audio),
    );
  }
}

/// 游戏画面。
class GameScreen extends StatefulWidget {
  const GameScreen({super.key, this.game, this.audio});

  /// 允许注入游戏实例（测试用，便于 await `game.ready`）。为 null 时自行创建。
  final WarshipGame? game;

  /// 允许注入音效实现（测试用）。[game] 非空时本参数被忽略。
  final GameAudio? audio;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  /// 游戏实例。本 State **拥有**它，并负责在 dispose 时释放。
  late final WarshipGame _game;

  static const TextStyle _hudStyle = TextStyle(
    color: Colors.black87,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  @override
  void initState() {
    super.initState();
    // 注册生命周期观察者，用于把"窗口失焦"桥接给游戏层。
    WidgetsBinding.instance.addObserver(this);
    _game = widget.game ?? WarshipGame(audio: widget.audio);
  }

  /// 应用生命周期变化。
  ///
  /// 规格 §4.2：「失焦 | 清空输入」。
  /// 在 macOS 上切走窗口会进入 inactive / hidden，
  /// 此时系统不保证补发 KeyUpEvent，必须主动清空输入，
  /// 否则用户切回来会发现飞船在持续移动或射击。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _game.handleFocusLost();
    }
  }

  @override
  void dispose() {
    // 先注销观察者，再释放游戏，避免释放后仍收到生命周期回调。
    WidgetsBinding.instance.removeObserver(this);
    // close() 是幂等的，重复调用安全。
    _game.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 与逻辑画布之外的 letterbox 区域保持同色，
      // 避免窗口比例与 4:3 不一致时出现色差边框。
      backgroundColor: _game.config.letterboxColor,
      body: SizedBox.expand(
        child: Stack(
          children: <Widget>[
            // ① 底层：Flame 画布。
            //   固定 800×600 逻辑画布由 Flame 的 viewport 负责等比缩放与留边，
            //   所以这里不需要 Flutter 侧再套 AspectRatio。
            Positioned.fill(child: GameWidget(game: _game)),
            // ② HUD
            _buildHud(),
            // ③ 遮罩（菜单 / 结束）
            Positioned.fill(child: _buildOverlay()),
            // ④ 音效控制
            //   必须叠在遮罩【之上】：遮罩是铺满全屏的半透明容器，
            //   会吞掉点击；如果静音按钮放在 HUD 层里，菜单/结束界面下就按不动。
            _buildAudioControl(),
          ],
        ),
      ),
    );
  }

  Widget _buildHud() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        // 三等分：左 / 中 / 右，保证在任意窗口宽度下都不溢出。
        //
        // 注意：这里刻意**不用** Align 做水平对齐。
        // Align 在 Expanded 内会撑满整个可用高度，再用 Alignment.centerXxx
        // （它含垂直居中语义）摆放子组件，会把整条 HUD 拉到屏幕垂直中线附近。
        // 正确做法是把对齐交给 FittedBox 自己的 alignment ——
        // FittedBox 只按内容大小占位，不会撑高。
        child: Row(
          children: <Widget>[
            Expanded(
              child: _fitted(
                ValueListenableBuilder<int>(
                  valueListenable: _game.session.livesNotifier,
                  builder: (context, lives, _) =>
                      Text('Ships: $lives', style: _hudStyle),
                ),
                alignment: Alignment.centerLeft,
              ),
            ),
            Expanded(
              child: _fitted(
                ValueListenableBuilder<int>(
                  valueListenable: _game.session.highScoreNotifier,
                  builder: (context, highScore, _) =>
                      Text('High Score: $highScore', style: _hudStyle),
                ),
                alignment: Alignment.center,
              ),
            ),
            Expanded(
              child: _fitted(
                ValueListenableBuilder<int>(
                  valueListenable: _game.session.scoreNotifier,
                  builder: (context, score, _) =>
                      Text('Score: $score', style: _hudStyle),
                ),
                alignment: Alignment.centerRight,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 窗口变窄时把内容等比缩小，而不是抛 RenderFlex 溢出。
  ///
  /// 规格 §3.2 要求 HUD 在真实窗口布局且不能被裁切；
  /// 用户把窗口拖到很小时也必须安全（T07）。
  Widget _fitted(Widget child, {Alignment alignment = Alignment.center}) =>
      FittedBox(fit: BoxFit.scaleDown, alignment: alignment, child: child);

  /// 音效控制层：右下角，浮在遮罩之上。
  Widget _buildAudioControl() {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _buildMuteButton(),
        ),
      ),
    );
  }

  /// 静音开关。
  Widget _buildMuteButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: _game.audio.mutedNotifier,
      builder: (context, muted, _) => IconButton(
        color: Colors.black87,
        tooltip: muted ? '取消静音' : '静音',
        onPressed: _game.audio.toggleMute,
        icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
      ),
    );
  }

  Widget _buildOverlay() {
    return ValueListenableBuilder<GameState>(
      valueListenable: _game.session.stateNotifier,
      builder: (context, state, _) {
        if (state == GameState.playing) {
          return const SizedBox.shrink();
        }

        return Container(
          color: Colors.black45,
          alignment: Alignment.center,
          // 窗口过小时整体等比缩小，避免 Column 纵向溢出（T07）。
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _overlayChildren(state),
            ),
          ),
        );
      },
    );
  }

  /// 按状态组装遮罩内容。
  ///
  /// 对应规格 §2 状态表：
  ///   menu     → 标题 + Play
  ///   paused   → 暂停菜单（恢复 / 重开）
  ///   gameOver → 结算 + Play Again
  List<Widget> _overlayChildren(GameState state) {
    switch (state) {
      case GameState.menu:
        return <Widget>[
          _overlayTitle('Alien Invasion'),
          const SizedBox(height: 24),
          _primaryButton(label: 'Play', onPressed: _game.startNewGame),
        ];

      case GameState.paused:
        return <Widget>[
          _overlayTitle('Paused'),
          const SizedBox(height: 8),
          const Text(
            'Esc / P to resume',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 24),
          _primaryButton(label: 'Resume', onPressed: _game.resume),
          const SizedBox(height: 4),
          _secondaryButton(label: 'Restart', onPressed: _game.startNewGame),
        ];

      case GameState.gameOver:
        return <Widget>[
          _overlayTitle('Game Over'),
          const SizedBox(height: 12),
          ValueListenableBuilder<int>(
            valueListenable: _game.session.scoreNotifier,
            builder: (context, score, _) => Text(
              'Score: $score',
              style: const TextStyle(color: Colors.white, fontSize: 22),
            ),
          ),
          const SizedBox(height: 24),
          _primaryButton(label: 'Play Again', onPressed: _game.startNewGame),
        ];

      // playing 不会走到这里（上层已提前返回），列出来只为让 switch 穷尽。
      case GameState.playing:
        return const <Widget>[];
    }
  }

  Widget _overlayTitle(String text) => Text(
    text,
    style: const TextStyle(
      color: Colors.white,
      fontSize: 42,
      fontWeight: FontWeight.bold,
    ),
  );

  Widget _primaryButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return FilledButton(
      onPressed: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Text(label, style: const TextStyle(fontSize: 20)),
      ),
    );
  }

  Widget _secondaryButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return TextButton(
      onPressed: onPressed,
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }
}
