// ================================================================
// lib/app/v2_run_screen.dart —— v2.0 对局屏幕（Flame + Flutter HUD）
//
// **架构位置**：Presentation 层 —— **只读快照、只画画面**。
//   本层**不持有任何规则状态**，不得反向修改 Domain/Core。
//
// **与谁交互**：
//   * 上游：`GameRuntime.snapshot()`（每帧一份**不可变**快照）；
//     资源来自 `VisualAssetCache`（manifest 驱动）
//   * 下游：Flame 的 `Canvas` / Flutter 的 Widget 树
//
// **关键约束**：
//   * **表现不得影响规则** —— 由
//     `acceptance_visual_must_not_affect_rules_test.dart` 守住
//   * **只用 manifest 绑定的正式素材**；产品裁决明确
//     **禁止用 Canvas 几何替代资源**（F-12 / F-37）
//   * 任何"素材确实被绘制"的断言都必须能**从渲染器自身取证** ——
//     为此本层维护绘制记录（见下）
//
// **⚠️ 易错点（真实事故）**：
//
//   1. **HUD 必须锚定"窗口边缘"，不能用世界坐标反向计算。**
//      产品裁决：「**无论窗口大小，HUD 都应该在顶部**」。
//      此前反向锚定写成 `bottom: 窗口高 − y × scale` —— 那是"距窗口**顶**"
//      的位置，窗口越高越窄它越往中间浮（1000×1000 窗口下浮到距底 **456px**，
//      接近窗口中央；全屏 1920×1080 恰好 36px 所以看不出问题）。
//      现改为「距窗口边的固定边距」`(逻辑尺寸 − 逻辑坐标) × scale`，
//      与窗口尺寸无关。由 `hud_anchor_test.dart` 静态守住。
//      **注意**：战场**仍**保边（不拉伸逻辑世界，AC-02 仍成立）——
//      HUD 贴窗口与战场保边是**两条并存**的口径。
//
//   2. **焦点判断必须用 `hasPrimaryFocus`，不能用 `hasFocus`。**
//      Flutter 的 `hasFocus` 语义是"本节点**或任一后代**持有主焦点" ——
//      用它判断会导致键盘输入被静默丢弃（F-26-01，P0）。
//
//   3. **草案卡文案必须经 `catalog.text(nameKey/descKey)` 解析**，
//      绝不可直接渲染 `cardId` / `descKey` 原文 —— 那会把内部 ID 与
//      未解析 Key 展示给玩家（F-25-01）。`text()` 是 fail-fast 的。
//
//   4. **本层只读快照与运行时句柄**，不得持有可变的实体状态。
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
// Flutter 也导出一个 AssetManifest，这里用我们自己的内容模型。
import 'package:flutter/services.dart' hide AssetManifest;

import '../game/core/game_phase.dart';
import '../game/core/game_runtime.dart';
import '../game/core/phase_controller.dart';
import '../game/content/asset_manifest.dart';
import '../game/content/content_catalog.dart';
import '../game/core/baseline_recorder.dart';
import '../game/core/render_snapshot.dart';
import '../game/presentation/asset_cache.dart';
import '../game/presentation/v21_result_notice.dart';
import '../game/presentation/v21_result_emblem.dart';
import '../game/presentation/input_gateway.dart';
import '../game/presentation/warship_v2_game.dart';

/// HUD 安全区（逻辑坐标）。
const Rect kHudSafeArea = Rect.fromLTRB(48, 36, 1872, 1044);

/// v2.0 对局屏幕。
class V2RunScreen extends StatefulWidget {
  const V2RunScreen({
    super.key,
    required this.runtime,
    required this.input,
    required this.manifest,
    required this.catalog,
    this.baselineRecorder,
    this.onFrame,
    this.onQuitToHome,
    this.preloadAssets = true,
    this.assetCache,
    this.reduceMotion = false,
  });

  final GameRuntime runtime;
  final KeyboardInputGateway input;
  final AssetManifest manifest;

  /// AC-06 基准录制器（协议 §5.1）。**默认 null —— 不录制**。
  /// 只有基准操作员那一次真实通关才由 `--dart-define` 开启。
  final BaselineRecording? baselineRecorder;

  /// 内容目录 —— **玩家可见文本的唯一来源**（F-01）。
  /// HUD/风险门/草案/暂停的每一句文案都从它按 key 取。
  final ContentCatalog catalog;

  /// 见 `WarshipV2Game.preloadAssets`。生产恒为 `true`。
  final bool preloadAssets;

  /// **F-40**：可注入的**已预填**资源缓存。
  ///
  /// 生产恒为 `null`（由本页新建并按 `preloadAssets` 加载）。
  ///
  /// 存在理由：`testWidgets` 处于**假异步区**，`rootBundle` 的真实 I/O
  /// 永不完成，因此测试脚手架一律传 `preloadAssets: false`，
  /// 表现层随即退回**矢量占位** —— 于是 Golden 截到的是"无素材回退图"，
  /// **不能作为视觉验收证据**（F-40）。
  ///
  /// 正确做法：测试先用 `tester.runAsync` 把素材**真实加载**进一个
  /// `VisualAssetCache`，再把它注入这里 —— 此时 `imageFor` 返回的是
  /// 正式贴图，画面即发布路径。
  final VisualAssetCache? assetCache;

  /// 见 `WarshipV2Game.reduceMotion`。来自本地设置。
  final bool reduceMotion;

  /// 每个渲染帧之后回调，供上层判断对局是否结束。
  final VoidCallback? onFrame;

  /// 暂停菜单里的「返回首页」。
  final VoidCallback? onQuitToHome;

  @override
  State<V2RunScreen> createState() => _V2RunScreenState();
}

class _V2RunScreenState extends State<V2RunScreen> with WidgetsBindingObserver {
  final FocusNode _focusNode = FocusNode(debugLabel: 'warship-v2');
  late final WarshipV2Game _game;

  /// **F-40 诊断**：只读暴露本页的 `WarshipV2Game`。
  ///
  /// 存在理由：Golden 需要断言"某个正式素材**确实被绘制**"，
  /// 而这只能从渲染器自身的绘制记录读取（见 `drawnAssetMaxRadius`），
  /// 不能靠"运行时出现过该 attackId"推断。
  WarshipV2Game get game => _game;

  RenderSnapshot _snapshot = RenderSnapshot.empty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _game = WarshipV2Game(
      baselineRecorder: widget.baselineRecorder,
      preloadAssets: widget.preloadAssets,
      reduceMotion: widget.reduceMotion,
      runtime: widget.runtime,
      input: widget.input,
      visualAssets:
          widget.assetCache ?? VisualAssetCache(manifest: widget.manifest),
      onSnapshot: _onSnapshot,
      onFrame: widget.onFrame,
    );

    // F-26-01：**可靠地把键盘焦点交给游戏**。
    //
    // 此前只依赖 `Focus(autofocus: true)`，但在
    // Home → Loading → Briefing → Playing 的**正常重建链路**后，
    // 该节点并没有拿到焦点 —— 玩家必须额外点一下画布才能控制，
    // 而产品基线规定 WASD/方向键**开局即可用**。
    //
    // 放在 post-frame 而不是构造里：autofocus 的焦点分配发生在
    // 首帧构建期间，此时立刻 requestFocus 会被随后的分配覆盖。
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureGameFocus());
  }

  /// 把焦点交给游戏 —— 仅在**可玩**相位抢，避免从暂停/草案/结算
  /// 覆盖层手里夺走焦点（那样玩家就无法用键盘操作菜单）。
  void _ensureGameFocus() {
    if (!mounted) {
      return;
    }
    // ⚠️ 必须用 `hasPrimaryFocus`，**不能用 `hasFocus`**。
    //
    // `hasFocus` 的语义是"**本节点或其任一子节点**持有 primary focus"，
    // 因此当实际的 primary focus 落在某个匿名子节点上时，
    // `warship-v2.hasFocus` 仍为 true —— 于是这里会误判"已聚焦"而跳过
    // requestFocus，键事件便永远到不了游戏。
    // 这正是玩家按 A 不动的直接原因（实测：焦点探针显示 hasFocus=true，
    // 但网关的 pressedKeys 为空）。
    if (_focusNode.hasPrimaryFocus) {
      return;
    }
    // 注意： 是**字符串**（表现层不该依赖相位枚举）。
    if (_snapshot.phase != GamePhase.playing.name) {
      return;
    }
    _focusNode.requestFocus();
  }

  /// 相位变化后补交焦点（覆盖层关闭 → 回到 Playing 时必须恢复键盘控制）。
  void _afterPhaseSettled() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureGameFocus());
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
    final phaseChanged = previous.phase != snapshot.phase;
    if (!mounted) {
      return;
    }
    setState(() => _snapshot = snapshot);
    // F-26-01：相位变化（含覆盖层关闭回到 Playing）后重新交还焦点。
    if (phaseChanged) {
      _afterPhaseSettled();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 技术架构 §3.1：inactive/paused/detached 与浏览器 hidden 提交同一个
    // PauseRequested 命令；恢复不自动继续。
    //
    // `hidden` 是 Flutter 对浏览器 `visibilitychange(hidden)` 的映射
    // （切标签页、最小化、锁屏）。它与 inactive/paused 走**完全相同**的
    // 分支，不区分平台 —— 这样就不会出现"某个平台忘了暂停"的漏洞。
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _clearInputAndPause();
    }
  }

  /// 选择升级卡（产品基线 §4.2 的三选一）。
  void _selectCard(int index) {
    final runtime = widget.runtime;
    if (runtime.selectDraftCard(index)) {
      setState(() => _snapshot = runtime.snapshot());
    }
  }

  /// 选择风险门选项（产品基线 §7.1）。
  void _selectRisk(String optionId) {
    final runtime = widget.runtime;
    if (runtime.selectRiskOption(optionId)) {
      setState(() => _snapshot = runtime.snapshot());
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
  void didUpdateWidget(V2RunScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 设置是**异步加载**的：`_game` 在 initState 里创建时
    // `reduceMotion` 往往还是默认值 false。若不在 widget 更新时同步，
    // 这个开关就永远到不了游戏（实测过：开关打开后画面像素级不变）。
    if (widget.reduceMotion != oldWidget.reduceMotion) {
      _game.reduceMotion = widget.reduceMotion;
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
                    catalog: widget.catalog,
                    hud: _snapshot.hud!,
                    phase: _snapshot.phase,
                    viewport: viewport,
                    draft: _snapshot.upgradeDraft,
                    onSelectCard: _selectCard,
                    riskGate: _snapshot.riskGate,
                    onSelectRisk: _selectRisk,
                    onPause: _clearInputAndPause,
                    onResume: () {
                      widget.runtime.phases.requestResume();
                      setState(() {});
                    },
                    onQuitToHome: widget.onQuitToHome,
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
    required this.catalog,
    required this.hud,
    required this.phase,
    required this.viewport,
    required this.onPause,
    required this.onResume,
    this.onQuitToHome,
    this.draft,
    this.onSelectCard,
    this.riskGate,
    this.onSelectRisk,
  });

  /// F-01：文案只从内容目录按 key 取，不硬编码。
  final ContentCatalog catalog;

  final HudView hud;
  final String phase;
  final ViewportMath viewport;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback? onQuitToHome;
  final DraftView? draft;
  final void Function(int index)? onSelectCard;
  final RiskGateView? riskGate;
  final void Function(String optionId)? onSelectRisk;

  /// 逻辑坐标 → 屏幕坐标（**HUD 锚定窗口**）。
  ///
  /// 产品裁决：「**无论窗口大小，HUD 都应该在顶部**」。
  ///
  /// 此前这里加上 `viewport.origin`（**留黑边的居中偏移**），因此窗口
  /// 不是 16:9 时，世界被居中并留边，HUD 也跟着往下掉 ——
  /// 全屏（16:9）时看不出问题，非全屏时 HUD 就不贴顶了。
  ///
  /// 现在 HUD **忽略黑边偏移、只用缩放**：战场仍然 letterbox
  /// （不拉伸逻辑世界，AC-02 仍然成立），但 HUD 始终贴着窗口边缘。
  Offset _toScreen(double x, double y) {
    final scale = viewport.scale;
    return Offset(x * scale, y * scale);
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
        // **v2.1 强化 Toast**（冻结表 §2.3）：固定右上安全区，
        // 位置由 `toastRectFor()` 按视口算；不参与输入（`IgnorePointer`）。
        // **v2.1-R2 结果徽记**（冻结表 §2.3）：
        // * **无文字、无卡片、无边框**，只有图形；
        // * 完整说明只走无障碍语义（`Semantics.label`）；
        // * 固定右上安全区 `1728,28,132×176`，窄屏等比且距边 ≥24；
        // * 时序 90/580/330 = 1000ms，缩放与不透明度来自 `V21EmblemTiming`。
        if (hud.resultNoticeKind != null)
          Positioned.fromRect(
            rect: emblemRectFor(
              viewport.viewportSize.width,
              viewport.viewportSize.height,
            ),
            child: IgnorePointer(
              child: V21ResultEmblem(
                kind: hud.resultNoticeKind!,
                args: hud.resultNoticeArgs,
                elapsedMs: hud.resultNoticeElapsedMs,
                catalog: catalog,
              ),
            ),
          ),
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
          _TimerPanel(hud: hud, scale: scale, catalog: catalog),
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
                catalog: catalog,
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
        if (riskGate != null && onSelectRisk != null)
          _RiskGateOverlay(
            catalog: catalog,
            gate: riskGate!,
            scale: scale,
            onSelect: onSelectRisk!,
          ),
        if (draft != null && onSelectCard != null)
          _DraftOverlay(
            catalog: catalog,
            draft: draft!,
            scale: scale,
            onSelect: onSelectCard!,
          ),
        if (isPaused)
          _PauseOverlay(
            catalog: catalog,
            onResume: onResume,
            onQuitToHome: onQuitToHome,
            scale: scale,
          ),
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
    final scale = viewport.scale;
    return Positioned(
      left: 0,
      right: 0,
      // 顶部元素：距窗口顶 = 逻辑 y × scale（y 就是距世界顶的距离）。
      top: alignBottom ? null : y * scale,
      // 底部元素：距窗口底 = (逻辑世界高 − y) × scale，即**距世界底的边距**。
      //
      // ⚠️ 这里此前写的是「窗口高 − y × scale」—— 那等于把元素锚在
      // **距窗口顶** y×scale 的位置，于是窗口越高越窄，它越往中间浮
      //（1000×1000 的窗口下浮到距底 456px，接近窗口中央；
      //  1920×1080 全屏时恰好是 36px 所以看不出问题）。
      // 现在改为「距窗口底的固定边距」，与窗口尺寸无关 ——
      // 与顶部元素对称，HUD 四周都贴窗口边。
      bottom: alignBottom
          ? ((kLogicalHeight - y) * scale).clamp(0.0, double.infinity)
          : null,
      child: Center(child: child),
    );
  }

  /// 右侧元素：距窗口右 = (逻辑世界宽 − x) × scale，即**距世界右边缘的边距**。
  ///
  /// ⚠️ 与底部同源的问题：此前写「窗口宽 − x × scale」= 锚在**距窗口左**
  /// x×scale 处，于是超宽窗口（世界被居中留边）下元素会远离右边缘。
  Widget _atRightTop(double x, double y, Widget child) {
    final scale = viewport.scale;
    return Positioned(
      right: ((kLogicalWidth - x) * scale).clamp(0.0, double.infinity),
      top: y * scale,
      child: child,
    );
  }

  /// 右下角元素：两边都用**距窗口边的固定边距**，与窗口尺寸无关。
  Widget _atRightBottom(double x, double y, Widget child) {
    final scale = viewport.scale;
    return Positioned(
      right: ((kLogicalWidth - x) * scale).clamp(0.0, double.infinity),
      bottom: ((kLogicalHeight - y) * scale).clamp(0.0, double.infinity),
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
  const _TimerPanel({
    required this.hud,
    required this.scale,
    required this.catalog,
  });

  /// F-01：文案只从内容目录按 key 取。
  final ContentCatalog catalog;

  final HudView hud;
  final double scale;

  @override
  Widget build(BuildContext context) {
    // **v2.1（冻结表 §4）**：
    // 「顶部中间从 v2.1 起**不得显示** `190-combatSeconds` 或裸数字。
    //   UI **只能**从 `objectiveKey`/`objectiveArgs` 显示文案，
    //   **不能自行根据时间猜测**。」
    //
    // 因此这里**不再自己算秒数** —— 一切都来自规则层填好的字段。
    // 这不是"少了个倒计时"，而是**目标提示从裸数字改成了语义文案**。
    final key = hud.objectiveKey;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (key != null)
          Text(
            catalog.text(key, Map<String, Object?>.from(hud.objectiveArgs)),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 22 * scale,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
        if (hud.isSectorClearConfirming)
          Text(
            catalog.text('objective.sectorClear'),
            style: TextStyle(
              color: const Color(0xFF6BE59A),
              fontSize: 18 * scale,
              fontWeight: FontWeight.bold,
            ),
          ),
        if (hud.objectiveWarning)
          Text(
            catalog.text('hud.objective.warning'),
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
    required this.catalog,
    required this.icon,
    required this.scale,
    required this.onTap,
  });

  /// F-01：文案只从内容目录按 key 取。
  final ContentCatalog catalog;

  final IconData icon;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 触控目标 ≥88×88（产品基线 §2）。
    final size = 56 * scale;
    return Semantics(
      button: true,
      // **F-25-03 修复**：语义标签必须描述**本控件会执行的动作**。
      //
      // 此前这里用的是 `pause.title`，而该 key 的文案是「**已暂停**」——
      // 那是一个**状态描述**，用于暂停覆盖层的标题（见下方覆盖层 ✓）。
      // 把它用在**运行中**的暂停按钮上，会让读屏软件在玩家**并未暂停**时
      // 播报「已暂停」—— 即 F-25-03 的实测现象「辅助标签描述了错误状态」。
      //
      // 运行中的按钮动作是「暂停」，故改用 `hud.pauseAria`。
      label: catalog.text('hud.pauseAria'),
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

/// 风险门覆盖层。
///
/// 5 秒选择窗口；未选择或窗口外点击一律执行保底（`RG-SUPPLY`）。
/// HP ≤35 时过载**可见但锁定**，且不进入可选项列表。
class _RiskGateOverlay extends StatelessWidget {
  const _RiskGateOverlay({
    required this.catalog,
    required this.gate,
    required this.scale,
    required this.onSelect,
  });

  /// F-01：文案只从内容目录按 key 取，不硬编码。
  final ContentCatalog catalog;

  final RiskGateView gate;
  final double scale;
  final void Function(String optionId) onSelect;

  Map<String, String> get _labels => <String, String>{
    'RG-SUPPLY': catalog.text('risk.supply.name'),
    'RG-BOUNTY': catalog.text('risk.bounty.name'),
    'RG-OVERLOAD': catalog.text('risk.overload.name'),
  };

  Map<String, String> get _descriptions => <String, String>{
    'RG-SUPPLY': catalog.text('risk.supply.desc'),
    'RG-BOUNTY': catalog.text('risk.bounty.desc'),
    'RG-OVERLOAD': catalog.text('risk.overload.desc'),
  };

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xE605030F),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              catalog.text('risk.title'),
              style: TextStyle(
                color: const Color(0xFFFFC24B),
                fontSize: 34 * scale,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
            ),
            SizedBox(height: 6 * scale),
            Text(
              catalog.text('risk.hintWithTimer', <String, Object?>{'seconds': gate.remainingSeconds.toStringAsFixed(1)}),
              style: TextStyle(color: Colors.white54, fontSize: 15 * scale),
            ),
            SizedBox(height: 28 * scale),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var i = 0; i < gate.availableOptionIds.length; i++)
                  ...<Widget>[
                    if (i > 0) SizedBox(width: 20 * scale),
                    _RiskOptionCard(
                      catalog: catalog,
                      optionId: gate.availableOptionIds[i],
                      label: _labels[gate.availableOptionIds[i]] ??
                          gate.availableOptionIds[i],
                      description:
                          _descriptions[gate.availableOptionIds[i]] ?? '',
                      scale: scale,
                      onTap: () =>
                          onSelect(gate.availableOptionIds[i]),
                    ),
                  ],
                for (final locked in gate.lockedOptionIds) ...<Widget>[
                  SizedBox(width: 20 * scale),
                  _RiskOptionCard(
                    catalog: catalog,
                    optionId: locked,
                    label: _labels[locked] ?? locked,
                    description: catalog.text('risk.lockedReason'),
                    scale: scale,
                    locked: true,
                    onTap: null,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskOptionCard extends StatelessWidget {
  const _RiskOptionCard({
    required this.catalog,
    required this.optionId,
    required this.label,
    required this.description,
    required this.scale,
    this.locked = false,
    this.onTap,
  });

  /// F-01：文案只从内容目录按 key 取。
  final ContentCatalog catalog;

  final String optionId;
  final String label;
  final String description;
  final double scale;
  final bool locked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = locked
        ? const Color(0xFF555555)
        : optionId == 'RG-SUPPLY'
        ? const Color(0xFF3FE0FF)
        : optionId == 'RG-BOUNTY'
        ? const Color(0xFFFFC24B)
        : const Color(0xFFFF5C8A);

    return Semantics(
      button: !locked,
      enabled: !locked,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 260 * scale,
          height: 200 * scale,
          padding: EdgeInsets.all(18 * scale),
          decoration: BoxDecoration(
            color: const Color(0xFF120A26),
            borderRadius: BorderRadius.circular(14 * scale),
            border: Border.all(color: color, width: 2 * scale),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 20 * scale,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 10 * scale),
              Expanded(
                child: Text(
                  description,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14 * scale,
                  ),
                ),
              ),
              if (locked)
                Text(
                  catalog.text('risk.locked'),
                  style: TextStyle(
                    color: const Color(0xFF888888),
                    fontSize: 13 * scale,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 升级三选一覆盖层。
///
/// 按产品基线 §4.2 用 1/2/3 或点击选择；战时逻辑已完全冻结。
class _DraftOverlay extends StatelessWidget {
  const _DraftOverlay({
    required this.catalog,
    required this.draft,
    required this.scale,
    required this.onSelect,
  });

  /// F-01：文案只从内容目录按 key 取，不硬编码。
  final ContentCatalog catalog;

  final DraftView draft;
  final double scale;
  final void Function(int index) onSelect;

  static const Map<String, Color> _seriesColors = <String, Color>{
    'pulse': Color(0xFF3FE0FF),
    'missile': Color(0xFFFFC24B),
    'laser': Color(0xFFFF5C8A),
    'drone': Color(0xFF7CF9FF),
    'survival': Color(0xFF7C6BFF),
    'damage': Color(0xFFFF8A3A),
  };

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xE605030F),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              catalog.text('draft.title'),
              style: TextStyle(
                color: const Color(0xFF3FE0FF),
                fontSize: 34 * scale,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
            ),
            SizedBox(height: 6 * scale),
            Text(
              catalog.text('draft.subtitle', <String, Object?>{'index': draft.draftIndex + 1, 'total': 6}),
              style: TextStyle(color: Colors.white54, fontSize: 15 * scale),
            ),
            SizedBox(height: 28 * scale),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var i = 0; i < draft.cards.length; i++) ...<Widget>[
                  if (i > 0) SizedBox(width: 22 * scale),
                  _DraftCard(
                    catalog: catalog,
                    card: draft.cards[i],
                    index: i,
                    color: _seriesColors[draft.cards[i].series] ??
                        const Color(0xFF3FE0FF),
                    scale: scale,
                    onTap: () => onSelect(i),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.catalog,
    required this.card,
    required this.index,
    required this.color,
    required this.scale,
    required this.onTap,
  });

  /// F-01：文案只从内容目录按 key 取。
  final ContentCatalog catalog;

  final DraftCardView card;
  final int index;
  final Color color;
  final double scale;
  final VoidCallback onTap;

  /// 把色弱叠层的 Asset ID 解析为 Flutter 资源路径（F-12）。
  ///
  /// 走 manifest 的 `runtimeFiles`，**不硬编码路径**（协议 §2：
  /// 「资源用 `AssetId` 查表，不允许散落的字符串路径」）。
  String? _rarityPatternPath() => _runtimeFileOf('UI-COLORBLIND-PATTERN-RARITY');

  /// **逐卡**能力图标的运行时文件（F-26-03）。
  ///
  /// 一律经 manifest 的 `runtimeFiles` 解析该卡**自己的**
  /// `iconAssetId` —— 禁止写死文件路径，也禁止用系列通用图标替代。
  String? _iconFile() => _runtimeFileOf(card.iconAssetId);

  /// 稀有度**各档外形**（`UI-RARITY-COMMON/RARE/EPIC`）。
  ///
  /// 裁决：「`UI-RARITY-COMMON/RARE/EPIC` 继续提供**各档不同的外形/边框**，
  /// **不能只靠颜色或文本区分**」——因此这里贴的是各档自己的图形，
  /// 而不是仅靠边框颜色。
  String? _rarityTierPath() {
    final tier = switch (card.rarity) {
      'common' => 'COMMON',
      'rare' => 'RARE',
      'epic' => 'EPIC',
      _ => null,
    };
    if (tier == null) {
      return null;
    }
    return _runtimeFileOf('UI-RARITY-$tier');
  }

  /// 经 manifest 的 `runtimeFiles` 解析资源路径。
  ///
  /// **不硬编码字符串路径**（协议 §2：「资源用 `AssetId` 查表」）。
  String? _runtimeFileOf(String assetId) {
    final record = catalog.manifest.lookup(assetId);
    final files = record?.runtimeFiles;
    return (files == null || files.isEmpty) ? null : files.first;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: catalog.text('draft.cardAria', <String, Object?>{'cardId': card.cardId}),
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 300 * scale,
          height: 380 * scale,
          padding: EdgeInsets.all(20 * scale),
          decoration: BoxDecoration(
            color: const Color(0xFF120A26),
            borderRadius: BorderRadius.circular(16 * scale),
            border: Border.all(
              color: card.isGuaranteed ? const Color(0xFFFFC24B) : color,
              width: (card.isGuaranteed ? 3 : 2) * scale,
            ),
          ),
          // F-12：稀有度的**颜色之外**第二识别维度。
          //
          // 裁决：「**必须实际合成正式 PNG 素材，禁止用 Canvas 或程序化
          // 几何等价替代**」。因此这里贴 `UI-COLORBLIND-PATTERN-RARITY`
          // 本身（同心圆十字），而不是自绘图形或改边框样式。
          // **始终显示，不依赖设置**（没有"色弱开关"这回事）。
          child: _buildCardBody(scale, color),
        ),
      ),
    );
  }

  /// 稀有度标识区（卡片右上角的一小块）。
  ///
  /// ⚠️ **这里必须是小面积徽标，不能铺满整卡。**
  /// 我上一版把 `UI-COLORBLIND-PATTERN-RARITY` 用
  /// `foregroundDecoration` + `BoxFit.fill` 铺满整张卡、又把
  /// `UI-RARITY-*` 用 `Positioned.fill` 盖在上面 —— 结果**卡面内容
  /// 被整层盖住**，玩家"完全看不清素材，也不知道是啥意思"。
  /// 裁决的原话就是「在稀有度**标识区域**合成」，不是铺满卡片。
  Widget _rarityBadge(double scale) {
    final tierPath = _rarityTierPath();
    final patternPath = _rarityPatternPath();
    if (tierPath == null && patternPath == null) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 各档**外形**（形状本身可区分，不只靠颜色）。
        if (tierPath != null)
          SizedBox(
            height: 26 * scale,
            width: 26 * scale,
            child: Image.asset(tierPath, fit: BoxFit.contain),
          ),
        // 颜色之外的**第二识别维度**（同心圆十字）。
        if (patternPath != null) ...<Widget>[
          SizedBox(width: 4 * scale),
          SizedBox(
            height: 22 * scale,
            width: 22 * scale,
            child: Image.asset(patternPath, fit: BoxFit.contain),
          ),
        ],
      ],
    );
  }

  Widget _buildCardBody(double scale, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10 * scale,
                      vertical: 4 * scale,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6 * scale),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: color,
                        fontSize: 18 * scale,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _rarityBadge(scale),
                      SizedBox(width: 8 * scale),
                      Text(
                        'Lv ${card.nextLevel}/${card.maxLevel}',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 14 * scale,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              SizedBox(height: 12 * scale),

              // F-26-03：**逐卡能力图标**。
              //
              // 此前完全没有渲染 `iconAssetId` —— 素材已交付 16 张
              // `UI-UP-*`、配置也已逐卡绑定，但 UI 从不使用它，
              // 玩家只能靠读长描述判断卡牌类型。
              //
              // 固定图标位：位于标题**上方**、独立一行，因此不会被
              // 稀有度叠层、文字或点击层遮挡。
              SizedBox(
                height: 52 * scale,
                child: _iconFile() == null
                    ? const SizedBox.shrink()
                    : Image.asset(_iconFile()!, fit: BoxFit.contain),
              ),
              SizedBox(height: 10 * scale),

              // ⚠️ F-25：这里此前渲染的是 **`card.cardId`**（内部 Key，
              // 例如 `UP-PULSE-RATE`），描述渲染的是 **`card.descKey`** ——
              // 玩家看到的是 key 而不是文案。已改为经 catalog 解析。
              Text(
                catalog.text(card.nameKey),
                style: TextStyle(
                  color: color,
                  fontSize: 16 * scale,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 10 * scale),
              Expanded(
                child: Text(
                  catalog.text(card.descKey),
                  style: TextStyle(color: Colors.white70, fontSize: 14 * scale),
                ),
              ),
              if (card.isGuaranteed)
                Text(
                  catalog.text('draft.guaranteedBadge'),
                  style: TextStyle(
                    color: const Color(0xFFFFC24B),
                    fontSize: 13 * scale,
                    fontWeight: FontWeight.bold,
                  ),
                ),
      ],
    );
  }
}

class _PauseOverlay extends StatelessWidget {
  const _PauseOverlay({
    required this.catalog,
    required this.onResume,
    required this.scale,
    this.onQuitToHome,
  });

  /// F-01：文案只从内容目录按 key 取，不硬编码。
  final ContentCatalog catalog;

  final VoidCallback onResume;
  final double scale;
  final VoidCallback? onQuitToHome;

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
                catalog.text('pause.title'),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 42 * scale,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 24 * scale),
              FilledButton(
                onPressed: onResume,
                child: Text(catalog.text('pause.resume'), style: TextStyle(fontSize: 20 * scale)),
              ),
              if (onQuitToHome != null) ...<Widget>[
                SizedBox(height: 12 * scale),
                OutlinedButton(
                  onPressed: onQuitToHome,
                  child: Text(
                    catalog.text('pause.quit'),
                    style: TextStyle(fontSize: 18 * scale),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

