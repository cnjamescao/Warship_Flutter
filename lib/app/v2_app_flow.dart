// ================================================================
// lib/app/v2_app_flow.dart —— v2.0 相位路由
//
// **架构位置**：App（装配与路由） —— 注入依赖、相位与页面路由；**禁止直接遍历战斗实体**。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：内容校验失败必须拒绝开局（不得默认值兜底）· 本层不得引用 Domain 具体规则类型。
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../game/content/content_catalog.dart';
import '../game/presentation/asset_cache.dart';
import 'baseline_recording.dart';
import '../game/core/domain_event.dart';
import '../game/core/game_phase.dart';
import '../game/core/baseline_recorder.dart';
import '../game/core/game_runtime.dart';
import '../game/domain/result_tier.dart';
import '../game/infrastructure/asset_loader.dart';
import '../game/infrastructure/audio_director.dart';
import '../game/infrastructure/audio_port.dart';
import '../game/infrastructure/haptics_director.dart';
import '../game/infrastructure/haptics_platform.dart';
import '../game/infrastructure/haptics_port.dart';
import '../game/infrastructure/progress_store.dart';
import '../game/infrastructure/shared_preferences_store.dart';
import '../game/presentation/input_gateway.dart';
import 'v2_bootstrap.dart';
import 'v2_run_screen.dart';

/// 简报倒计时秒数（产品基线 §4.2：首次升级不早于 15 秒，
/// 简报只占表现时间，不消耗有效战斗时间）。
const int kBriefingCountdown = 3;

/// **F-25-02 修复**：简报目标里「坚持 N 秒」的权威值。
///
/// 来源：`Spec/01_产品/Warship_v2.0研发交付基线.md` ——
/// 「一局有效战斗时间**上限为 190 秒**，计时从 `Briefing` 结束开始。
///   Boss 在 150 秒出现；180 秒未击败时进入狂暴，但仍允许到 190 秒，
///   190 秒判负。」
///
/// ⚠️ 此前这里错误地传入了 [kBriefingCountdown]（=3，即简报界面的
/// 3→1 展示倒计时），于是玩家看到「**坚持 3 秒**，击败守门者 Aegis」——
/// 把**界面展示倒计时**当成了**游戏目标**（F-25-02 的实测现象）。
/// 两者是完全不同的数值，不可混用。
const int kRunObjectiveSeconds = 190;

/// 应用主流程。
class V2AppFlow extends StatefulWidget {
  const V2AppFlow({
    super.key,
    required this.catalog,
    required this.seed,
    this.audioPort,
    this.store,
    this.preloadAssets = true,
    this.assetCache,
  });

  final ContentCatalog catalog;
  final int seed;

  /// 音频输出端口。
  ///
  /// 可注入是为了**可测试性**：默认的 `FlameAudioPort` 会走
  /// `flame_audio` 的平台通道，在 `flutter_test` 里无法驱动。
  /// 生产代码不传它，行为与之前完全一致。
  final AudioPort? audioPort;

  /// 本地存档。
  ///
  /// 同样可注入：默认走 `SharedPreferencesStore.openOrMemory()`，
  /// 在测试里需要替身。生产代码不传它。
  final KeyValueStore? store;

  /// 是否在进入对局时预载 `firstRun` 资源分组。
  ///
  /// 默认 `true`（生产行为）。测试里置 `false` ——
  /// 预载走 `Flame.images.load` → `rootBundle`，是**真实 I/O**，
  /// 在 `testWidgets` 的假异步区里不会完成。
  /// 关掉后表现层走矢量占位，**规则不受影响**（架构 §7）。
  final bool preloadAssets;

  /// **F-40**：透传给 `V2RunScreen` 的已预填资源缓存（测试用）。
  final VisualAssetCache? assetCache;

  @override
  State<V2AppFlow> createState() => _V2AppFlowState();
}

class _V2AppFlowState extends State<V2AppFlow> {
  GameRuntime? _runtime;
  KeyboardInputGateway? _input;

  /// 音频（跨局复用：设置是全局的，不随重开重建）。
  late final AudioService _audio;
  AudioDirector? _audioDirector;

  /// AC-06 基准录制器（协议 §5.1）。**默认 null —— 不录制**；
  /// 仅当以 `--dart-define=WARSHIP_RECORD_BASELINE=<path>` 构建时创建。
  BaselineRecording? _baselineRecorder;

  /// 触感（F-10）。同样跨局复用。
  ///
  /// 注意：**触感能力由平台决定，与用户开关是两回事** ——
  /// 服务内部做"用户开 且 平台支持"的双重判定，此处只负责传开关。
  late final HapticsService _haptics;
  HapticsDirector? _hapticsDirector;

  /// 本地设置与记录。
  late final ProgressStore _progress;
  GameSettings _settings = const GameSettings();
  GameRecords _records = const GameRecords();
  bool _progressReady = false;

  /// 本局结果（进入 Result 时写入）。
  String _resultOutcome = 'defeat';
  int _resultScore = 0;
  double _resultSeconds = 0;

  /// 本局结算奖牌（`gold` / `silver` / `bronze`）。
  ///
  /// 算法见 `lib/game/domain/result_tier.dart`（含文档冲突的裁决记录）。
  String _resultTier = ResultTier.bronze.id;

  @override
  void initState() {
    super.initState();
    // 音频与存档都在 flow 层建立：它们跨局存活，不随 RunSession 重建。
    _audio = AudioService(port: widget.audioPort ?? FlameAudioPort());

    // F-10：触感端口。支持触感时用平台实现，否则用静默实现 ——
    // 这样上层无需到处判平台，"不支持"只在一处表达。
    final platformHaptics = PlatformHapticsPort();
    _haptics = HapticsService(
      platformHaptics.isSupported
          ? platformHaptics
          : const NoopHapticsPort(),
      enabled: _settings.hapticsEnabled,
    );
    _progress = ProgressStore(store: widget.store ?? InMemoryKeyValueStore());
    _loadProgress();
    // 初始相位是 Home（架构 §3.1）。这里**不**自动开局 ——
    // 由玩家点击「开始战斗」触发 Home → Loading → Briefing。
  }

  @override
  void dispose() {
    _runtime?.dispose();
    _audio.stopAllLoops();
    super.dispose();
  }

  /// 读取本地设置与记录。
  ///
  /// 任何失败都退化为默认值，**绝不阻断开局**（架构 §7）。
  Future<void> _loadProgress() async {
    // 注入了替身就直接用，不走平台通道（测试路径）。
    final store = widget.store ?? await SharedPreferencesStore.openOrMemory();
    final result = await ProgressStore(store: store).load();
    if (!mounted) {
      return;
    }
    setState(() {
      _settings = result.settings;
      _records = result.records;
      _progressReady = true;
    });
    _applySettings();
  }

  /// 把设置作用到音频。
  ///
  /// 产品设计 §8 要求「音效/音乐**独立**音量」。此前这里写的是
  /// `setMuted(!sfxEnabled && !musicEnabled)` —— 只有两个开关**都**关
  /// 才会静音，于是"关音乐留音效"时两者都还在响，等于只有一个开关生效。
  /// 现改为按总线分别判定：音乐总线看 `musicEnabled`，
  /// 音效/UI/预警三条总线看 `sfxEnabled`。
  void _applySettings() {
    _audio.setBusEnabled(AudioBus.music, _settings.musicEnabled);
    for (final bus in <AudioBus>[
      AudioBus.sfx,
      AudioBus.ui,
      AudioBus.warning,
    ]) {
      _audio.setBusEnabled(bus, _settings.sfxEnabled);
    }
    // F-10：触感只有一个开关，直接作用到服务。
    _haptics.enabled = _settings.hapticsEnabled;

    // 全局静音保持关闭：真正的开关交给上面的总线判定。
    _audio.setMuted(false);
  }

  Future<void> _updateSettings(GameSettings next) async {
    setState(() => _settings = next);
    _applySettings();
    await _progress.saveSettings(next);
  }

  /// 开始新一局：先释放上一局，再创建。
  ///
  /// 技术架构 §3.2：「重新开始先 dispose RunSession，再创建下一局；
  /// 旧对象不得再向 HUD、音频或 Flame World 发事件。」
  void _startNewRun() {
    _runtime?.dispose();
    _audioDirector = AudioDirector(
      table: const AssetLoader().build(widget.catalog.manifest),
      service: _audio,
    );
    _hapticsDirector = HapticsDirector(service: _haptics);

    // AC-06 基准录制：**默认关闭**。
    //
    // ⚠️ 指纹必须在开启时**才算** —— 首版我把它当实参无条件求值，
    // 结果日常构建每次开局都会执行这段（并因类型问题崩掉）。
    // 关闭状态下应当是彻底的 no-op。
    if (isBaselineRecordingEnabled) {
      // 运行时只能得到"构建复制品"的指纹（应用里没有 素材/ 原文件）。
      // 提交前由 `dart run tool/finalize_baseline.dart` 盖上
      // 正式 `素材/manifest.json` 的真实 SHA-256（§5.1 要求）。
      _baselineRecorder = createBaselineRecorder(
        seed: widget.seed,
        contentVersion: widget.catalog.contentVersion,
        manifestSha256: manifestFingerprint(
          recordCount: widget.catalog.manifest.records.length,
          contentVersion: widget.catalog.contentVersion,
        ),
      );
    }
    // 每局的音频限频窗口从头开始，避免上一局的节奏影响本局。
    _audio.reset();

    final runtime = V2Bootstrap().buildRuntime(
      catalog: widget.catalog,
      seed: widget.seed,
      audioDirector: _audioDirector,
      hapticsDirector: _hapticsDirector,
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

    // AC-06 基准：**只有满足 §5.1 成功条件才写出**（在下面判定完
    // outcome 之后调用；不合格的局什么都不写）。
    final outcome = runtime.player.health.isDead ? 'defeat' : 'victory';
    // 奖牌在这里算：bossHpRatio 取**该局结束时的真实值**。
    // 胜利时 Boss 已被击毁，`boss` 可能为 null —— 但 victory=true
    // 会直接返回 gold，不依赖该值。
    final tier = resultTierFor(
      victory: outcome == 'victory',
      bossHpRatio: runtime.boss?.hpRatio,
    );
    setState(() {
      _resultOutcome = outcome;
      _resultScore = runtime.score;
      _resultSeconds = runtime.combatSeconds;
      _resultTier = tier.id;
    });

    // AC-06 基准写出（未开启时是 no-op；不合格时不写）。
    writeBaselineIfEligible(_baselineRecorder);

    // 记录只增不减；存档失败不阻断结算界面。
    var updated = _records.withScore(runtime.score);
    if (outcome == 'victory') {
      updated = updated.withClearTime(runtime.combatSeconds);
    }
    if (updated.highScore != _records.highScore ||
        updated.bestClearSeconds != _records.bestClearSeconds) {
      setState(() => _records = updated);
      _progress.saveRecords(updated);
    }
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
      return _HomeScreen(
        catalog: widget.catalog,
        onStart: _startNewRun,
        highScore: _records.highScore,
        bestClearSeconds: _records.bestClearSeconds,
        settings: _settings,
        onSettingsChanged: _updateSettings,
        progressReady: _progressReady,
      );
    }

    switch (runtime.phases.phase) {
      case GamePhase.home:
        return _HomeScreen(
          catalog: widget.catalog,
          onStart: _startNewRun,
          highScore: _records.highScore,
          bestClearSeconds: _records.bestClearSeconds,
          settings: _settings,
          onSettingsChanged: _updateSettings,
          progressReady: _progressReady,
        );

      case GamePhase.loading:
        return const _LoadingSurface();

      case GamePhase.briefing:
        return _BriefingScreen(
          catalog: widget.catalog,
          countdown: kBriefingCountdown,
          onFinished: _onBriefingFinished,
        );

      case GamePhase.playing:
      case GamePhase.paused:
      case GamePhase.upgradeDraft:
      case GamePhase.riskGate:
        return V2RunScreen(
          catalog: widget.catalog,
          baselineRecorder: _baselineRecorder,
          runtime: runtime,
          input: input,
          manifest: widget.catalog.manifest,
          preloadAssets: widget.preloadAssets,
          assetCache: widget.assetCache,
          reduceMotion: _settings.reduceMotion,
          onFrame: () => _checkRunOver(runtime),
          onQuitToHome: _backToHome,
        );

      case GamePhase.result:
        return _ResultScreen(
          catalog: widget.catalog,
          outcome: _resultOutcome,
          tier: _resultTier,
          score: _resultScore,
          seconds: _resultSeconds,
          bestScore: _records.highScore,
          bestClearSeconds: _records.bestClearSeconds,
          onRestart: _startNewRun,
          onHome: _backToHome,
        );
    }
  }

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
class _HomeScreen extends StatefulWidget {
  const _HomeScreen({
    required this.catalog,
    required this.onStart,
    required this.highScore,
    required this.settings,
    required this.onSettingsChanged,
    required this.progressReady,
    this.bestClearSeconds,
  });

  final ContentCatalog catalog;
  final VoidCallback onStart;
  final int highScore;
  final double? bestClearSeconds;
  final GameSettings settings;
  final ValueChanged<GameSettings> onSettingsChanged;
  final bool progressReady;

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

/// 把本地化标题拆成「主标题 / 副标题」。
///
/// 约定：标题里的全角或半角冒号是主副标题的分隔符。
/// 没有冒号时整串作为主标题。这样版式不依赖硬编码文案。
(String, String) _titleParts(String title) {
  for (final sep in <String>['：', ':']) {
    final index = title.indexOf(sep);
    if (index > 0) {
      return (
        title.substring(0, index).trim().toUpperCase(),
        title.substring(index + sep.length).trim(),
      );
    }
  }
  return (title.toUpperCase(), '');
}

class _HomeScreenState extends State<_HomeScreen> {
  bool _showSettings = false;

  @override
  Widget build(BuildContext context) {
    if (_showSettings) {
      return _SettingsScreen(
                catalog: widget.catalog,
        settings: widget.settings,
        onChanged: widget.onSettingsChanged,
        onBack: () => setState(() => _showSettings = false),
      );
    }
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 标题来自 `app.title`（产品设计 §8 要求所有展示文本走
            // 本地化 key，不硬编码）。该键形如「Warship：霓虹最后防线」，
            // 这里按全角冒号拆成「主标题 + 副标题」两行以保持原有版式；
            // 若无冒号则整串作为主标题，副标题留空（对其他语言安全）。
            Text(
              _titleParts(widget.catalog.text('app.title')).$1,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF3FE0FF),
                fontSize: 64,
                fontWeight: FontWeight.bold,
                letterSpacing: 12,
              ),
            ),
            const SizedBox(height: 8),
            if (_titleParts(widget.catalog.text('app.title')).$2.isNotEmpty)
              Text(
              _titleParts(widget.catalog.text('app.title')).$2,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 20,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 48),
            FilledButton(
              onPressed: widget.onStart,
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
              child: Text(widget.catalog.text('home.start')),
            ),
            const SizedBox(height: 28),
            // 最高分只在读取完成后显示，避免闪一下 0。
            if (widget.progressReady) ...<Widget>[
              Text(
                widget.catalog.text('home.highScore', <String, Object?>{'score': widget.highScore}),
                style: const TextStyle(
                  color: Color(0xFFFFC24B),
                  fontSize: 18,
                  letterSpacing: 2,
                ),
              ),
              if (widget.bestClearSeconds != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    widget.catalog.text('home.bestClear', <String, Object?>{'seconds': widget.bestClearSeconds!.toStringAsFixed(1)}),
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 14,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 28),
            TextButton(
              onPressed: () => setState(() => _showSettings = true),
              child: Text(widget.catalog.text('home.settings')),
            ),
            const SizedBox(height: 12),
            Text(
              widget.catalog.text('home.controls'),
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置页。
///
/// 四个开关对应产品基线 §8 的固定键；**减少动效**是无障碍项，
/// 只降低非关键动效，不削弱预警与状态可读性。
class _SettingsScreen extends StatelessWidget {
  const _SettingsScreen({
    required this.catalog,
    required this.settings,
    required this.onChanged,
    required this.onBack,
  });

  /// F-01：文案只从内容目录按 key 取。
  final ContentCatalog catalog;

  final GameSettings settings;
  final ValueChanged<GameSettings> onChanged;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                catalog.text('settings.title'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF3FE0FF),
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 8,
                ),
              ),
              const SizedBox(height: 24),
              SwitchListTile(
                title: Text(catalog.text('settings.music')),
                value: settings.musicEnabled,
                onChanged: (v) =>
                    onChanged(settings.copyWith(musicEnabled: v)),
              ),
              SwitchListTile(
                title: Text(catalog.text('settings.sfx')),
                value: settings.sfxEnabled,
                onChanged: (v) => onChanged(settings.copyWith(sfxEnabled: v)),
              ),
              SwitchListTile(
                title: Text(catalog.text('settings.reduceMotion')),
                subtitle: Text(catalog.text('settings.reduceMotionHint')),
                value: settings.reduceMotion,
                onChanged: (v) =>
                    onChanged(settings.copyWith(reduceMotion: v)),
              ),
              SwitchListTile(
                title: Text(catalog.text('settings.haptics')),
                value: settings.hapticsEnabled,
                onChanged: (v) =>
                    onChanged(settings.copyWith(hapticsEnabled: v)),
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: onBack, child: Text(catalog.text('settings.back'))),
            ],
          ),
        ),
      ),
    );
  }
}

/// 开局简报：只有表现时钟，战斗逻辑完全冻结。
class _BriefingScreen extends StatefulWidget {
  const _BriefingScreen({
    required this.catalog,
    required this.countdown,
    required this.onFinished,
  });

  final ContentCatalog catalog;
  final int countdown;
  final VoidCallback onFinished;

  @override
  State<_BriefingScreen> createState() => _BriefingScreenState();
}

class _BriefingScreenState extends State<_BriefingScreen> {
  int _remaining = 0;
  bool _done = false;

  /// 倒计时定时器。
  ///
  /// 原先用 `Future.delayed` —— 它**无法取消**：dispose 之后 `mounted`
  /// 会让回调空转，但**定时器本身仍然挂在那里**。这既是真实的资源泄漏，
  /// 也让 widget 测试在结束时报 "Pending timers"。
  /// 改用可取消的 `Timer` 并在 `dispose` 里取消。
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remaining = widget.countdown;
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () {
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
            Text(
              widget.catalog.text('briefing.title'),
              style: TextStyle(
                color: Color(0xFF3FE0FF),
                fontSize: 32,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              // F-25-02：目标是**战斗时长上限**，不是简报的 3 秒展示倒计时。
              widget.catalog.text('briefing.objective', <String, Object?>{
                'seconds': kRunObjectiveSeconds,
              }),
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 28),
            // 三条操作提示。产品设计 §8 要求展示文本走本地化 key，
            // 且这三个键在 strings_zh_CN.json 中**早已提供** ——
            // 此前界面没有渲染它们，属于内容缺失，这里补上。
            for (final key in <String>[
              'briefing.tip.move',
              'briefing.tip.dash',
              'briefing.tip.autofire',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  widget.catalog.text(key),
                  style: const TextStyle(color: Colors.white60, fontSize: 15),
                ),
              ),
            const SizedBox(height: 28),
            Text(
              '$_remaining',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 96,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.catalog.text('briefing.skipHint'),
              style: const TextStyle(color: Colors.white38, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// 结算界面。
/// 结算奖牌：图形（`UI-RESULT-MEDAL` 的对应状态）+ 本地化档位名。
///
/// 资源路径从 manifest 取，**不硬编码文件名**（素材规范 §1.1）。
/// 该档位没有图形时只显示文字，不影响结算可用性。
class _ResultMedal extends StatelessWidget {
  const _ResultMedal({required this.catalog, required this.tier});

  final ContentCatalog catalog;
  final String tier;

  @override
  Widget build(BuildContext context) {
    final record = catalog.manifest.lookup('UI-RESULT-MEDAL');
    final spec = record?.renderStates[tier];
    final files = spec != null && spec.runtimeFiles.isNotEmpty
        ? spec.runtimeFiles
        : (record?.runtimeFiles ?? const <String>[]);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (files.isNotEmpty)
          Image.asset(
            files.first,
            width: 96,
            height: 96,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => const SizedBox(width: 96, height: 96),
          ),
        const SizedBox(height: 6),
        Text(
          catalog.text('result.tier.$tier'),
          style: const TextStyle(color: Color(0xFFFFC24B), fontSize: 20),
        ),
      ],
    );
  }
}

class _ResultScreen extends StatelessWidget {
  const _ResultScreen({
    required this.catalog,
    required this.outcome,
    required this.tier,
    required this.score,
    required this.seconds,
    required this.bestScore,
    required this.onRestart,
    required this.onHome,
    this.bestClearSeconds,
  });

  final ContentCatalog catalog;
  final String outcome;

  /// 结算奖牌档位 id（`gold` / `silver` / `bronze`）。
  final String tier;

  final int score;
  final double seconds;
  final int bestScore;
  final double? bestClearSeconds;
  final VoidCallback onRestart;
  final VoidCallback onHome;

  /// F-01：文案只从内容目录按 key 取。
  


  @override
  Widget build(BuildContext context) {
    final victory = outcome == 'victory';
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              catalog.text(victory ? 'result.victory' : 'result.defeat'),
              style: TextStyle(
                color: victory
                    ? const Color(0xFFFFC24B)
                    : const Color(0xFFFF5C8A),
                fontSize: 44,
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 20),
            _ResultMedal(catalog: catalog, tier: tier),
            const SizedBox(height: 20),
            Text(
              catalog.text('result.score', <String, Object?>{'score': score}),
              style: const TextStyle(color: Colors.white, fontSize: 26),
            ),
            const SizedBox(height: 8),
            Text(
              catalog.text('result.time', <String, Object?>{
                'seconds': seconds.toStringAsFixed(1),
              }),
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              catalog.text('result.best', <String, Object?>{
                'score': bestScore,
              }),
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
                  child: Text(catalog.text('result.restart')),
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
                  child: Text(catalog.text('result.home')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
