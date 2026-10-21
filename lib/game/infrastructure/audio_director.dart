// ================================================================
// lib/game/infrastructure/audio_director.dart —— 事件 → 音频 cue 路由
//
// **架构位置**：Infrastructure（平台与 IO 适配） —— 把平台能力（音频/触觉/存档/性能）包成**可替换的端口**，便于测试注入替身。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：在假异步测试环境中须可注入替身 · 失败不得影响规则 · 平台不支持时静默 no-op。
// 本文件把事件转成音频调用：
//   * 限频与并发上限在此统一管理（maxVoices、最短重触发间隔）—— 如低血/低护盾提示最短间隔 8 秒（§7.5）
//   * 音频只消费事件，不得反向改变 Domain；失败必须静默降级
//   * 限频窗口用逻辑时间推进（不用墙钟），否则回放不可复现
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §7
//   「AssetLoader 必须…只按 `event + when` 条件匹配」；
//   03_素材 §1.1
//   「音频记录已补齐 Cue、事件、通用回退、内存估算及并发/循环参数」。
//
// 因此这里**不硬编码任何 cue ID**：把 DomainEvent 转成条件参数，
// 交给 [AssetBindingTable] 解析，再交给 [AudioService] 做限频与并发控制。
// 换素材只需改 manifest，不动代码。
// ================================================================

import 'package:flame_audio/flame_audio.dart';

import '../core/domain_event.dart';
import '../core/event_bus.dart';
import '../core/game_phase.dart';
import '../content/asset_manifest.dart';
import 'asset_loader.dart';
import 'audio_port.dart';

/// 把事件负载转成 `when` 条件参数。
///
/// 键名必须与 manifest 的 `when` 条件键**完全一致**
/// （`enemyId` / `attackId` / `weaponId` / `command` / `result` /
/// `optionId` / `direction` / `isElite` / `critical` / `hpRatio` …）。
Map<String, Object?> audioParamsOf(DomainEvent event) =>
    conditionalParamsOf(event);

/// Domain 事件 → `when` 条件参数的**规范名称**。
///
/// 视觉与音频共用同一套条件键空间（manifest 的图形与音频记录都写
/// `eventBindings` + `when`），因此这里只有一份实现。
/// `audioParamsOf` 保留为历史名称的转发。
Map<String, Object?> conditionalParamsOf(DomainEvent event) {
  switch (event) {
    case EnemySpawned(:final enemyId, :final isElite):
      return <String, Object?>{'enemyId': enemyId, 'isElite': isElite};
    case EnemyDestroyed(:final enemyId, :final isElite):
      return <String, Object?>{'enemyId': enemyId, 'isElite': isElite};
    case EnemyDamaged(:final enemyId, :final hpRatio):
      return <String, Object?>{'enemyId': enemyId, 'hpRatio': hpRatio};
    case EnemyBreached(:final enemyId, :final isElite):
      return <String, Object?>{'enemyId': enemyId, 'isElite': isElite};
    case EnemyAttackTelegraphed(:final enemyId, :final attackId):
      return <String, Object?>{'enemyId': enemyId, 'attackId': attackId};
    case EnemyAttackFired(:final enemyId, :final attackId):
      return <String, Object?>{'enemyId': enemyId, 'attackId': attackId};
    case PlayerDamaged(:final shieldDamage, :final hpDamage, :final direction):
      return <String, Object?>{
        'shieldDamage': shieldDamage,
        'hpDamage': hpDamage,
        'direction': direction,
        // **v2.1**：稳定枚举，区分这一击打在护盾还是 HP。
        //
        // 蓝图 §2.2 明文：「manifest 只允许**等值** when 条件，因此
        // `conditionalParamsOf` **必须输出稳定枚举** damageLayer=shield 或 hp，
        // **不得隐式扩展 schema 做数值表达式比较**。」
        // 判定：本击产生了护盾伤害即记为 shield，否则 hp。
        'damageLayer': shieldDamage > 0 ? 'shield' : 'hp',
      };
    case PlayerVitalStateChanged(:final hpRatio, :final shieldRatio):
      return <String, Object?>{
        'hpRatio': hpRatio,
        'shieldRatio': shieldRatio,
        // **v2.1**：低血 / 濒危的稳定枚举（B3 的动效路由用）。
        // 阈值取产品基线：>30% normal / (10%,30%] low / ≤10% critical。
        'hpVisualState': hpRatio <= 0.10
            ? 'critical'
            : (hpRatio <= 0.30 ? 'low' : 'normal'),
      };
    case WeaponFired(:final weaponId, :final weaponStyleId):
      return <String, Object?>{
        'weaponId': _audioWeaponId(weaponId),
        // **v2.1**：五种主弹道的稳定 style ID（null 表示旧主炮/副武器，
        // 此时不参与任何 weaponStyleId 路由 —— 符合"旧主炮传 null"）。
        'weaponStyleId': ?weaponStyleId,
      };
    case WeaponHit(
        :final weaponId,
        :final critical,
        :final weaponStyleId,
        :final targetIsBoss,
      ):
      return <String, Object?>{
        'weaponId': _audioWeaponId(weaponId),
        'critical': critical,
        // **v2.1**：Boss 命中音按此**精确**路由（不推断）。
        'targetIsBoss': targetIsBoss,
        // **v2.1**：命中资源按 style 精确路由（五形态各自一张命中图 + cue）。
        // 旧主炮/副武器为 null ⇒ 不参与 weaponStyleId 路由。
        'weaponStyleId': ?weaponStyleId,
      };
    case BossPhaseChanged(:final phase):
      return <String, Object?>{'phase': phase};
    case BossAttackTelegraphed(:final attackId):
      return <String, Object?>{'attackId': attackId};
    case BossAttackFired(:final attackId):
      return <String, Object?>{'attackId': attackId};
    case BossAttackEnded(:final attackId):
      return <String, Object?>{'attackId': attackId};
    case BossCriticalReached(:final hpRatio):
      return <String, Object?>{'hpRatio': hpRatio};
    case RiskGateOpened(:final gateId):
      return <String, Object?>{'gateId': gateId};
    case RiskSelected(:final optionId):
      return <String, Object?>{'optionId': optionId};
    case UpgradeSelected(:final cardId):
      return <String, Object?>{'cardId': cardId};
    case RunEnded(:final result):
      return <String, Object?>{'result': result};
    default:
      return const <String, Object?>{};
  }
}

/// 把 Domain 的武器 ID 映射成 manifest 条件里的 `weaponId`。
///
/// Domain 用 `WPN-PULSE`（来自 `weapons.json` 的主键），
/// 而素材 manifest 的音频条件写的是**系列短名** `pulse`。
/// 两者语义相同但字面不同 —— 这个映射属于适配层的职责，
/// 不能在 Domain 里改（那会让配置主键与代码耦合到素材命名）。
String _audioWeaponId(String domainWeaponId) {
  final stripped = domainWeaponId.startsWith('WPN-')
      ? domainWeaponId.substring(4)
      : domainWeaponId;
  return stripped.toLowerCase();
}

/// 事件 → 音频。
class AudioDirector {
  AudioDirector({required this.table, required this.service});

  // ------------------------------------------------------------
  // Boss 命中 duck（技术协议：impact 子总线 -6dB / 110ms，BGM 不受影响）
  // ------------------------------------------------------------
  //
  // 现有 `AudioBus` 只有 music/sfx/ui/warning，**没有 impact 子总线** ✗，
  // 无法逐总线调音量。因此这里用**等效意图**实现：
  // Boss 命中音触发后 **110ms 内抑制五形态命中音**，
  // 目的（协议原话）是「确保独立反馈不被五种主弹道命中音掩盖」——
  // 抑制比 -6dB 更强，同样达到该目的，且 BGM **完全不受影响** ✓。
  //
  // **已知差异（如实标注）**：这是"抑制"而不是"降 6dB"；
  // 若日后 `AudioPort` 支持子总线增益，应替换为真正的 duck。
  static const int kBossDuckMs = 110;
  int? _duckUntilMs;

  /// 当前"音频时间"（毫秒），由 `handleAll` 按 `StampedEvent.frameIndex`
  /// 推导 —— **确定性**（同回放同结果），不依赖墙钟 ✗。
  int _nowMs = 0;

  /// 当前是否处于 Boss 命中的 duck 窗口。
  bool isDucking(int nowMs) =>
      _duckUntilMs != null && nowMs < _duckUntilMs!;

  final AssetBindingTable table;
  final AudioService service;

  /// 已解析的音乐 cue（BGM 需要按局面切换，且必须成对停止）。
  String? _currentMusicCueId;

  String? get currentMusicCueId => _currentMusicCueId;

  /// 处理一批本步事件。
  void handleAll(List<StampedEvent> events) {
    if (events.isNotEmpty) {
      final f = events.last.frameIndex;
      if (f > 0) {
        _nowMs = (f * 1000 / 60).round();
      }
    }
    for (final stamped in events) {
      handle(stamped.event);
    }
  }

  /// 从绑定里取**音频文件路径**（相对 `assets/audio/`）。
  ///
  /// `FlameAudio` 的 `audioCache` 前缀是 `assets/audio/`，
  /// 因此 manifest 里的 `assets/audio/v2/SFX-xxx.wav` 要裁掉前缀，
  /// 传 `v2/SFX-xxx.wav`。
  ///
  /// 找不到文件时**回退到 Asset ID** —— 播放会失败，但
  /// `_loadAndPlay` 里有日志（见 F-44 的可见性修复），不会完全静默。
  static String _audioFileOf(ResolvedCue match) {
    final files = match.binding.record.runtimeFiles;
    if (files.isEmpty) {
      return match.assetId.value;
    }
    const prefix = 'assets/audio/';
    final f = files.first;
    return f.startsWith(prefix) ? f.substring(prefix.length) : f;
  }

  /// 处理单个事件：解析出 cue 并请求播放。
  List<AudioCue> handle(DomainEvent event) {
    final params = audioParamsOf(event);
    final resolved = table.resolveCues(event.eventType, params);
    if (resolved.isEmpty) {
      return const <AudioCue>[];
    }

    final played = <AudioCue>[];
    for (final match in resolved) {
      final cueId = match.cueId;
      if (cueId == null) {
        continue;
      }
      // **Boss duck**：形态命中音在窗口内被抑制（见 kBossDuckMs 的说明）。
      final assetId = match.assetId.value;
      if (assetId.startsWith('SFX-V21-WPN-') && _duckUntilMs != null) {
        if (_nowMs < _duckUntilMs!) {
          continue; // 被 duck：不播这条形态命中音。
        }
      }
      if (assetId == 'SFX-V21-BOSS-HIT') {
        _duckUntilMs = _nowMs + kBossDuckMs;
      }
      final cue = AudioCue(
        cueId: cueId,
        // ⚠️ **F-44（2026-10-19 玩家实测：全程无声）**
        //
        // 这里原来填的是 **Asset ID**（如 `SFX-V21-...`），
        // 而 `FlameAudio.play()` 要的是**文件路径** ⇒ 每次播放都抛异常，
        // 又被 `_loadAndPlay` 的 `catch (_) {}` **静默吞掉** ⇒ **一声不响** ✗。
        //
        // 现在改为 manifest 里的**真实运行时文件**，并去掉
        // `FlameAudio` 的默认前缀 `assets/audio/`（它自己会加）。
        assetId: _audioFileOf(match),
        bus: _busOf(match.bus),
        priority: match.priority,
        maxVoices: match.maxVoices,
        minRetriggerMs: match.minRetriggerMs,
        loop: match.loop,
      );

      // 音乐：换曲时先停旧曲，避免叠层。
      if (cue.bus == AudioBus.music) {
        final previous = _currentMusicCueId;
        if (previous != null && previous != cue.cueId) {
          service.endLoop(previous);
        }
        _currentMusicCueId = cue.cueId;
      }

      if (service.request(cue) == AudioDecision.play) {
        played.add(cue);
      }
    }
    return played;
  }

  /// 相位变化时的音频处理：
  ///   暂停 → 挂起全部；恢复 → 只恢复，不重新起播；
  ///   离开对局 → 停止所有循环音。
  void onPhaseChanged(GamePhase from, GamePhase to) {
    if (to == GamePhase.paused) {
      service.pause();
      return;
    }
    if (from == GamePhase.paused) {
      service.resume();
      return;
    }
    if (!to.isInRun) {
      service.stopAllLoops();
      _currentMusicCueId = null;
    }
  }

  static AudioBus _busOf(String? raw) => switch (raw) {
    'Music' => AudioBus.music,
    'UI' => AudioBus.ui,
    'Warning' => AudioBus.warning,
    _ => AudioBus.sfx,
  };
}

/// 基于 `flame_audio` 的真实播放端口。
///
/// 所有异常都在这里被吞掉：音频设备缺失、编解码失败、Web 自动播放策略
/// 都**不允许**影响战斗循环（架构 §7）。
class FlameAudioPort implements AudioPort {
  FlameAudioPort();

  bool _muted = false;
  bool _paused = false;

  /// 已解码的短音效（按 asset 路径缓存，避免重复解码）。
  final Set<String> _loaded = <String>{};

  @override
  bool get isMuted => _muted;

  @override
  void setMuted(bool muted) => _muted = muted;

  @override
  void play(AudioCue cue) {
    if (_muted || _paused) {
      return;
    }
    // 真实播放是**异步**的，但战斗循环不能等它 —— 因此 fire-and-forget，
    // 并把异常收敛在这里。
    unawaitedPlay(cue);
  }

  /// 供测试重写的挂起点。
  void unawaitedPlay(AudioCue cue) {
    if (cue.loop) {
      // **FV21-AUDIO-01（玩家要求）**：「射击声要高过背景音」。
      // BGM 固定 0.32，而 SFX 用 1.0（`FlameAudio.play` 默认）
      // ⇒ SFX 明显压过 BGM，但 BGM 仍"全程都在"。
      // 若日后调音量，必须保持 **BGM < SFX** 这个关系。
      FlameAudio.bgm.play(cue.assetId, volume: 0.32).catchError((Object _) {});
      return;
    }
    _loadAndPlay(cue.assetId);
  }

  /// **已告警过的资源**（每个只警告一次，避免刷屏）。
  final Set<String> _warned = <String>{};

  Future<void> _loadAndPlay(String assetId) async {
    try {
      if (!_loaded.contains(assetId)) {
        await FlameAudio.audioCache.load(assetId);
        _loaded.add(assetId);
      }
      await FlameAudio.play(assetId);
    } catch (e) {
      // 架构 §7：音频失败**静默继续**（不能因音频崩掉战斗）。
      //
      // 但**完全静默**让我在 2026-10-19 白白多花了一轮排查 ——
      // 玩家报"全程没声音"，而代码把真实原因（传了 Asset ID 而不是路径）
      // 吞得干干净净。现在每个资源**只警告一次**：战斗照常，
      // 但开发者能在日志里看到根因。
      if (_warned.add(assetId)) {
        // ignore: avoid_print
        print('[audio] 播放失败（将静默继续）："$assetId" → $e');
      }
    }
  }

  @override
  void stop(String cueId) {
    // cueId → asset 的映射由调用方在 AudioCue 里给出；
    // 停止时直接停 BGM（持续音目前只有 BGM 与激光循环）。
    try {
      FlameAudio.bgm.stop();
    } catch (_) {}
  }

  @override
  void stopBus(AudioBus bus) {
    if (bus == AudioBus.music) {
      try {
        FlameAudio.bgm.stop();
      } catch (_) {}
    }
  }

  @override
  void pauseAll() {
    _paused = true;
    try {
      // 暂停时挂起持续音（BGM 淡出而非硬切）。
      FlameAudio.bgm.pause();
    } catch (_) {}
  }

  @override
  void resumeAll() {
    _paused = false;
    try {
      FlameAudio.bgm.resume();
    } catch (_) {}
  }
}

/// 预载音频分组（协议 §7：firstRun 预载）。
Future<void> preloadAudioGroup(
  AssetManifest manifest,
  AssetLoadGroup group,
) async {
  for (final record in manifest.inLoadGroup(group)) {
    if (!record.category.isAudio) {
      continue;
    }
    for (final file in record.runtimeFiles) {
      try {
        await FlameAudio.audioCache.load(file);
      } catch (_) {
        // 单个失败不影响其他资源（架构 §7）。
      }
    }
  }
}
