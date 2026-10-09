// ================================================================
// game_audio.dart —— 音效服务
// ================================================================
//
// 音效在规格里原本是 [提议] 项；经产品确认后提升进 v1.1，
// 因此这里引入 flame_audio 并定义静音开关。
//
// 设计原则：**音频是锦上添花，绝不能影响对局。**
//   1. 所有播放调用都是 fire-and-forget，异常被就地吞掉；
//   2. 加载或播放失败时自动降级为静音，游戏照常运行；
//   3. 通过 GameAudio 接口注入，测试可用 SilentGameAudio / 假实现，
//      完全不需要真实的音频后端。
//
// 音频素材由 `tool/generate_audio.dart` 现场合成（方波 + 噪声 + 指数衰减），
// 不引入任何第三方素材，因此没有授权问题，四个文件合计约 52KB。
// ================================================================

import 'dart:async';

import 'package:flame_audio/flame_audio.dart';
import 'package:flutter/foundation.dart';

/// 音效契约。
///
/// 具体实现见 [FlameGameAudio]（真实播放）与 [SilentGameAudio]（静默）。
abstract class GameAudio {
  /// 静音状态。UI 订阅它来切换图标。
  final ValueNotifier<bool> mutedNotifier = ValueNotifier<bool>(false);

  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get isMuted => mutedNotifier.value;

  /// 设置静音。
  void setMuted(bool value) {
    if (_disposed || mutedNotifier.value == value) {
      return;
    }
    mutedNotifier.value = value;
  }

  /// 切换静音。
  void toggleMute() => setMuted(!isMuted);

  /// 预加载全部音效（失败不应抛出）。
  Future<void> preload();

  void playShoot();
  void playHit();
  void playLifeLost();
  void playGameOver();

  /// 幂等释放。
  @mustCallSuper
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    mutedNotifier.dispose();
  }
}

/// 真实音频实现（基于 flame_audio）。
class FlameGameAudio extends GameAudio {
  static const String shootFile = 'shoot.wav';
  static const String hitFile = 'hit.wav';
  static const String lifeLostFile = 'life_lost.wav';
  static const String gameOverFile = 'game_over.wav';

  /// 每个音效复用一个 AudioPlayer：
  /// 射击声每秒会触发 3~4 次，如果每次都新建播放器会造成明显的对象churn。
  final Map<String, AudioPlayer> _players = <String, AudioPlayer>{};

  /// 一旦音频子系统不可用（例如没有平台插件），
  /// 就整体降级为静默，避免每帧都去尝试并抛异常。
  bool _available = true;

  @override
  Future<void> preload() async {
    if (isDisposed || !_available) {
      return;
    }
    try {
      // FlameAudio 的缓存前缀默认是 'assets/audio/'
      await FlameAudio.audioCache.loadAll(<String>[
        shootFile,
        hitFile,
        lifeLostFile,
        gameOverFile,
      ]);
    } catch (_) {
      _available = false;
    }
  }

  @override
  void playShoot() => _play(shootFile, volume: 0.35);

  @override
  void playHit() => _play(hitFile, volume: 0.55);

  @override
  void playLifeLost() => _play(lifeLostFile, volume: 0.6);

  @override
  void playGameOver() => _play(gameOverFile, volume: 0.6);

  void _play(String file, {required double volume}) {
    if (isDisposed || isMuted || !_available) {
      return;
    }
    // fire-and-forget：不 await，也不让任何异常泄漏到游戏循环。
    unawaited(_playSafely(file, volume));
  }

  Future<void> _playSafely(String file, double volume) async {
    try {
      final player = _players.putIfAbsent(file, AudioPlayer.new);
      await player.stop();
      await player.play(AssetSource('audio/$file'), volume: volume);
    } catch (_) {
      _available = false;
    }
  }

  @override
  void dispose() {
    if (isDisposed) {
      return;
    }
    for (final player in _players.values) {
      unawaited(player.dispose().catchError((Object _) {}));
    }
    _players.clear();
    super.dispose();
  }
}

/// 静默实现：用于测试与无声环境。
class SilentGameAudio extends GameAudio {
  @override
  Future<void> preload() async {}

  @override
  void playShoot() {}

  @override
  void playHit() {}

  @override
  void playLifeLost() {}

  @override
  void playGameOver() {}
}
