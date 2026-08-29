// ================================================================
// main.dart —— 应用入口与主界面
// ================================================================
//
// 这个文件负责两件事：
//   1. main() 函数：整个 Flutter 应用的启动入口。
//   2. 构建游戏主界面：把 Flame 游戏画布（GameWidget）和
//      Flutter 的 UI 元素（HUD 抬头显示、菜单/结束遮罩）叠在一起。
//
// 简单理解：main.dart 是"外壳"，真正的游戏逻辑在
// game/warship_game.dart 中实现。
// ================================================================

// ---------- 导入依赖 ----------

// Flame 游戏引擎，提供游戏循环、精灵渲染等能力。
import 'package:flame/game.dart';
// Flutter 的 Material 组件库，提供 MaterialApp、Scaffold、Text、Button 等 UI 组件。
import 'package:flutter/material.dart';

// 我们自己的游戏逻辑类。路径写法是相对当前文件(main.dart)的：
// main.dart 位于 lib/，所以 game/warship_game.dart 就是
// lib/game/warship_game.dart。
import 'game/warship_game.dart';

/// 程序的入口函数。
///
/// 任何 Dart 程序都是从 main() 开始执行的；
/// 对 Flutter 应用来说，main() 里通常只做一件事：
/// 调用 runApp() 把根组件挂载到屏幕上。
void main() {
  // runApp：Flutter 框架提供的启动函数。
  // 它会把传入的 Widget 作为"应用根节点"渲染出来。
  // const 表示该对象在编译期就确定，可以避免不必要的重建，提升性能。
  runApp(const WarshipApp());
}

/// WarshipApp：整个应用的根组件。
///
/// 继承 StatelessWidget（无状态组件），因为应用本身没有需要
/// 动态变化的内部状态——它只是配置主题并指向主页面。
class WarshipApp extends StatelessWidget {
  /// const 构造函数。
  /// 用 const 修饰后，框架可以在合适时机复用同一个实例，减少开销。
  /// super.key 表示把 key 参数原样传给父类 StatelessWidget。
  const WarshipApp({super.key});

  /// build 是 Widget 的核心方法。
  ///
  /// 它的职责是"描述这个组件长什么样"：
  /// 根据当前状态，返回一棵 Widget 树，Flutter 负责把它绘制出来。
  /// 状态不变时，这个方法的输出也不会变（Stateless 的含义）。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // 应用标题（任务栏/系统层面显示用）
      title: 'Warship',
      // 关闭调试模式下右上角的 "DEBUG" 横幅
      debugShowCheckedModeBanner: false,
      // 主题配置
      theme: ThemeData(
        // ColorScheme.fromSeed：从一个"种子颜色"自动生成
        // 一整套协调的配色（主色、辅助色、对比色等），
        // 是 Material 3 推荐的配色方式。
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        // 启用 Material 3 设计风格
        useMaterial3: true,
      ),
      // 应用启动后显示的第一个页面
      home: const GameScreen(),
    );
  }
}

/// GameScreen：游戏画面组件。
///
/// 继承 StatefulWidget（有状态组件）。
/// 为什么需要"有状态"？因为我们要在 initState 里创建游戏对象，
/// 而这个对象必须保存在某个地方，让 build 能拿到它。
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  /// 创建并返回与这个 Widget 绑定的 State 对象。
  ///
  /// StatefulWidget 本身是不可变的，真正可变的状态
  /// 保存在 State 里。Flutter 会自动调用本方法完成绑定。
  @override
  State<GameScreen> createState() => _GameScreenState();
}

/// _GameScreenState：GameScreen 对应的状态类。
///
/// 类名前缀下划线 "_" 是 Dart 的"私有"约定：
/// 表示这个类只在当前文件内可见（Dart 没有 private 关键字）。
class _GameScreenState extends State<GameScreen> {
  /// 游戏逻辑对象。
  ///
  /// late 关键字表示"延迟初始化"：先声明变量，
  /// 承诺在真正使用之前一定完成赋值。
  /// 这里选择 late + final，是因为 _game 在 initState 里才创建，
  /// 但创建之后永远不会再改变指向（final = 只读引用）。
  late final WarshipGame _game;

  /// HUD（抬头显示）文字的统一样式。
  ///
  /// static const：属于类本身而不是某个实例，且编译期确定。
  /// 把样式抽成常量可以避免每次 build 都重新创建 TextStyle。
  static const _hudStyle = TextStyle(
    color: Colors.black87, // 接近黑色但不刺眼
    fontSize: 16,
    fontWeight: FontWeight.w600, // 半粗体
  );

  /// initState：State 对象创建后只会调用一次的生命周期方法。
  ///
  /// 适合做"一次性初始化"工作，比如创建游戏对象。
  /// 注意：这里不能用 context 去获取 InheritedWidget，
  /// 但创建普通对象是完全安全的。
  @override
  void initState() {
    // 必须先调用父类的 initState，这是 Flutter 的约定
    super.initState();
    // 创建真正的游戏逻辑对象（包含游戏循环、敌人、子弹等）
    _game = WarshipGame();
  }

  /// build：构建游戏页面的界面结构。
  ///
  /// 页面一共分三层，用 Stack 叠加（后写的在上层）：
  ///   1. 游戏画布 GameWidget（最底层）
  ///   2. HUD 信息条（分数/生命/最高分）
  ///   3. 遮罩层（菜单 / 游戏结束画面）
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 背景色，和游戏画布保持一致，避免出现色差边框
      backgroundColor: const Color(0xFFE6E6E6),
      // SizedBox.expand：强制子组件铺满整个可用区域
      body: SizedBox.expand(
        // Stack：层叠布局，children 依次从下往上叠放
        child: Stack(
          children: [
            // Positioned.fill：让子组件填满 Stack 的整个区域。
            // 这里相当于告诉 GameWidget："占满全屏"。
            Positioned.fill(
              // GameWidget 是 Flame 引擎提供的桥接组件：
              // 它把一个 FlameGame 实例接入 Flutter 的组件树，
              // 并负责启动游戏循环、把每一帧渲染出来。
              child: GameWidget(game: _game),
            ),
            // HUD 层：分数、最高分、生命数
            _buildHud(),
            // 遮罩层：根据游戏状态显示菜单或"游戏结束"
            // 用 Positioned.fill 保证遮罩也能铺满全屏、居中显示
            Positioned.fill(child: _buildOverlay()),
          ],
        ),
      ),
    );
  }

  /// 构建 HUD（抬头显示）信息条。
  ///
  /// HUD 放在 SafeArea 里，避免文字被刘海屏/状态栏遮挡。
  Widget _buildHud() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        // Row：水平排列三个信息文本
        child: Row(
          // spaceBetween：两端对齐，中间均匀留白
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          // 顶部对齐（文本高度不同时不会错位）
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- 生命数 ----------
            // ValueListenableBuilder：响应式 UI 的核心组件。
            //
            // 原理：它监听一个 ValueNotifier 对象；
            // 只要 notifier.value 发生变化，它就会自动重建
            // 自己的 builder，用新值重新生成界面。
            //
            // 这里监听 _game.livesNotifier（游戏对象暴露出来的
            // "生命数"通知器），游戏内部改生命数时，UI 自动刷新。
            // 优点：UI 与游戏逻辑解耦，不需要手动 setState。
            ValueListenableBuilder<int>(
              valueListenable: _game.livesNotifier,
              // builder 的三个参数：
              //   context - 构建上下文
              //   lives   - notifier 当前的值（int）
              //   _       - 子组件（这里没用，用 _ 占位）
              builder: (context, lives, _) {
                // $lives 是字符串插值语法：把变量拼进字符串
                return Text('Ships: $lives', style: _hudStyle);
              },
            ),
            // ---------- 最高分 ----------
            ValueListenableBuilder<int>(
              valueListenable: _game.highScoreNotifier,
              builder: (context, highScore, _) {
                return Text('High Score: $highScore', style: _hudStyle);
              },
            ),
            // ---------- 当前分数 ----------
            ValueListenableBuilder<int>(
              valueListenable: _game.scoreNotifier,
              builder: (context, score, _) {
                return Text('Score: $score', style: _hudStyle);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 构建遮罩层。
  ///
  /// 根据游戏状态显示不同内容：
  ///   - GameState.menu     → 显示标题 + "Play" 按钮
  ///   - GameState.gameOver → 显示 "Game Over" + 分数 + "Play Again" 按钮
  ///   - GameState.playing  → 什么都不显示（返回一个零尺寸组件）
  Widget _buildOverlay() {
    // 监听游戏状态通知器：状态一变，整个遮罩自动重建
    return ValueListenableBuilder<GameState>(
      valueListenable: _game.stateNotifier,
      builder: (context, state, _) {
        // 游戏进行中：返回一个不占空间的空组件（相当于隐藏遮罩）
        if (state == GameState.playing) {
          return const SizedBox.shrink();
        }

        // 是"菜单"还是"游戏结束"？
        final isMenu = state == GameState.menu;

        // 半透明黑色背景，把游戏画面压暗，突出弹窗
        return Container(
          color: Colors.black45,
          // 让子组件在容器内居中
          alignment: Alignment.center,
          child: Column(
            // mainAxisSize.min：列的高度按内容收缩，而不是撑满
            mainAxisSize: MainAxisSize.min,
            children: [
              // 大标题：菜单显示游戏名，结束显示 Game Over
              Text(
                isMenu ? 'Alien Invasion' : 'Game Over',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                ),
              ),
              // 只有"游戏结束"时才显示本局分数
              // if + 展开运算符(...)：
              //   条件为 true 时，把后面的列表元素展开进 children
              if (!isMenu) ...[
                const SizedBox(height: 12),
                ValueListenableBuilder<int>(
                  valueListenable: _game.scoreNotifier,
                  builder: (context, score, _) {
                    return Text(
                      'Score: $score',
                      style: const TextStyle(color: Colors.white, fontSize: 22),
                    );
                  },
                ),
              ],
              const SizedBox(height: 24),
              // FilledButton：Material 3 的实心按钮
              FilledButton(
                // 点击后调用游戏的"开始新游戏"方法
                onPressed: _game.startNewGame,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Text(
                    // 菜单里显示 Play，结束画面显示 Play Again
                    isMenu ? 'Play' : 'Play Again',
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
