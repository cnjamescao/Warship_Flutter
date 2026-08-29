// ================================================================
// warship_game.dart —— 游戏核心逻辑
// ================================================================
//
// 这个文件实现了整个游戏的核心：一艘飞船、一群外星敌人、
// 子弹、碰撞检测、分数与生命值管理。
//
// 整体架构分为两大部分：
//
// 一、WarshipGame 类（继承 FlameGame）
//    它代表"整个游戏世界"，负责：
//      - 管理游戏状态（菜单 / 进行中 / 结束）
//      - 加载图片资源（精灵 Sprite）
//      - 处理键盘输入
//      - 实现游戏循环（每帧更新飞船、子弹、敌人的位置）
//      - 做碰撞检测、算分、扣生命
//      - 通过 ValueNotifier 把数据变化通知给 UI 层
//
// 二、三个"组件"类（Flame 的 Component）
//    它们代表游戏世界里的具体物体，会被加入游戏并渲染：
//      - PlayerShip：玩家飞船（用图片精灵显示）
//      - AlienEnemy：外星敌人（用图片精灵显示）
//      - Bullet：子弹（用纯色矩形绘制）
//
// 关键概念：Flame 的"组件树"
//    就像 Flutter 有 Widget 树一样，Flame 有 Component 树。
//    add(component) 把一个组件挂到游戏里，它就会被自动更新和绘制。
//    removeFromParent() 则把它从树上摘除（消失）。
// ================================================================

// ---------- 导入依赖 ----------

// Dart 内置的数学库，别名 math。
// 这里用到了 math.max()（取较大值），用于计算敌人排列的行列数。
import 'dart:math' as math;

// Flame 的组件库：SpriteComponent、RectangleComponent 等都在这里。
import 'package:flame/components.dart';
// Flame 的输入事件库：KeyboardEvents 混入类、KeyEvent 等。
import 'package:flame/events.dart';
// Flame 的核心：FlameGame 基类。
import 'package:flame/game.dart';
// Flutter 的 Material 库。
// 这里主要用到 ValueNotifier（值通知器）和 WidgetsBinding。
import 'package:flutter/material.dart';
// Flutter 的服务库：LogicalKeyboardKey（逻辑按键）等。
import 'package:flutter/services.dart';

/// 游戏状态的枚举。
///
/// 枚举（enum）用来表示"有限的几种取值"，
/// 比用数字 0/1/2 更易读、更安全（编译器会检查）。
enum GameState { menu, playing, gameOver }

/// WarshipGame：游戏世界主体。
///
/// 继承 FlameGame 让它具备游戏循环能力；
/// 混入（with）KeyboardEvents 让它能接收键盘事件。
class WarshipGame extends FlameGame with KeyboardEvents {
  WarshipGame();

  // ------------------------------------------------------------
  // 对外暴露的"通知器"（UI 与游戏通信的桥梁）
  // ------------------------------------------------------------
  // ValueNotifier 是 Flutter 提供的一个简单响应式容器：
  // 它内部保存一个值，当值改变时（value = xxx），
  // 所有监听它的 ValueListenableBuilder 会自动重建。
  //
  // 游戏逻辑只负责改这几个 notifier 的值，
  // UI 层（main.dart）则监听它们并自动刷新界面——
  // 双方不需要直接调用对方，这就是"解耦"。
  // ------------------------------------------------------------

  /// 当前分数通知器（初始 0）
  final ValueNotifier<int> scoreNotifier = ValueNotifier<int>(0);

  /// 历史最高分通知器（初始 0）
  final ValueNotifier<int> highScoreNotifier = ValueNotifier<int>(0);

  /// 剩余生命通知器（初始 3 条命）
  final ValueNotifier<int> livesNotifier = ValueNotifier<int>(3);

  /// 游戏状态通知器（初始为"菜单"）
  final ValueNotifier<GameState> stateNotifier = ValueNotifier<GameState>(
    GameState.menu,
  );

  // ------------------------------------------------------------
  // 游戏数值常量
  // ------------------------------------------------------------
  // 全部用 static const 声明：
  //   static —— 属于类本身，不需要实例就能访问
  //   const  —— 编译期常量，运行期不可修改
  // 把这些"魔法数字"集中在一起，方便统一调整游戏手感。
  // ------------------------------------------------------------

  static const double _shipSpeed = 420; // 飞船每秒移动的像素数
  static const double _bulletSpeed = 520; // 子弹每秒上升的像素数
  static const double _baseAlienSpeed = 90; // 敌人基础横向速度（会逐渐加快）
  static const double _alienDropSpeed = 30; // 敌人碰到边界后向下"降落"的距离
  static const int _alienPoints = 50; // 击落一个敌人的得分
  static const double _shipWidth = 64; // 飞船宽度（像素）
  static const double _shipHeight = 48; // 飞船高度（像素）
  static const double _alienWidth = 48; // 敌人宽度（像素）
  static const double _alienHeight = 40; // 敌人高度（像素）

  // ------------------------------------------------------------
  // 资源与对象引用
  // ------------------------------------------------------------

  late Sprite _shipSprite; // 飞船的图片精灵（延迟到 onLoad 加载）
  late Sprite _alienSprite; // 敌人的图片精灵
  late PlayerShip _ship; // 玩家飞船组件
  RectangleComponent? _background; // 背景色块（可空，onGameResize 时才创建）

  final List<AlienEnemy> _aliens = <AlienEnemy>[]; // 场上所有敌人
  final List<Bullet> _bullets = <Bullet>[]; // 场上所有子弹

  // ------------------------------------------------------------
  // 游戏运行时数据
  // ------------------------------------------------------------
  // 这些是"内部真实值"。UI 显示的值来自上面的 notifier，
  // 而 notifier 的值会在每帧结束后由 _markUiDirty() 统一同步。
  // ------------------------------------------------------------

  int _score = 0; // 当前分数
  int _highScore = 0; // 最高分
  int _lives = 3; // 剩余生命
  GameState _state = GameState.menu; // 当前游戏状态

  double _alienSpeed = _baseAlienSpeed; // 敌人当前横向速度（会随波次加快）
  double _alienDirection = 1; // 敌人移动方向：1 = 向右，-1 = 向左
  double _shootCooldown = 0; // 射击冷却倒计时（防止每帧都发射）

  bool _leftPressed = false; // 左方向键 / A 键是否被按住
  bool _rightPressed = false; // 右方向键 / D 键是否被按住
  bool _spacePressed = false; // 空格键是否被按住

  // ------------------------------------------------------------
  // 初始化流程相关的标志位
  // ------------------------------------------------------------
  // 游戏的初始化需要同时满足两个条件：
  //   1. 图片资源加载完成（onLoad 之后）
  //   2. 游戏画布有了明确的尺寸（onGameResize 之后）
  // 因为这两个事件是异步、先后不确定的，
  // 所以用标志位记录进度，等条件齐了再统一初始化。
  // ------------------------------------------------------------

  bool _spritesLoaded = false; // 精灵是否已加载完成
  bool _layoutReady = false; // 布局尺寸是否已就绪
  bool _initialized = false; // 是否已完成整体初始化
  bool _uiSyncScheduled = false; // 是否已安排了一次 UI 同步（避免重复安排）

  // ------------------------------------------------------------
  // 生命周期方法
  // ------------------------------------------------------------

  /// onLoad：游戏首次加载时调用一次，是 Flame 的生命周期钩子。
  ///
  /// 在这里做"异步初始化"：加载图片资源、创建飞船组件。
  @override
  Future<void> onLoad() async {
    // Sprite.load 从 assets 里读取图片（assets 在 pubspec.yaml 中声明）。
    // await 表示"等这张图加载完再继续"，因此这个方法是 async 的。
    _shipSprite = await Sprite.load('ship.png');
    _alienSprite = await Sprite.load('alien.png');

    // 创建玩家飞船组件。
    // PlayerShip 继承 SpriteComponent，用 sprite 指定图片，
    // size 指定显示尺寸（Vector2 是 Flame 的二维向量）。
    _ship = PlayerShip(
      sprite: _shipSprite,
      size: Vector2(_shipWidth, _shipHeight),
    );
    // 把飞船挂到游戏组件树上，之后它才会被更新和绘制
    add(_ship);

    // 标记精灵加载完成，尝试进入初始化
    _spritesLoaded = true;
    _tryInitialize();
  }

  /// onGameResize：游戏画布尺寸变化时调用。
  ///
  /// 首次布局完成时也会调用一次，因此它是我们获知
  /// "游戏区域有多大"的时机。
  @override
  void onGameResize(Vector2 size) {
    // 调用父类实现（Flame 内部需要同步尺寸信息）
    super.onGameResize(size);

    // 背景色块只创建一次，之后尺寸变化时直接调整大小。
    if (_background == null) {
      _background = RectangleComponent(
        size: size,
        // Paint 是绘制对象，这里配置填充颜色
        paint: Paint()..color = const Color(0xFFE6E6E6),
        // priority：渲染优先级，数字越小越先画（越在底层）。
        // 设为 -1000 确保背景永远在所有物体的后面。
        priority: -1000,
      );
      add(_background!);
    } else {
      // 已存在则更新大小（例如窗口被拉伸）
      _background!.size = size;
    }

    // 拿到有效尺寸后，标记布局就绪
    if (size.x > 0 && size.y > 0) {
      _layoutReady = true;
      _tryInitialize();
    }
  }

  /// _tryInitialize：尝试完成整体初始化。
  ///
  /// 只有在"精灵加载完成"且"布局就绪"且"尚未初始化过"时，
  /// 才真正执行。这样无论两个条件谁先谁后，都能正确初始化。
  void _tryInitialize() {
    if (_initialized || !_spritesLoaded || !_layoutReady) {
      return;
    }

    _initialized = true;
    // 把飞船放到屏幕底部中间
    _resetShip();
    // 生成第一波敌人舰队
    _createFleet();
  }

  /// startNewGame：开始新游戏（UI 按钮会调用它）。
  ///
  /// 重置所有运行时数据，然后进入 playing 状态。
  void startNewGame() {
    // 重置分数、生命、速度等
    _score = 0;
    _lives = 3;
    _alienSpeed = _baseAlienSpeed;
    _alienDirection = 1;
    _shootCooldown = 0;
    _leftPressed = false;
    _rightPressed = false;
    _spacePressed = false;

    // 如果已经初始化过（游戏世界中已有对象），
    // 先清空旧敌人和子弹，再重新摆放飞船、生成舰队。
    if (_initialized) {
      _clearAliensAndBullets();
      _resetShip();
      _createFleet();
    }

    // 切换到"游戏进行中"状态，并同步给 UI
    _state = GameState.playing;
    _markUiDirty();
  }

  // ------------------------------------------------------------
  // 输入处理
  // ------------------------------------------------------------

  /// onKeyEvent：键盘事件回调。
  ///
  /// Flame 每收到一个按键按下/抬起事件，都会调用这个方法。
  /// 返回值告诉引擎这个按键是否被我们"消费"了。
  @override
  KeyEventResult onKeyEvent(
    KeyEvent event,
    Set<LogicalKeyboardKey> keysPressed,
  ) {
    // logicalKey：逻辑按键（和物理位置无关），
    // 比如不管键盘布局如何，字母 A 就是 keyA。
    final key = event.logicalKey;

    // 左移：方向键左 或 A 键
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyA) {
      // KeyDownEvent 表示"按下"，KeyUpEvent 表示"抬起"。
      // 用 is 判断事件类型，就能得到"按键是否处于按住状态"。
      _leftPressed = event is KeyDownEvent;
      return KeyEventResult.handled; // 告诉引擎：这个键我们处理了
    }

    // 右移：方向键右 或 D 键
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyD) {
      _rightPressed = event is KeyDownEvent;
      return KeyEventResult.handled;
    }

    // 射击：空格键
    if (key == LogicalKeyboardKey.space) {
      _spacePressed = event is KeyDownEvent;
      return KeyEventResult.handled;
    }

    // 其他按键不关心，交给引擎继续处理
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------
  // 游戏循环核心：update
  // ------------------------------------------------------------

  /// update：游戏循环的核心方法，每一帧都会被 Flame 调用一次。
  ///
  /// 参数 dt（delta time）= 距上一帧经过的秒数，例如 60 帧时约为 0.0167。
  ///
  /// 为什么要乘 dt？
  ///   为了让移动速度与帧率无关：不管设备是 30 帧还是 120 帧，
  ///   "每秒移动 420 像素" 这个速度都保持不变。
  ///   公式：本帧移动距离 = 速度(像素/秒) × dt(秒)。
  @override
  void update(double dt) {
    super.update(dt);

    // 只有"游戏进行中"且"已初始化"才运行游戏逻辑
    if (_state != GameState.playing || !_initialized) {
      return;
    }

    // 防御性检查：画布尺寸无效时什么都不做
    if (size.x <= 0 || size.y <= 0) {
      return;
    }

    // ----- 1. 移动飞船 -----
    if (_leftPressed) {
      _ship.x -= _shipSpeed * dt; // 向左移动
    }
    if (_rightPressed) {
      _ship.x += _shipSpeed * dt; // 向右移动
    }
    // clamp：把飞船的 x 坐标限制在 [0, 屏幕宽 - 飞船宽] 区间，
    // 防止飞船飞出屏幕左右边界。
    _ship.x = _ship.x.clamp(0.0, size.x - _ship.width);

    // ----- 2. 射击 -----
    // 冷却倒计时递减（每帧减少 dt 秒）
    _shootCooldown -= dt;
    // 只有按住空格 且 冷却已结束 才能发射。
    // 发射后把冷却重置为 0.28 秒，限制射速，避免"每帧一颗子弹"。
    if (_spacePressed && _shootCooldown <= 0) {
      _spawnBullet();
      _shootCooldown = 0.28;
    }

    // ----- 3. 更新子弹、敌人、碰撞 -----
    _updateBullets(dt);
    _updateAliens(dt);
    _checkCollisions();
  }

  /// _spawnBullet：在飞船位置生成一颗子弹。
  void _spawnBullet() {
    // 子弹的初始 x：飞船中心再左偏 2 像素（子弹宽 4，让中心对齐）
    // 初始 y：飞船顶部再往上 12 像素（从炮口射出）
    final bullet = Bullet(Vector2(_ship.x + _ship.width / 2 - 2, _ship.y - 12));
    // 记录到列表，方便统一更新与碰撞检测
    _bullets.add(bullet);
    // 挂到组件树上，才会被绘制出来
    add(bullet);
  }

  /// _updateBullets：更新所有子弹的位置，并回收飞出屏幕的子弹。
  void _updateBullets(double dt) {
    // 用一个临时列表记录"本帧需要删除"的子弹。
    // 不能在遍历列表的同时删除元素（会打乱下标），
    // 所以先遍历记录，再统一删除——这是常见的安全写法。
    final toRemove = <Bullet>[];

    for (final bullet in _bullets) {
      bullet.y -= _bulletSpeed * dt; // 子弹向上飞
      // 完全飞出屏幕顶部时，标记待删除
      if (bullet.y < -bullet.height) {
        toRemove.add(bullet);
      }
    }

    for (final bullet in toRemove) {
      // removeFromParent：从 Flame 组件树上摘除（不再绘制/更新）
      bullet.removeFromParent();
      // 同时从我们自己的列表里移除
      _bullets.remove(bullet);
    }
  }

  /// _updateAliens：更新敌人舰队。
  ///
  /// 经典"太空侵略者"式移动：
  ///   整队敌人沿同一方向横向移动，
  ///   任一敌人碰到屏幕左右边缘 → 全体反向 + 整体下移一格。
  void _updateAliens(double dt) {
    // 先让所有敌人沿当前方向移动
    for (final alien in _aliens) {
      alien.x += _alienSpeed * _alienDirection * dt;
    }

    // 检查是否有人碰到了屏幕边缘
    var changeDirection = false;
    for (final alien in _aliens) {
      if (alien.x <= 0 || alien.x + alien.width >= size.x) {
        changeDirection = true;
        break; // 只要有一个碰到，就无需再检查其他
      }
    }

    // 需要换向时：方向取反，并且所有敌人整体下移
    if (changeDirection) {
      _alienDirection *= -1; // 1 变 -1，-1 变 1
      for (final alien in _aliens) {
        alien.y += _alienDropSpeed; // 向下逼近飞船
      }
    }
  }

  /// _checkCollisions：做所有碰撞检测。
  ///
  /// 检测三类碰撞：
  ///   1. 子弹 vs 敌人 → 敌人被击毁、子弹消失、加分
  ///   2. 飞船 vs 敌人 → 损失一条命
  ///   3. 敌人 vs 屏幕底边 → 敌人"着陆"，损失一条命
  void _checkCollisions() {
    final aliensToRemove = <AlienEnemy>[]; // 本帧被击毁的敌人
    final bulletsToRemove = <Bullet>[]; // 本帧命中的子弹

    // ----- 1. 子弹 × 敌人 -----
    // 双重循环：遍历每一颗子弹 × 每一个敌人
    for (final bullet in _bullets) {
      for (final alien in _aliens) {
        if (_overlaps(bullet, alien)) {
          bulletsToRemove.add(bullet);
          aliensToRemove.add(alien);
          break; // 一颗子弹只打一个敌人
        }
      }
    }

    // 统一移除命中的子弹和敌人
    for (final bullet in bulletsToRemove) {
      bullet.removeFromParent();
      _bullets.remove(bullet);
    }
    for (final alien in aliensToRemove) {
      alien.removeFromParent();
      _aliens.remove(alien);
    }

    // 有击毁才加分，并刷新最高分
    if (aliensToRemove.isNotEmpty) {
      _score += _alienPoints * aliensToRemove.length; // 每个敌人 50 分
      if (_score > _highScore) {
        _highScore = _score;
      }
      _markUiDirty(); // 通知 UI 刷新
    }

    // ----- 2. 敌人全灭 → 生成更快的一波 -----
    if (_aliens.isEmpty) {
      _alienSpeed += 10; // 每一波敌人移动速度 +10
      _createFleet(); // 生成新舰队
      return; // 新舰队刚生成，不必再检测下面的碰撞
    }

    // ----- 3. 飞船撞敌人 -----
    for (final alien in _aliens) {
      if (_overlaps(_ship, alien)) {
        _shipHit(); // 处理"飞船被撞"
        return; // 一条命只能损失一次，直接结束本帧碰撞检测
      }
    }

    // ----- 4. 敌人到达屏幕底部 -----
    for (final alien in _aliens) {
      if (alien.y + alien.height >= size.y) {
        _shipHit();
        return;
      }
    }
  }

  /// _overlaps：判断两个矩形组件是否重叠（AABB 碰撞检测）。
  ///
  /// AABB = Axis-Aligned Bounding Box（轴对齐包围盒）。
  /// 两个矩形不重叠的条件是下列任一成立：
  ///   a 完全在 b 左边 / b 完全在 a 左边 / a 在上 / a 在下
  /// 因此"重叠"就是四个条件同时不成立，用公式表达即：
  ///   a.x < b.x + b.width      (a 的左边在 b 的右边界的左侧)
  ///   && a.x + a.width > b.x   (a 的右边在 b 的左边界的右侧)
  ///   && a.y < b.y + b.height  (垂直方向同理)
  ///   && a.y + a.height > b.y
  bool _overlaps(PositionComponent a, PositionComponent b) {
    return a.x < b.x + b.width &&
        a.x + a.width > b.x &&
        a.y < b.y + b.height &&
        a.y + a.height > b.y;
  }

  /// _shipHit：飞船受到一次伤害。
  void _shipHit() {
    _lives -= 1; // 扣一条命
    _markUiDirty(); // 立刻同步生命数到 UI

    // 清空场上所有敌人和子弹（被撞后"清屏重来"）
    _clearAliensAndBullets();

    if (_lives > 0) {
      // 还有命：飞船归位，生成新一波敌人，继续游戏
      _resetShip();
      _createFleet();
    } else {
      // 没命了：游戏结束
      _state = GameState.gameOver;
      _markUiDirty(); // 通知 UI 显示结束画面
    }
  }

  /// _clearAliensAndBullets：移除场上所有敌人和子弹。
  void _clearAliensAndBullets() {
    // 逐个从组件树摘除
    for (final alien in _aliens) {
      alien.removeFromParent();
    }
    _aliens.clear(); // 清空列表本身

    for (final bullet in _bullets) {
      bullet.removeFromParent();
    }
    _bullets.clear();
  }

  /// _resetShip：把飞船放回屏幕底部中间。
  void _resetShip() {
    _ship.position = Vector2(
      (size.x - _ship.width) / 2, // 水平居中：左边距 = (屏宽 - 船宽) / 2
      size.y - _ship.height - 20, // 距底部 20 像素
    );
  }

  /// _createFleet：生成一整队敌人。
  ///
  /// 排列算法：
  ///   - 横向：从 x = _alienWidth 开始，每个敌人间隔 2 倍宽度
  ///     （即：一个敌人宽 + 一个空白宽）。
  ///   - 纵向：从 y = _alienHeight 开始，行间距同样是 2 倍高度。
  ///   - 行列数根据屏幕尺寸自动计算，保证敌人不会超出屏幕。
  void _createFleet() {
    // 横向可用空间：屏幕宽度两侧各留一个敌人宽度做边距
    final availableX = size.x - 2 * _alienWidth;
    // 列数 = 可用空间 / (2 倍敌人宽度)，向下取整，至少 1 列
    final cols = math.max(1, (availableX / (2 * _alienWidth)).floor());

    // 纵向可用空间：为飞船和敌人底部预留空间
    final availableY = size.y - 3 * _alienHeight - _shipHeight - 20;
    // 行数同理
    final rows = math.max(1, (availableY / (2 * _alienHeight)).floor());

    // 双重循环生成 rows × cols 个敌人
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        // 计算每个敌人的位置
        final x = _alienWidth + 2 * _alienWidth * col;
        final y = _alienHeight + 2 * _alienHeight * row;
        // 创建敌人组件
        final alien = AlienEnemy(
          sprite: _alienSprite,
          position: Vector2(x, y),
          size: Vector2(_alienWidth, _alienHeight),
        );
        // 加入列表和组件树
        _aliens.add(alien);
        add(alien);
      }
    }
  }

  /// _markUiDirty：把内部数据同步到 UI 通知器。
  ///
  /// 为什么要等"帧结束后"再同步？
  ///   一帧之内可能多次修改 _score、_lives、_state（例如一次击毁多个敌人），
  ///   如果每次都立刻改 notifier.value，会触发 UI 多次重建，浪费性能。
  ///
  /// 这里用 addPostFrameCallback 把同步动作推迟到当前帧渲染结束后，
  ///   并且用 _uiSyncScheduled 标志位保证"一帧最多同步一次"。
  ///   这样不管一帧里改了多少次数据，UI 都只刷新一次。
  void _markUiDirty() {
    // 已经安排过了就跳过，避免重复注册回调
    if (_uiSyncScheduled) {
      return;
    }
    _uiSyncScheduled = true;

    // addPostFrameCallback：注册一个"当前帧绘制完成后执行"的回调。
    // WidgetsBinding.instance 是 Flutter 引擎与框架的绑定接口。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 回调真正执行时，把标志位复位
      _uiSyncScheduled = false;

      // 把内部真实值写入通知器 → 触发 UI 层的 ValueListenableBuilder 重建
      scoreNotifier.value = _score;
      highScoreNotifier.value = _highScore;
      livesNotifier.value = _lives;
      stateNotifier.value = _state;
    });
  }
}

// ================================================================
// 游戏对象组件
// ================================================================
//
// 下面三个类都非常短，因为它们只负责"长什么样"，
// 具体行为由 WarshipGame 统一调度。
// 这种"数据/表现分离"的设计让结构更清晰。
// ================================================================

/// PlayerShip：玩家飞船组件。
///
/// 继承 SpriteComponent（精灵组件）：Flame 会用一张图片来绘制它。
class PlayerShip extends SpriteComponent {
  PlayerShip({required Sprite sprite, required Vector2 size})
    : super(
        // sprite - 用来绘制的图片
        // size   - 组件尺寸
        // anchor - 锚点，决定 position 指的是组件的哪个点。
        //          Anchor.topLeft 表示坐标 (x, y) 是左上角，
        //          这样碰撞检测时 x/y 就是矩形的左上角，计算更直观。
        sprite: sprite,
        size: size,
        anchor: Anchor.topLeft,
      );
}

/// AlienEnemy：外星敌人组件。
///
/// 与飞船一样是精灵组件，但初始 position 由外部指定
/// （因为每个敌人的位置都由舰队排列算法计算）。
class AlienEnemy extends SpriteComponent {
  AlienEnemy({
    required Sprite sprite,
    required Vector2 position,
    required Vector2 size,
  }) : super(
         sprite: sprite,
         position: position,
         size: size,
         anchor: Anchor.topLeft,
       );
}

/// Bullet：子弹组件。
///
/// 继承 RectangleComponent（矩形组件）：不需要图片，
/// 直接用一个纯色矩形表示子弹，简单高效。
class Bullet extends RectangleComponent {
  Bullet(Vector2 position)
    : super(
        position: position,
        size: Vector2(4, 12), // 宽 4、高 12 的细长矩形
        // Paint：Flutter 的绘制配置对象。
        // ".." 是级联操作符：在同一个对象上连续调用多个成员，
        // 这里相当于 paint = Paint(); paint.color = 黑色。
        paint: Paint()..color = const Color(0xFF000000),
      );
}
