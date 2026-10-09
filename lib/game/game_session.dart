// ================================================================
// game_session.dart —— 对局状态（唯一事实来源）
// ================================================================
//
// 规格要求（Warship产品设计.md §4.1）：
//   「score、highScore、lives、state 是游戏层唯一事实来源。UI 只读，不得写入。」
//   「一次规则事务提交时，所有对应的只读 listenable 必须同步为可见值；
//     正确性不得依赖 WidgetsBinding.addPostFrameCallback。」
//   「允许一次事务只通知一次，但 listener 读取值必须与已提交游戏事实一致。」
//
// ---------------------------------------------------------------
// 为什么不用四个独立的 ValueNotifier？
// ---------------------------------------------------------------
// 四个 ValueNotifier 必然要逐个赋值，而每个赋值都会**同步**触发自己的
// listener。于是监听 scoreNotifier 的回调被唤醒时，
// highScoreNotifier 可能还停留在旧值 —— 这正是"中间态"。
// （本项目的第一版实现就踩了这个坑，并被 T10 测试抓了出来。）
//
// 现在的做法：
//   * 内部字段是唯一真相；
//   * 只有一个通知源 `_revision`（单调递增的修订号）；
//   * 四个对外 listenable 都是"读当前字段 + 监听同一个通知源"的视图。
// 这样一次事务只发一次通知，且任何 listener 被唤醒时读到的
// 四个值必然全部是已提交的最终值。
// ================================================================

import 'package:flutter/foundation.dart';
import 'package:warship_flutter/game/game_config.dart';

/// 游戏状态机。
///
/// `paused` 已由产品批准纳入本轮范围（原文档标为 [提议]）。
///
/// 暂停的语义是**世界完全冻结**：
///   * 不推进任何规则（移动 / 射击 / 碰撞 / 计分）；
///   * 不改变分数、生命与任何实体坐标；
///   * 只允许"恢复"与"重开"两个操作。
enum GameState { menu, playing, paused, gameOver }

/// 只读视图：`value` 实时读取 session 的当前字段，
/// 但监听的是 session 唯一的修订号通知源。
class _SessionView<T> implements ValueListenable<T> {
  _SessionView(this._session, this._read);

  final GameSession _session;
  final T Function(GameSession session) _read;

  @override
  T get value => _read(_session);

  @override
  void addListener(VoidCallback listener) =>
      _session._revision.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _session._revision.removeListener(listener);
}

/// 对局状态容器：分数 / 最高分 / 生命 / 状态。
class GameSession {
  GameSession({required this.config}) : _lives = config.initialLives;

  final GameConfig config;

  /// 唯一的通知源：一次规则事务提交只 +1。
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  // ------------------------------------------------------------
  // 对外只读通道
  // ------------------------------------------------------------
  // UI 只订阅这些 listenable，绝不写入。
  // ------------------------------------------------------------
  late final ValueListenable<int> scoreNotifier = _SessionView<int>(
    this,
    (session) => session._score,
  );
  late final ValueListenable<int> highScoreNotifier = _SessionView<int>(
    this,
    (session) => session._highScore,
  );
  late final ValueListenable<int> livesNotifier = _SessionView<int>(
    this,
    (session) => session._lives,
  );
  late final ValueListenable<GameState> stateNotifier =
      _SessionView<GameState>(this, (session) => session._state);

  // ------------------------------------------------------------
  // 内部字段（真正的权威值）
  // ------------------------------------------------------------
  int _score = 0;

  /// 最高分在**当前进程内**跨局保留（规格 §2.1 第 1 条）。
  /// 持久化到磁盘属于 [提议] 项，不在 v1.1 范围。
  int _highScore = 0;
  int _lives;
  GameState _state = GameState.menu;
  bool _disposed = false;

  /// 本事务内是否有尚未提交的变更。
  ///
  /// 规则方法只修改字段并置脏，真正的通知统一发生在 [commit]。
  bool _dirty = false;

  int get score => _score;
  int get highScore => _highScore;
  int get lives => _lives;
  GameState get state => _state;
  bool get isPlaying => _state == GameState.playing;
  bool get isDisposed => _disposed;

  // ------------------------------------------------------------
  // 规则事务
  // ------------------------------------------------------------
  // 【事务边界】
  //   * 规则方法（startNewGame / addScore / loseLife / setState）
  //     只修改字段并把事务标记为脏，**不发送任何通知**；
  //   * 只有 commit() 才会把本事务累积的全部变更一次性发布出去。
  //
  // 为什么必须这样（代码审查反馈 P2）：
  //   同一帧内完全可能连续发生多次规则变更 —— 例如一帧里既击毁敌人
  //   （加分）又有一名敌人触底（掉命）。如果每个变更方法各自发布，
  //   消费者就会收到若干"中间提交"，
  //   v1.1「一次规则事务只通知一次」的契约并不成立。
  //
  // 【调用方责任】
  //   * 帧循环：在每帧末尾调用一次 commit()（见 WarshipGame.update）；
  //   * 帧外路径（按钮 / 快捷键触发的 startNewGame、pause、resume）：
  //     必须在变更后**显式** commit()，否则 UI 不会收到通知。
  //
  // 所有变更方法在【已释放】之后都是安全的空操作：
  // 释放意味着这个会话彻底结束，不再接受任何规则写入，
  // 从而杜绝"已释放对象仍被更新"这一类隐患。
  // ------------------------------------------------------------

  /// 开始新一局：重置分数与生命，但**保留**进程内最高分。
  void startNewGame() {
    if (_disposed) {
      return;
    }
    _score = 0;
    _lives = config.initialLives;
    _state = GameState.playing;
    _dirty = true;
  }

  /// 增加分数，并同步刷新最高分。
  void addScore(int points) {
    if (_disposed || points <= 0) {
      return;
    }
    _score += points;
    if (_score > _highScore) {
      _highScore = _score;
    }
    _dirty = true;
  }

  /// 损失一条生命（不会低于 0）。
  void loseLife() {
    if (_disposed || _lives <= 0) {
      return;
    }
    _lives -= 1;
    _dirty = true;
  }

  /// 切换状态。
  void setState(GameState value) {
    if (_disposed || _state == value) {
      return;
    }
    _state = value;
    _dirty = true;
  }

  /// 提交一次规则事务：把本事务内累积的全部变更**一次性**发布。
  ///
  /// 对应规格 §5 单帧流程图里的 "Commit GameSession once"。
  ///
  /// 幂等：没有未提交变更时是安全空操作，不会产生多余通知；
  /// 释放之后同样是空操作（规格 §4.2：释放后不得再向 UI 发通知）。
  ///
  /// 注意：字段一定在调用本方法**之前**就已经写好，
  /// 因此 listener 被唤醒时读到的永远是一致且最终的值。
  void commit() {
    if (_disposed || !_dirty) {
      return;
    }
    _dirty = false;
    // 唯一的通知点：一次事务 = 一次 revision +1。
    _revision.value++;
  }

  /// 是否存在尚未提交的变更（测试与调试用）。
  bool get hasPendingChanges => _dirty;

  /// 幂等释放。
  ///
  /// 由 [WarshipGame.close] 调用；重复调用是安全的空操作。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _revision.dispose();
  }
}
