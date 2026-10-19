// ================================================================
// lib/game/infrastructure/audio_port.dart —— 音频端口与限频调度
//
// **架构位置**：Infrastructure（平台与 IO 适配） —— 把平台能力（音频/触觉/存档/性能）包成**可替换的端口**，便于测试注入替身。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：在假异步测试环境中须可注入替身 · 失败不得影响规则 · 平台不支持时静默 no-op。
//
// **本文件是"音频能力"的端口** —— 把平台音频包成可替换接口。
//
// **要点与易错点**：
//   * **平台不支持时必须静默 no-op，不得抛错**：
//     音频只是表现，**任何音频问题都不允许影响规则或让游戏崩溃**。
//     捕获异常并继续是**正确行为**，不是偷懒。
//   * **Web 有"音频手势解锁"要求**：浏览器在用户首次交互前不允许播放 ——
//     因此"没声音"在 Web 上可能是**预期**而非缺陷，验收时要按
//     AC-08 的清单在真实浏览器确认。
//   * **预加载失败要记录但不阻断**：素材缺失应表现为缺少该音效，
//     而不是卡住加载流程。
//   * **音量三路独立**（音乐/音效/总），且**设置需持久化**；
//     不要把音量混成一路。
//   * **音频不能反向改变 Domain**（架构 §7）：它只消费事件。
//   * 测试注入静音替身（`SilentAudioPort`），**不要**在测试里走真实通道。
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §7
//   「音频采用 Music/SFX/UI/Warning 四总线，**Warning 优先**；
//     高频 `WeaponFired`、`WeaponHit` 按 **80 ms** 合并；
//     同 cue 最大并发由素材元数据指定。
//     暂停停止或挂起持续音，恢复不得重复叠层。」
//
// 架构 §2.1 的 `AudioPort` 契约：「合并、限频、静音、暂停/恢复正确」，
// 且音频失败必须静默继续、不抛到战斗循环（架构 §7）。
//
// 本文件是**纯 Dart**：真正的播放由实现类完成，调度规则在这里，
// 因此可以被完整单测覆盖。
// ================================================================

/// 音频总线。Warning 的优先级最高。
enum AudioBus {
  music,
  sfx,
  ui,
  warning;

  /// 总线优先级：数值越大越不容易被抢占。
  int get priority => switch (this) {
    AudioBus.warning => 3,
    AudioBus.ui => 2,
    AudioBus.sfx => 1,
    AudioBus.music => 0,
  };
}

/// 一条可播放的 cue（由 manifest 的音频记录映射而来）。
class AudioCue {
  const AudioCue({
    required this.cueId,
    required this.assetId,
    required this.bus,
    this.priority = 0,
    this.maxVoices = 1,
    this.minRetriggerMs = 0,
    this.loop = false,
  });

  final String cueId;
  final String assetId;
  final AudioBus bus;

  /// 总线内优先级（manifest 的 `priority`）。
  final int priority;

  /// 同 cue 最大并发。
  final int maxVoices;

  /// 同一 cue 的最小重触发间隔（毫秒）。
  final int minRetriggerMs;

  /// 是否为持续音（BGM、激光循环等）。
  final bool loop;

  /// 高频 cue 的合并窗口。仅 `WeaponFired` / `WeaponHit` 使用 80 ms。
  static const int mergeWindowMs = 80;
}

/// 音频端口。
abstract interface class AudioPort {
  /// 播放一条 cue。实现必须吞掉一切异常（架构 §7：音频失败静默继续）。
  void play(AudioCue cue);

  /// 停止某个 cue 的全部发声。
  void stop(String cueId);

  /// 停止整条总线。
  void stopBus(AudioBus bus);

  /// 暂停：挂起持续音，不销毁句柄。
  void pauseAll();

  /// 恢复：**不得重复叠层** —— 已在播的持续音不再重新起播。
  void resumeAll();

  void setMuted(bool muted);

  bool get isMuted;
}

/// 记录调用的假实现，供测试与无音频环境使用。
class RecordingAudioPort implements AudioPort {
  final List<String> playedCueIds = <String>[];

  /// **完整的 cue 对象**（含 `assetId`）。
  ///
  /// 只记 `cueId` 不够 —— F-44 的缺陷正是"`assetId` 传错"，
  /// 而只记 id 的假实现**根本发现不了** ✗。
  final List<AudioCue> playedCues = <AudioCue>[];
  final List<String> stoppedCueIds = <String>[];
  final List<AudioBus> stoppedBuses = <AudioBus>[];

  int pauseCount = 0;
  int resumeCount = 0;
  bool _muted = false;

  /// 当前正在发声的 cue（用于验证"恢复不叠层"）。
  final Set<String> activeLoops = <String>{};

  @override
  void play(AudioCue cue) {
    if (_muted) {
      return;
    }
    playedCues.add(cue);
    playedCueIds.add(cue.cueId);
    if (cue.loop) {
      activeLoops.add(cue.cueId);
    }
  }

  @override
  void stop(String cueId) {
    stoppedCueIds.add(cueId);
    activeLoops.remove(cueId);
  }

  @override
  void stopBus(AudioBus bus) {
    stoppedBuses.add(bus);
  }

  @override
  void pauseAll() => pauseCount++;

  @override
  void resumeAll() => resumeCount++;

  @override
  void setMuted(bool muted) => _muted = muted;

  @override
  bool get isMuted => _muted;

  void clear() {
    playedCueIds.clear();
    stoppedCueIds.clear();
    stoppedBuses.clear();
    activeLoops.clear();
    pauseCount = 0;
    resumeCount = 0;
  }
}

/// 永远不发声的端口（无声模式、测试默认）。
class SilentAudioPort implements AudioPort {
  const SilentAudioPort();

  @override
  void play(AudioCue cue) {}
  @override
  void stop(String cueId) {}
  @override
  void stopBus(AudioBus bus) {}
  @override
  void pauseAll() {}
  @override
  void resumeAll() {}
  @override
  void setMuted(bool muted) {}
  @override
  bool get isMuted => true;
}

/// 一次播放决策。
enum AudioDecision {
  /// 允许播放。
  play,

  /// 被同 cue 的合并窗口吸收（高频 cue 限频）。
  mergedIntoPrevious,

  /// 被 `minRetriggerMs` 挡住。
  throttled,

  /// 该 cue 所属总线被设置关闭（音效 / 音乐独立开关）。
  busDisabled,

  /// 已达同 cue 最大并发。
  voiceLimitReached,

  /// 被总线上限或其他 cue 抢占。
  preempted,
}

/// 限频与并发调度器。
///
/// 它只回答"这次请求该不该真的发声"，不关心底层播放器。
class AudioScheduler {
  AudioScheduler({this.mergeWindowMs = AudioCue.mergeWindowMs});

  /// 高频 cue 的合并窗口（产品基线：80 ms）。
  final int mergeWindowMs;

  final Map<String, double> _lastPlayedAtMs = <String, double>{};
  final Map<String, int> _activeVoices = <String, int>{};

  /// 被合并掉的请求数（诊断用）。
  int mergedCount = 0;

  /// 被限频挡掉的请求数。
  int throttledCount = 0;

  /// 决策：是否播放 [cue]，以及原因。
  AudioDecision decide(AudioCue cue, {required double nowMs}) {
    final last = _lastPlayedAtMs[cue.cueId];

    // 1. 高频 cue 合并：同 cue 在窗口内只播一次。
    if (last != null && nowMs - last < mergeWindowMs) {
      mergedCount++;
      return AudioDecision.mergedIntoPrevious;
    }

    // 2. 最小重触发间隔（持续音如激光循环不受此限）。
    if (!cue.loop &&
        cue.minRetriggerMs > 0 &&
        last != null &&
        nowMs - last < cue.minRetriggerMs) {
      throttledCount++;
      return AudioDecision.throttled;
    }

    // 3. 同 cue 最大并发。Warning 总线永远不被并发上限挡掉 ——
    //    它是玩家必须听到的安全信息。
    final voices = _activeVoices[cue.cueId] ?? 0;
    if (voices >= cue.maxVoices && cue.bus != AudioBus.warning) {
      return AudioDecision.voiceLimitReached;
    }

    return AudioDecision.play;
  }

  /// 记录一次实际播放。
  void recordPlayed(AudioCue cue, {required double nowMs}) {
    _lastPlayedAtMs[cue.cueId] = nowMs;
    _activeVoices[cue.cueId] = (_activeVoices[cue.cueId] ?? 0) + 1;
  }

  /// 记录一次结束（非持续音播完后调用）。
  void recordFinished(String cueId) {
    final voices = _activeVoices[cueId];
    if (voices == null) {
      return;
    }
    if (voices <= 1) {
      _activeVoices.remove(cueId);
    } else {
      _activeVoices[cueId] = voices - 1;
    }
  }

  int activeVoicesOf(String cueId) => _activeVoices[cueId] ?? 0;

  /// 暂停/重开时清空并发计数，但**保留**限频时间戳，
  /// 避免恢复瞬间爆发一串积压的音效。
  void resetVoices() => _activeVoices.clear();

  void reset() {
    _lastPlayedAtMs.clear();
    _activeVoices.clear();
    mergedCount = 0;
    throttledCount = 0;
  }
}

/// 把调度器与端口组合起来的音频服务。
///
/// 战斗代码只依赖它；它保证任何底层异常都不会冒泡到逻辑循环。
class AudioService {
  AudioService({required this.port, AudioScheduler? scheduler})
    : scheduler = scheduler ?? AudioScheduler();

  final AudioPort port;
  final AudioScheduler scheduler;

  /// 逻辑时间（毫秒）。由 Runtime 每步推进，**不使用墙上时钟** ——
  /// 否则暂停与回放都会让限频行为不可复现。
  double _nowMs = 0;

  bool _paused = false;

  /// 当前正在循环的 cue（用于暂停/恢复与"不叠层"）。
  final Set<String> _runningLoops = <String>{};

  /// 各总线是否启用。
  ///
  /// 产品设计 §8 第 280 行要求「音效/音乐**独立**音量」——
  /// 此前只有一个合并的 `setMuted(!sfx && !music)`：
  /// 关掉音乐但留着音效时，因为 `!sfx && !music` 为 false，
  /// **两者都会出声**，两个开关等于只有一个在起作用。
  /// 现在按总线分别判定。
  final Map<AudioBus, bool> _busEnabled = <AudioBus, bool>{};

  /// 设置某条总线是否启用。
  void setBusEnabled(AudioBus bus, bool enabled) {
    _busEnabled[bus] = enabled;
    if (!enabled) {
      // 关闭总线时立刻停掉它正在循环的声音，否则会一直响。
      port.stopBus(bus);
      _runningLoops.removeWhere((cueId) => _cueBus[cueId] == bus);
    }
  }

  bool isBusEnabled(AudioBus bus) => _busEnabled[bus] ?? true;

  /// cueId → 所属总线（用于关闭总线时清理循环音）。
  final Map<String, AudioBus> _cueBus = <String, AudioBus>{};

  double get nowMs => _nowMs;
  bool get isPaused => _paused;
  Set<String> get runningLoops => Set<String>.unmodifiable(_runningLoops);

  void advance(double dtSeconds) {
    _nowMs += dtSeconds * 1000;
  }

  /// 请求播放。返回实际做出的决策。
  AudioDecision request(AudioCue cue) {
    _cueBus[cue.cueId] = cue.bus;
    if (!isBusEnabled(cue.bus)) {
      // 总线被设置关闭：循环音必须停掉，瞬时音直接丢弃。
      if (_runningLoops.remove(cue.cueId)) {
        port.stop(cue.cueId);
      }
      return AudioDecision.busDisabled;
    }
    if (_paused && !cue.loop) {
      return AudioDecision.throttled; // 暂停期间不产生新的瞬时音
    }
    final decision = scheduler.decide(cue, nowMs: _nowMs);
    if (decision != AudioDecision.play) {
      return decision;
    }
    try {
      port.play(cue);
    } catch (_) {
      // 架构 §7：音频失败静默继续，绝不抛到战斗循环。
      return AudioDecision.throttled;
    }
    scheduler.recordPlayed(cue, nowMs: _nowMs);
    if (cue.loop) {
      _runningLoops.add(cue.cueId);
    }
    return AudioDecision.play;
  }

  /// 持续音结束（发射/结束成对事件里的"结束"）。
  void endLoop(String cueId) {
    if (!_runningLoops.remove(cueId)) {
      return;
    }
    try {
      port.stop(cueId);
    } catch (_) {
      // 静默
    }
    scheduler.recordFinished(cueId);
  }

  /// 暂停：挂起持续音。
  void pause() {
    if (_paused) {
      return;
    }
    _paused = true;
    port.pauseAll();
  }

  /// 恢复：**已经在播的持续音不重新起播**，避免叠层。
  void resume() {
    if (!_paused) {
      return;
    }
    _paused = false;
    port.resumeAll();
  }

  /// 一局结束/重开：停止所有循环音并清空并发。
  void stopAllLoops() {
    for (final cueId in _runningLoops.toList()) {
      try {
        port.stop(cueId);
      } catch (_) {
        // 静默
      }
    }
    _runningLoops.clear();
    scheduler.resetVoices();
  }

  void setMuted(bool muted) => port.setMuted(muted);

  bool get isMuted => port.isMuted;

  void reset() {
    _nowMs = 0;
    _paused = false;
    _runningLoops.clear();
    scheduler.reset();
  }
}
