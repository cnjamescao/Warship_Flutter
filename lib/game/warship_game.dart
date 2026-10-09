// ================================================================
// warship_game.dart —— Flame 场景与单帧协调
// ================================================================
//
// 职责（规格 §4 架构表）：
//   本类只负责 Flame 生命周期、固定 viewport、以及单帧流程的**编排**。
//   具体规则下沉到各自模块：
//     GameSession       状态 / 分数 / 最高分 / 生命
//     InputController   键集合 → 动作，失焦清理
//     FleetController   舰队生成、边界、波次
//     CollisionResolver AABB、唯一命中、伤害裁决
//     GameConfig        不可变数值
//
// 本文件对应代码审查反馈的两项 P1 与一项 P2：
//   * P1 固定逻辑画布：不再用窗口尺寸做规则边界；
//   * P1 输入：改为键集合，失焦/状态切换时清空；
//   * P2 生命周期：提供幂等 close()，UI 同步改为一帧一次同步提交。
// ================================================================

import 'dart:async';
import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:warship_flutter/game/collision_resolver.dart';
import 'package:warship_flutter/game/components.dart';
import 'package:warship_flutter/game/fleet_controller.dart';
import 'package:warship_flutter/game/game_audio.dart';
import 'package:warship_flutter/game/game_config.dart';
import 'package:warship_flutter/game/game_session.dart';
import 'package:warship_flutter/game/input_controller.dart';

/// 资源加载期间游戏被 [WarshipGame.close] 关闭时，`worldReady` 以此结束。
///
/// 之所以用专门的类型而不是泛化异常：
/// 调用方需要能区分"加载被取消"（正常生命周期事件，不该报警）
/// 与"加载真的失败"（需要排查的缺陷）。
class GameLoadCancelled implements Exception {
  const GameLoadCancelled();

  @override
  String toString() => 'GameLoadCancelled: 游戏在资源加载完成前已被关闭';
}

/// 游戏世界主体：Flame 生命周期 + 单帧协调。
class WarshipGame extends FlameGame with KeyboardEvents {
  WarshipGame({GameConfig? config, GameAudio? audio})
    : config = config ?? const GameConfig(),
      audio = audio ?? FlameGameAudio() {
    // 预挂一个错误处理器：若加载期间被 close()，
    // worldReady 会以 GameLoadCancelled 结束；当**没有任何人 await** 它时，
    // 该错误否则会升级为"未处理异步异常"（在测试中会直接判失败）。
    //
    // 这不影响显式 await worldReady 的调用方 —— Future 支持多个监听者，
    // 它们依然能收到这个错误。
    unawaited(_readyCompleter.future.catchError((Object _) {}));
  }

  /// 不可变规则配置。
  final GameConfig config;

  /// 音效服务（可注入，便于测试）。
  final GameAudio audio;

  /// 对局状态：唯一的只读事实来源。
  late final GameSession session = GameSession(config: config);

  /// 输入控制器。
  late final InputController input = InputController();

  /// 舰队控制器（通过回调与组件树交互）。
  late final FleetController fleet = FleetController(
    config: config,
    attach: world.add,
    detach: (alien) => alien.removeFromParent(),
  );

  /// 碰撞与伤害裁决。
  late final CollisionResolver collisions = CollisionResolver(config: config);

  // ------------------------------------------------------------
  // 就绪信号
  // ------------------------------------------------------------
  // 规格 §6：测试不得用固定 Future.delayed(500ms) 假定资源已加载，
  // 必须等待一个确定的加载完成信号。这里就是那个信号。
  // ------------------------------------------------------------
  final Completer<void> _readyCompleter = Completer<void>();

  /// 精灵资源加载完成、世界初始化完毕后完成。
  ///
  /// 命名说明：FlameGame 自身已经有一个 `ready()` 方法
  /// （语义是"等待组件树挂载操作完成"，且只能在已连接的 game 上等待），
  /// 与"资源就绪"不是一回事，因此这里命名为 `worldReady` 以避免歧义。
  Future<void> get worldReady => _readyCompleter.future;

  bool get isWorldReady => _readyCompleter.isCompleted;

  // ------------------------------------------------------------
  // 场景对象
  // ------------------------------------------------------------
  final List<Bullet> _bullets = <Bullet>[];
  PlayerShip? _ship;
  RectangleComponent? _background;
  Sprite? _shipSprite;
  Sprite? _alienSprite;

  double _shootCooldown = 0;
  bool _closed = false;

  /// 初始化守卫。
  ///
  /// 规格 §4.2 要求「sprites + world ready → **仅初始化一次**并进入菜单」。
  /// 这里显式保证幂等：
  ///   * Flame 在组件树挂载时会调用 onLoad；
  ///   * 测试为了在确定性时钟下驱动加载，也会主动调用 onLoad。
  /// 两者叠加时必须只有第一次真正执行，
  /// 否则会出现"两艘飞船、70 个敌人"这种重复初始化。
  bool _loadStarted = false;

  // ------------------------------------------------------------
  // 只读查询接口
  // ------------------------------------------------------------
  // 代码审查反馈 P2 要求「暴露最小的只读游戏查询接口」，
  // 让测试可以断言"子弹确实生成了""位置确实变了"，
  // 而不是只能断言"没崩溃"。
  // ------------------------------------------------------------
  List<Bullet> get bullets => List<Bullet>.unmodifiable(_bullets);
  PlayerShip? get ship => _ship;
  bool get isClosed => _closed;

  /// letterbox 区域（逻辑画布之外）的填充色。
  @override
  Color backgroundColor() => config.letterboxColor;

  // ------------------------------------------------------------
  // 生命周期
  // ------------------------------------------------------------

  @override
  Future<void> onLoad() async {
    // 幂等守卫：只有第一次调用真正执行初始化。
    if (_loadStarted) {
      return;
    }
    _loadStarted = true;

    try {
      _setUpFixedViewport();

      // 每个异步边界之后都必须重新确认"游戏是否已被关闭"：
      // 玩家完全可能在首帧资源加载完成前就离开了页面，
      // 此时不应再建立世界、也不应再预加载音频。
      _shipSprite = await Sprite.load('ship.png');
      if (_abortLoadIfClosed()) {
        return;
      }

      _alienSprite = await Sprite.load('alien.png');
      if (_abortLoadIfClosed()) {
        return;
      }
      fleet.sprite = _alienSprite;

      _buildWorld();

      // 音频预加载失败不影响对局，因此走 _safeAudioAsync。
      await _safeAudioAsync(audio.preload);
      if (_abortLoadIfClosed()) {
        return;
      }

      if (!_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      }
    } catch (error, stackTrace) {
      // 让等待 ready 的测试立刻失败，而不是永远挂起。
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  /// 若游戏已在异步加载期间被 close()，中止后续初始化。
  ///
  /// `worldReady` 的关闭语义：以 [GameLoadCancelled] 结束。
  /// 用专门的类型而不是泛化异常，让等待者能精确区分
  /// "**加载被取消**" 与 "**加载真的失败**"，
  /// 而不会误以为世界已经就绪。
  ///
  /// 返回 true 表示调用方应当立即中止 onLoad。
  bool _abortLoadIfClosed() {
    if (!_closed) {
      return false;
    }
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(const GameLoadCancelled());
    }
    return true;
  }

  /// 建立固定逻辑画布。
  ///
  /// 关键点：FlameGame.size 返回的是 `camera.viewport.virtualSize`，
  /// 因此装上固定分辨率 viewport 之后，`size` 恒等于 800×600，
  /// 与真实窗口尺寸完全解耦 —— 这正是规格 §3.2 的要求。
  void _setUpFixedViewport() {
    camera = CameraComponent.withFixedResolution(
      width: config.logicalWidth,
      height: config.logicalHeight,
      // 复用 FlameGame 自己的 World，避免相机自建一个空世界导致
      // 我们 add 到 world 的组件不被渲染。
      world: world,
    );
    // withFixedResolution 默认把世界原点 (0,0) 放在视口正中，
    // 而我们的世界范围是 (0,0)-(800,600)，所以要把视线中心移到世界中心。
    camera.viewfinder.position = Vector2(
      config.logicalWidth / 2,
      config.logicalHeight / 2,
    );
  }

  void _buildWorld() {
    _background = RectangleComponent(
      position: Vector2.zero(),
      size: Vector2(config.logicalWidth, config.logicalHeight),
      paint: Paint()..color = config.worldBackgroundColor,
      // 永远绘制在所有游戏对象之下
      priority: -1000,
    );
    world.add(_background!);

    _ship = PlayerShip(
      sprite: _shipSprite,
      size: Vector2(config.shipWidth, config.shipHeight),
    );
    world.add(_ship!);

    _resetShip();
    fleet.createFleet();
  }

  /// 窗口尺寸变化时触发。
  ///
  /// 规格 §3.2 第 4 条：「resize 只重算 viewport 与背景表现；
  /// 不得重排、加速、下移或损坏现存舰队。」
  /// 固定逻辑画布下这些都由 Flame 的 viewport 自动完成，
  /// 我们**刻意什么都不做** —— 实体坐标与规则边界不受任何影响。
  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
  }

  /// 幂等释放入口。
  ///
  /// 由 `_GameScreenState.dispose()` 调用；重复调用是安全的空操作。
  ///
  /// 释放后：
  ///   * 不再更新、不再向 UI 发通知、不再播放音频；
  ///   * **把本游戏创建的全部实体从 World 摘除**，再清空引用
  ///     （规格 §4.2「移除监听/组件、释放本游戏拥有的 notifier/资源」）。
  ///
  /// 注意"先 detach、后清引用"的顺序：Flame 的移除是排队处理的，
  /// 保留引用直到 detach 请求发出，语义更清晰。
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    input.clear();

    // 敌人与子弹：_clearAliensAndBullets 内部会 fleet.clear()
    // 并逐颗 detach 子弹。
    _clearAliensAndBullets();

    // 飞船与背景此前没有清理，这里补齐并清空引用。
    _ship?.removeFromParent();
    _ship = null;
    _background?.removeFromParent();
    _background = null;

    session.dispose();
    audio.dispose();
    pauseEngine();
  }

  // ------------------------------------------------------------
  // 输入
  // ------------------------------------------------------------

  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    if (_closed) {
      return KeyEventResult.ignored;
    }

    final state = session.state;
    final canPause = state == GameState.playing || state == GameState.paused;

    // ---- 暂停 / 恢复：边沿触发 ----
    // 只有 KeyDownEvent 才切换；KeyRepeatEvent 与 KeyUpEvent 都不触发，
    // 否则长按 Esc 会来回抖动。
    if (canPause && InputController.isPauseKey(event.logicalKey)) {
      if (event is KeyDownEvent) {
        togglePause();
      }
      return KeyEventResult.handled;
    }

    // ---- 移动 / 射击：只在 playing 下接受 ----
    if (state != GameState.playing) {
      // menu / paused / gameOver 一律不消费按键：
      // 既避免误吞菜单操作，也避免把暂停期间按住的键带进对局。
      return KeyEventResult.ignored;
    }

    // 未列出的键返回 false → 交还引擎（规格：不得消费未声明的键）。
    return input.handleKeyEvent(event)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// 窗口 / 应用失焦时调用。
  ///
  /// 规格 §2.2：「窗口/Flutter 焦点丢失…必须清空全部输入。」
  /// 用户切走窗口时，系统不保证会补发 KeyUpEvent，
  /// 所以必须主动清空，否则回来后会持续移动或射击。
  ///
  /// 同时**自动暂停**（已批准的暂停需求明确包含"失焦自动暂停"）：
  /// 否则切走十几秒再回来，敌人早已压到底、生命已经掉光 ——
  /// 这种"离开就被惩罚"的体验对休闲定位是致命的。
  /// 注意这里只暂停、不自动恢复：恢复必须由玩家显式触发。
  void handleFocusLost() {
    if (_closed) {
      return;
    }
    input.clear();
    pause();
  }

  // ------------------------------------------------------------
  // 暂停 / 恢复
  // ------------------------------------------------------------
  // 契约（规格 §2 状态表 paused 一行）：
  //   「不运行 | 暂停菜单 | 恢复/重开」
  // 即：世界完全冻结，分数与所有实体坐标保持不变。
  // ------------------------------------------------------------

  /// 暂停（仅在 playing 时生效）。
  void pause() {
    if (_closed || session.state != GameState.playing) {
      return;
    }
    // 规格 §2.2：暂停时必须清空输入状态，防止恢复后"粘键"继续移动或射击。
    input.clear();
    session.setState(GameState.paused);
    // 帧外路径：必须显式提交事务，否则暂停菜单不会出现。
    session.commit();
  }

  /// 恢复（仅在 paused 时生效）。
  void resume() {
    if (_closed || session.state != GameState.paused) {
      return;
    }
    // 同样清空输入：恢复的瞬间不该因为残留按键而立刻移动或开火。
    input.clear();
    session.setState(GameState.playing);
    // 帧外路径：显式提交。
    session.commit();
  }

  /// 切换暂停 / 恢复。其他状态下是安全的空操作。
  void togglePause() {
    if (_closed) {
      return;
    }
    if (session.state == GameState.playing) {
      pause();
    } else if (session.state == GameState.paused) {
      resume();
    }
  }

  bool get isPaused => session.state == GameState.paused;

  // ------------------------------------------------------------
  // 对局控制
  // ------------------------------------------------------------

  /// 开始 / 重开一局。
  void startNewGame() {
    if (_closed) {
      return;
    }
    input.clear();
    _shootCooldown = 0;

    if (_ship != null) {
      _clearAliensAndBullets();
      fleet.reset();
      _resetShip();
      fleet.createFleet();
    }

    session.startNewGame();
    session.commit();
  }

  // ------------------------------------------------------------
  // 单帧流程（严格对应规格 §5 流程图）
  // ------------------------------------------------------------

  @override
  void update(double dt) {
    super.update(dt);

    if (_closed || !session.isPlaying) {
      return;
    }
    final ship = _ship;
    if (ship == null) {
      return;
    }

    // 1. 限制单帧步长（规格 §3.3）
    final step = math.min(dt, config.maxStepSeconds);
    if (step <= 0) {
      return;
    }

    // 2. 读取动作状态 → 移动 / 夹位飞船
    _updateShip(ship, step);

    // 3. 射击冷却与生成
    _updateShooting(ship, step);

    // 4. 子弹推进与回收
    _updateBullets(step);

    // 5. 舰队边界裁决与推进
    fleet.update(step);

    // 6. 唯一命中碰撞 + 伤害裁决
    _resolveCollisions(ship);

    // 7. 一次事务只提交一次
    session.commit();
  }

  void _updateShip(PlayerShip ship, double dt) {
    final axis = input.horizontalAxis;
    if (axis != 0) {
      ship.x += config.shipSpeed * axis * dt;
    }
    // 左边界 0，右边界由配置给出（固定画布下恒为 736，不为负）。
    // shipMaxX 内部已做 max(0, ...) 保护，保证 clamp 上下界合法。
    ship.x = ship.x.clamp(0.0, config.shipMaxX);
  }

  void _updateShooting(PlayerShip ship, double dt) {
    _shootCooldown -= dt;
    if (!input.shoot || _shootCooldown > 0) {
      return;
    }
    _spawnBullet(ship);
    _shootCooldown = config.shootCooldown;
  }

  void _spawnBullet(PlayerShip ship) {
    final bullet = Bullet(
      position: Vector2(
        // 子弹水平居中于飞船
        ship.x + ship.width / 2 - config.bulletWidth / 2,
        // 从飞船顶部射出
        ship.y - config.bulletHeight,
      ),
      size: Vector2(config.bulletWidth, config.bulletHeight),
      paint: Paint()..color = config.bulletColor,
    );
    _bullets.add(bullet);
    world.add(bullet);
    _safeAudio(audio.playShoot);
  }

  void _updateBullets(double dt) {
    // 先记录再统一删除：不在遍历列表的同时删除元素。
    final toRemove = <Bullet>[];
    for (final bullet in _bullets) {
      bullet.y -= config.bulletSpeed * dt;
      if (bullet.y < -bullet.height) {
        toRemove.add(bullet);
      }
    }
    for (final bullet in toRemove) {
      bullet.removeFromParent();
      _bullets.remove(bullet);
    }
  }

  void _resolveCollisions(PlayerShip ship) {
    final outcome = collisions.resolve(
      bullets: _bullets,
      aliens: fleet.aliens,
      ship: ship,
      worldHeight: config.logicalHeight,
    );

    // ---- 命中子弹：每颗只移除一次 ----
    for (final bullet in outcome.bulletsToRemove) {
      bullet.removeFromParent();
      _bullets.remove(bullet);
    }

    // ---- 被击毁的敌人：计分只认"唯一数量" ----
    if (outcome.hasKills) {
      // FleetController.removeAll 内部负责从组件树 detach，
      // 因此这里不再重复调用 removeFromParent。
      fleet.removeAll(outcome.aliensToRemove);
      session.addScore(
        (outcome.aliensToRemove.length * config.alienPoints).round(),
      );
      _safeAudio(audio.playHit);
    }

    // ---- 舰队清空 → 提高速度并生成新一波（本帧不判伤害） ----
    if (outcome.fleetCleared) {
      fleet.onWaveCleared();
      fleet.createFleet();
      return;
    }

    // ---- 飞船受击 / 敌人触底 ----
    if (outcome.shipDamaged) {
      _shipHit();
    }
  }

  /// 掉一条命；有命则清屏重来，无命则结束。
  void _shipHit() {
    session.loseLife();
    _clearAliensAndBullets();

    if (session.lives > 0) {
      _safeAudio(audio.playLifeLost);
      _resetShip();
      fleet.createFleet();
      return;
    }

    // 结束：清空输入，避免在结算界面残留按键状态
    input.clear();
    _safeAudio(audio.playGameOver);
    session.setState(GameState.gameOver);
  }

  void _clearAliensAndBullets() {
    fleet.clear();
    for (final bullet in _bullets) {
      bullet.removeFromParent();
    }
    _bullets.clear();
  }

  void _resetShip() {
    final ship = _ship;
    if (ship == null) {
      return;
    }
    ship.position = Vector2(
      (config.logicalWidth - ship.width) / 2,
      config.shipStartY,
    );
  }

  // ------------------------------------------------------------
  // 音效安全包装
  // ------------------------------------------------------------
  // 音效不是游戏的必要条件：任何异常都在这里被隔离，
  // 保证"音频失败绝不阻塞对局"。
  // ------------------------------------------------------------

  void _safeAudio(void Function() action) {
    try {
      action();
    } catch (error) {
      assert(() {
        debugPrint('[Warship] 音频调用失败，已忽略：$error');
        return true;
      }());
    }
  }

  Future<void> _safeAudioAsync(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      assert(() {
        debugPrint('[Warship] 音频预加载失败，已忽略：$error');
        return true;
      }());
    }
  }
}
