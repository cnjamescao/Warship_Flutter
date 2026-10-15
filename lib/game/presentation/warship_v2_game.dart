// ================================================================
// lib/game/presentation/warship_v2_game.dart —— Flame 表现层
// ================================================================
// 依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §6
//   「Flame Component 以 entityId 绑定 Domain 实体；每帧只读取
//     RenderSnapshot 更新位置、动画、可见性和视觉状态。」
//   「背景、粒子、残影等纯表现对象可不创建 Domain 实体，
//     但必须由 DomainEvent 触发且受性能上限控制。」
//
// 逻辑世界固定 1920×1080，由 CameraComponent.withFixedResolution 提供
// letterbox 自适应 —— 与屏幕分辨率解耦（产品基线 §2）。
//
// 渲染策略：整个战场由**单个** Component 一次性绘制，
// 不为每个实体创建/销毁 Flame 组件。理由：
//   * 逻辑实体每帧可能大量增删，组件生命周期开销不值得；
//   * 快照本身就是完整的绘制指令，逐一映射成组件只会多一层间接。
// 表现层只读快照，绝不回写 Domain。
// ================================================================

import 'dart:io';
import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Image;

import '../content/asset_manifest.dart';
import '../core/game_runtime.dart';
import '../domain/values.dart';
import '../core/baseline_recorder.dart';
import '../core/render_snapshot.dart';
import '../infrastructure/performance_monitor.dart';
import '../infrastructure/asset_loader.dart';
import 'asset_cache.dart';
import 'colorblind_patterns.dart';

import 'elite_affix_visuals.dart';
import 'visual_effects.dart';
import 'visual_router.dart';
import 'input_gateway.dart';

/// 取景器应瞄准的世界坐标 —— **逻辑世界的中心**（F-27）。
///
/// Flame 的 `Viewfinder.position` 语义是「被放到**屏幕中心**的那个世界
/// 坐标」。默认值是 `Vector2.zero()`，那会让世界原点落在屏幕中心，
/// 玩家只看到世界右下 1/4（开局看不到飞船、最左只能移动到屏幕中线）。
/// 取世界中心即可让视口正好覆盖 `(0,0)..(1920,1080)`。
///
/// 抽成纯函数是为了能**直接测**，不必驱动整个游戏循环
/// （`onLoad` 需要完整挂载，测试里会挂住）。
Vector2 viewfinderCenterForWorld() =>
    Vector2(kLogicalWidth / 2, kLogicalHeight / 2);

/// 玩家机体的正式素材 ID（F-26-02 的首屏关键资源）。
const String kPlayerBaseAssetId = 'GFX-PLAYER-BASE';

/// 把资源诊断写到**固定文件**（`/tmp/warship_assets.log`）。
///
/// 存在理由：F-26-02 的现场是"玩家看到图形不对"，而研发既看不到画面、
/// 也无法自动化玩家输入。把诊断落盘后，玩家只要玩一次，研发就能拿到
/// "加载成功几张、哪几条失败、玩家素材到底能不能取到"的真实数据，
/// 不必靠猜。
void writeAssetDiagnostics(String text) {
  if (kIsWeb) {
    return;
  }
  // ⚠️ macOS 应用是**沙盒**的：`/tmp` 与 `~/Desktop` 都会被拦。
  // 沙盒下 `HOME` 指向容器内的 Data 目录，因此写 `$HOME/Documents/`
  // 一定可写，而且**研发能从这里读到**
  // （`~/Library/Containers/<bundle-id>/Data/Documents/`）。
  //
  // 我第一版写死 `/tmp/warship_assets.log` 并被 catch 静默吞掉 ——
  // 结果**什么都没写出来，而我以为写了**。因此这里把失败也记下来，
  // 绝不再静默。
  for (final dir in <String>[
    '${Platform.environment['HOME'] ?? ''}/Documents',
    Directory.systemTemp.path,
  ]) {
    if (dir.isEmpty) {
      continue;
    }
    try {
      final target = File('$dir/warship_assets.log');
      target.writeAsStringSync(
        '${DateTime.now().toIso8601String()}\n$text\n',
      );
      return;
    } catch (error) {
      debugPrint('[assets] 诊断写入失败（$dir）：$error');
    }
  }
}

/// v2.0 逻辑世界尺寸（产品基线 §2）。
const double kLogicalWidth = 1920;
const double kLogicalHeight = 1080;

/// 主 Flame 游戏。
class WarshipV2Game extends FlameGame {
  WarshipV2Game({
    required this.runtime,
    required this.input,
    required this.visualAssets,
    this.onSnapshot,
    this.onFrame,
    this.baselineRecorder,
    this.preloadAssets = true,
    this.reduceMotion = false,
    PerformanceMonitor? performance,
  }) : performance = performance ?? PerformanceMonitor();

  final GameRuntime runtime;
  final KeyboardInputGateway input;

  /// 图形资源缓存（键一律来自 manifest 的 runtimeFiles）。
  /// 刻意不叫 assets —— Flame 的 Game 已有同名成员。
  final VisualAssetCache visualAssets;

  /// 每帧回调（HUD 用它刷新，避免 Widget 直接读 Flame 组件）。
  final void Function(RenderSnapshot snapshot)? onSnapshot;

  /// 每帧结束后的回调（上层用它判断对局是否结束）。
  final VoidCallback? onFrame;

  /// AC-06 基准录制器（协议 §5.1）。**默认为 null —— 不录制**。
  /// 只有指定基准操作员的那一次真实通关才开启它。
  final BaselineRecording? baselineRecorder;

  /// 帧时间采样与降级决策。
  final PerformanceMonitor performance;

  /// 是否开启「降低动效」（产品设计 §8 第 280 行要求提供的无障碍开关）。
  ///
  /// 实现方式：把它当成一个**降级地板** —— 非关键表现
  /// （星云、非关键粒子、命中碎片）一律关闭，
  /// 但**预警、HUD、碰撞与伤害数字保持**（设置页文案承诺
  /// 「只降低非关键动效，预警仍然清晰」）。
  bool reduceMotion;

  /// 是否在创建时预载 `firstRun` 分组。
  ///
  /// 默认 `true`（生产行为）。测试里置 `false`：预载走
  /// `Flame.images.load` → `rootBundle`，那是**真实 I/O**，
  /// 在 `testWidgets` 的假异步区里不会完成。
  /// 关掉后表现层走矢量占位，**规则完全不受影响**（架构 §7），
  /// 因此结构性 UI 断言仍然有效。
  final bool preloadAssets;

  /// 事件驱动的纯表现特效（碎片、伤害数字）。
  final VisualEffects effects = VisualEffects();

  /// 视觉路由：把 DomainEvent 经 `eventBindings` 解析成
  /// assetId/renderState（协议明文要求，禁止直接猜资源）。
  late final VisualRouter visualRouter =
      VisualRouter(table: const AssetLoader().build(visualAssets.manifest));

  late final BattlefieldComponent _battlefield;

  /// 最近一帧快照（供 HUD 读取）。
  RenderSnapshot latestSnapshot = RenderSnapshot.empty;

  /// 累计渲染帧数（诊断用）。
  int renderedFrames = 0;


  @override
  Color backgroundColor() => const Color(0xFF05030F);

  @override
  Future<void> onLoad() async {
    camera = CameraComponent.withFixedResolution(
      width: kLogicalWidth,
      height: kLogicalHeight,
      world: world,
    );

    // F-27（P0）：**把取景器对准逻辑世界的中心**。
    //
    // `withFixedResolution` 用的是默认 `Viewfinder()`，而 Flame 的
    // `Viewfinder.position` 语义是「**被放到屏幕中心**的那个世界坐标」，
    // 其默认值是 `Vector2.zero()` —— 于是**世界原点落在屏幕中心**：
    //   * 玩家在世界 (960, 900)，直接跑到屏幕右下之外 → 开局看不到飞船；
    //   * 世界左边界 x≈30 映射到屏幕中心附近 → "最多只能移动到中线"；
    //   * 只能看到世界右下 1/4，HUD 与战场自然都错位。
    //
    // 修正后：世界 (0,0)..(1920,1080) 正好铺满视口。
    camera.viewfinder.position = viewfinderCenterForWorld();
    // 预载 firstRun 分组（协议 §7）。
    if (preloadAssets) {
      await visualAssets.loadGroup(AssetLoadGroup.firstRun);

      // **lazy 分组也必须加载。**
      //
      // 此前只加载 firstRun，而**敌机、敌弹、部分战机的贴图都在 lazy 里** ——
      // 于是它们永远取不到图，一律退回程序化占位图形
      // （玩家看到的"奇奇怪怪的紫色三角形"）。
      // 协议允许 lazy 惰性加载，但要求"**不得造成攻击缺贴图**"，
      // 因此这里在进入可玩状态前一次性加载完毕。
      await visualAssets.loadGroup(AssetLoadGroup.lazy);

      // F-26-02：**把预载结果记录下来**。
      //
      // 此前预载失败是完全静默的 —— 玩家看到的是"两个圆点"，
      // 而没有任何一处告诉他/我们为什么。裁决要求检查 firstRun
      // 预载结果与每个 `AssetLoadFailure`，因此这里必须留下可诊断记录。
      // 除控制台外，**同时写入诊断文件** —— 这样即使拿不到界面截图，
      // 也能在事后拿到"到底加载了什么、失败在哪一条"的真实数据。
      final report = StringBuffer()
        ..writeln('firstRun 预载：成功 ${visualAssets.loadedCount}，'
            '失败 ${visualAssets.failures.length}')
        ..writeln('玩家素材可取=${visualAssets.imageFor(kPlayerBaseAssetId, 'default') != null}');
      for (final failure in visualAssets.failures.take(20)) {
        report.writeln('  失败 $failure');
      }
      debugPrint('[assets] ${report.toString().trim()}');
      writeAssetDiagnostics(report.toString());

      // 首屏关键资源就绪断言（裁决第 2 条）：玩家机体是
      // **release_ready 且首屏关键**的资源，它没就绪就不该进入可玩状态 ——
      // 否则玩家面对的是无法辨认的占位图形。
      if (visualAssets.imageFor(kPlayerBaseAssetId, 'default') == null) {
        debugPrint(
          '[assets] ❌ 首屏关键资源未就绪：$kPlayerBaseAssetId —— '
          '玩家机体将退化为占位图形。这是**资源接入故障**，不是设计。',
        );
      }
    }

    _battlefield = BattlefieldComponent(
      runtime: runtime,
      assets: visualAssets,
      effects: effects,
      router: visualRouter,
    )..degradation = _effectiveDegradation;
    world.add(_battlefield);
  }

  /// 实际生效的视觉档位。
  ///
  /// 取「性能降级」与「降低动效地板」中**更严格**的那个。
  static const DegradationLevel _reduceMotionFloor =
      DegradationLevel.hitDebris;

  /// 实际生效的视觉档位（对外可读，便于测试断言"降低动效确实生效"）。
  DegradationLevel get effectiveDegradation => _effectiveDegradation;

  DegradationLevel get _effectiveDegradation {
    final perf = performance.level;
    if (!reduceMotion) {
      return perf;
    }
    return perf.index >= _reduceMotionFloor.index ? perf : _reduceMotionFloor;
  }

  @override
  void update(double dt) {
    // 0. 帧时间采样 → 降级决策（产品基线 §2 的 95%/99% 预算）。
    performance.recordFrame(dt);
    _battlefield.degradation = _effectiveDegradation;

    // 1. 取本帧输入（锁定后交给运行时）。
    final frame = input.consume();

    // 2. 推进逻辑。非 Playing 状态内部会自动冻结。
    //
    // AC-06 基准录制（协议 §5.1）：在**唯一的推进点**逐帧记录真实输入，
    // 保证录下来的就是实际发生的，不存在"另一条路径"。
    baselineRecorder?.recordFrame(frame);
    runtime.advance(dt, frame);
    // 记录本帧真实事件（选卡 / 风险门选择 / HP 伤害 / 胜负）。
    for (final stamped in runtime.lastFrameEvents) {
      baselineRecorder?.consume(stamped.event);
    }

    // 3. 生成快照并交给表现层与 HUD。
    latestSnapshot = runtime.snapshot();
    _battlefield.snapshot = latestSnapshot;

    // 视觉路由：必须在绘制前刷新，否则本帧的事件不生效。
    visualRouter.consume(runtime.lastFrameEvents);

    // 事件驱动的纯表现特效；预算与降级都在特效池内部把关。
    effects.consume(
      runtime.lastFrameEvents,
      level: performance.level,
      positionOf: _battlefield.positionOf,
    );
    effects.step(dt);
    onSnapshot?.call(latestSnapshot);

    renderedFrames++;
    super.update(dt);
    onFrame?.call();
  }
}

/// 战场绘制组件。
class BattlefieldComponent extends Component {
  BattlefieldComponent({
    required this.runtime,
    required this.assets,
    required this.effects,
    required this.router,
  });

  final GameRuntime runtime;
  final VisualAssetCache assets;
  final VisualEffects effects;

  /// 视觉路由（协议要求：资源必须经 `eventBindings` 解析）。
  final VisualRouter router;

  /// 绘制诊断计数（F-28）：贴图成功 / 退回占位图形。
  ///
  /// 存在理由：敌机"三角形 / 五边形"这个问题，我**连续两次靠推理判断
  /// 都错了**（先是配置、后是路由）。因此改成让程序自己报数 ——
  /// 玩家玩一次，日志里就有真实数字，不必再猜。
  int enemySpriteDrawn = 0;
  int enemyFallbackDrawn = 0;
  int playerSpriteDrawn = 0;
  int playerFallbackDrawn = 0;
  int _renderFrames = 0;
  bool _drawCountersReported = false;

  /// 把实体 ID 解析成当前坐标（供特效池定位）。
  Vec2? positionOf(EntityId id) {
    if (id.kind == EntityKind.player) {
      return snapshot.player?.position;
    }
    for (final enemy in snapshot.enemies) {
      if (enemy.id == id) {
        return enemy.position;
      }
    }
    for (final projectile in snapshot.projectiles) {
      if (projectile.id == id) {
        return projectile.position;
      }
    }
    return null;
  }
  RenderSnapshot snapshot = RenderSnapshot.empty;

  /// 当前允许的视觉档位（由 PerformanceMonitor 决定）。
  ///
  /// 降级顺序：星云 → 非关键粒子 → 命中碎片 → 伤害数字。
  /// **预警、HUD、碰撞与 Boss 弱点永不降级**（产品基线 §2）。
  DegradationLevel degradation = DegradationLevel.none;

  /// 精灵绘制尺寸相对碰撞半径的放大系数。
  ///
  /// 正式素材在透明边缘留有发光/尾焰留白，直接按碰撞直径绘制会显得偏小。
  /// 这个系数只影响**观感**，碰撞判定永远使用产品基线的半径数据
  /// （素材规范 §2.1：透明边缘不得扩大真实判定）。
  static const double kSpriteScale = 2.4;

  final Paint _spritePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;

  /// 有精灵就画精灵，否则回退矢量占位。
  ///
  /// 回退是**逐资源**的：一张贴图载入失败不影响其他实体，
  /// 也完全不影响规则（架构 §7）。
  bool _drawSpriteOrNull(
    Canvas canvas,
    String? assetId,
    String? state,
    Offset center,
    double radius,
  ) {
    final image = assets.imageFor(assetId, state);
    if (image == null) {
      return false;
    }
    final anchor = assets.anchorFor(assetId, state);
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    final longest = iw > ih ? iw : ih;
    if (longest <= 0) {
      return false;
    }
    final scale = (radius * 2 * kSpriteScale) / longest;
    final w = iw * scale;
    final h = ih * scale;
    final left = center.dx - w * anchor[0];
    final top = center.dy - h * (anchor.length > 1 ? anchor[1] : 0.5);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, iw, ih),
      Rect.fromLTWH(left, top, w, h),
      _spritePaint,
    );
    return true;
  }

  final Paint _fill = Paint()..style = PaintingStyle.fill;
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3;

  /// 把绘制计数写进诊断日志（只写一次，进对局后约 2 秒）。
  void _maybeReportDrawCounters() {
    _renderFrames++;
    if (_drawCountersReported || _renderFrames < 120) {
      return;
    }
    _drawCountersReported = true;
    writeAssetDiagnostics(
      '绘制计数（约 2 秒时）：\n'
      '  玩家：贴图 $playerSpriteDrawn / 占位 $playerFallbackDrawn\n'
      '  敌机：贴图 $enemySpriteDrawn / 占位 $enemyFallbackDrawn\n'
      '  （占位 > 0 说明贴图路径没走通）',
    );
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    _maybeReportDrawCounters();
    _drawBackground(canvas);
    _drawHazards(canvas);
    _drawEnemies(canvas);
    _drawProjectiles(canvas);
    _drawPlayer(canvas);
    _drawEffects(canvas);
    _drawPickups(canvas);
  }

  /// 命中碎片与伤害数字 —— 降级顺序里最外层，最后才被牺牲。
  /// 拾取物/补给表现（F-12 裁决第 2 步）。
  ///
  /// 素材：拾取物图形本身 + **在其中央以原尺寸 42% 叠加**
  /// `UI-COLORBLIND-PATTERN-REWARD`（菱形加号）。
  ///
  /// 两者都**必须来自 manifest 的正式素材** —— 裁决明确禁止用
  /// Canvas 自绘或其他几何等价物替代。素材缺失时**不画替代图形**，
  /// 避免实现与素材合同再次分叉（加载失败由资源验收负责）。
  void _drawPickups(Canvas canvas) {
    for (final pickup in effects.pickups) {
      final center = Offset(pickup.position.x, pickup.position.y);
      const radius = 18.0;

      _drawSpriteOrNull(canvas, pickup.pickupAssetId, 'default', center, radius);

      // 中央叠加色弱叠层，尺寸 = 原尺寸 × 42%（裁决给定比例）。
      _drawColorblindPattern(
        canvas,
        ColorblindPattern.reward,
        center,
        radius * PickupFlash.rewardOverlayScale,
      );
    }
  }

  void _drawEffects(Canvas canvas) {
    if (degradation.allows(DegradationLevel.hitDebris)) {
      for (final piece in effects.debris) {
        _fill.color = Color(piece.color).withValues(
          alpha: (piece.remaining / piece.lifetime).clamp(0.0, 1.0),
        );
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset(piece.position.x, piece.position.y),
            width: 5,
            height: 5,
          ),
          _fill,
        );
      }
    }

    if (!degradation.allows(DegradationLevel.damageNumbers)) {
      return;
    }
    for (final number in effects.numbers) {
      final alpha = (number.remaining / number.lifetime).clamp(0.0, 1.0);
      final painter = TextPainter(
        text: TextSpan(
          text: '${number.amount}',
          style: TextStyle(
            color: Color(0xFFFFC24B).withValues(alpha: alpha),
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          number.position.x - painter.width / 2,
          number.position.y - painter.height,
        ),
      );
    }
  }

  void _drawBackground(Canvas canvas) {
    // 深空底色永远是第一层，**不参与降级** ——
    // 没有它画面会失去对比度，直接影响可读性（等于削弱预警）。
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, kLogicalWidth, kLogicalHeight),
      Paint()..color = const Color(0xFF05030F),
    );

    // 参考网格属于"星云"层，是最先被牺牲的表现（降级顺序第 1 档）。
    if (!degradation.allows(DegradationLevel.nebula)) {
      return;
    }
    final grid = Paint()
      ..color = const Color(0x14C64BFF)
      ..strokeWidth = 1;
    for (var x = 0.0; x <= kLogicalWidth; x += 120) {
      canvas.drawLine(Offset(x, 0), Offset(x, kLogicalHeight), grid);
    }
    for (var y = 0.0; y <= kLogicalHeight; y += 120) {
      canvas.drawLine(Offset(0, y), Offset(kLogicalWidth, y), grid);
    }
  }

  void _drawPlayer(Canvas canvas) {
    final player = snapshot.player;
    if (player == null) {
      return;
    }
    final center = Offset(player.position.x, player.position.y);

    // 护盾环（有护盾时可见）。
    final hud = snapshot.hud;
    if (hud != null && hud.shield > 0) {
      _stroke.color = const Color(0x6633E1FF);
      canvas.drawCircle(center, player.radius + 10, _stroke);
    }

    // 机体贴图**只取 `player.assetId`**（配置里的正式机体素材）。
    //
    // ⚠️ 此前写的是 `playerRoute?.assetId ?? player.assetId` —— 于是
    // **受击特效会「替换」机体**：一被打中，战舰就被换成
    // `GFX-PLAYER-SHIELD-HIT` / `GFX-PLAYER-HIT-FLASH` 那张图。
    // 那两张图同时还是占位素材（F-30），叠加起来的表现就是
    // "**被击中完全没有效果**"（玩家第 4 条反馈）。
    //
    // 正确语义：受击闪光/护盾受击是**叠层**，画在机体**之上**，
    // 而不是取代机体 —— 与敌机那边（F-28）是同一类错误。
    final drewSprite = _drawSpriteOrNull(
      canvas,
      player.assetId,
      player.visualState,
      center,
      player.radius,
    );

    // 受击表现的**叠层**（护盾受击 / 掉血闪光）。
    final playerRoute = router.playerRoute;
    if (playerRoute != null) {
      _drawSpriteOrNull(
        canvas,
        playerRoute.assetId,
        playerRoute.renderState,
        center,
        player.radius,
      );
    }
    if (drewSprite) {
      playerSpriteDrawn++;
      // 冲刺无敌时叠一层高亮，保证无敌状态**可读**（T-UI-02）。
      if (snapshot.isPlayerInvulnerable) {
        _stroke.color = const Color(0xCCFFFFFF);
        canvas.drawCircle(center, player.radius + 6, _stroke);
      }
      return;
    }
    _fill.color = snapshot.isPlayerInvulnerable
        ? const Color(0x99FFFFFF)
        : const Color(0xFF3FE0FF);
    _drawShip(canvas, center, player.radius);
  }

  /// 默认机头向上的三角机体。
  void _drawShip(Canvas canvas, Offset center, double radius) {
    final path = Path()
      ..moveTo(center.dx, center.dy - radius)
      ..lineTo(center.dx + radius * 0.8, center.dy + radius * 0.7)
      ..lineTo(center.dx, center.dy + radius * 0.35)
      ..lineTo(center.dx - radius * 0.8, center.dy + radius * 0.7)
      ..close();
    canvas.drawPath(path, _fill);
    _stroke.color = const Color(0xCCFFFFFF);
    _stroke.strokeWidth = 2;
    canvas.drawPath(path, _stroke);
    _stroke.strokeWidth = 3;
  }

  void _drawEnemies(Canvas canvas) {
    for (final enemy in snapshot.enemies) {
      final center = Offset(enemy.position.x, enemy.position.y);

      // 精英表现（F-21）：**按词缀精确路由**外环与图标。
      //
      // 此前这里对三个词缀画的是**同一个金色圆** —— 颜色在色弱场景下
      // 不可靠，而"这只精英是什么词缀"是玩法信息（加速/护体/弹幕），
      // 不能只靠颜色传达。
      if (enemy.isElite) {
        final affixVisual = eliteAffixVisualFor(enemy.affixId);
        if (affixVisual != null) {
          // 词缀特有外环：优先用正式素材，缺失时退回几何圆环，
          // 保证"词缀可区分"这一条不因素材加载失败而消失。
          // 外环素材的状态是 `default`（静态态，出生即可见）。
          final drewAura = _drawSpriteOrNull(
            canvas,
            affixVisual.auraAssetId,
            'default',
            center,
            enemy.radius + 18,
          );
          if (!drewAura) {
            _stroke.color = const Color(0x88FFC24B);
            _stroke.strokeWidth = 4;
            canvas.drawCircle(center, enemy.radius + 12, _stroke);
            _stroke.strokeWidth = 3;
          }
          // 词缀图标：画在外环上方，作为**颜色以外**的识别维度。
          // 图标素材的状态是 `normal`；画在外环上方，作为**颜色以外**
          // 的识别维度（色弱下也能分辨是哪个词缀）。
          _drawSpriteOrNull(
            canvas,
            affixVisual.iconAssetId,
            'normal',
            Offset(center.dx, center.dy - enemy.radius - 26),
            10,
          );

          // 名称条底板（`UI-ELITE-NAMEPLATE`）。
          //
          // 素材规范：512×512 @2x，**运行时缩放至 220×44 logical px**；
          // 文字由 `enemy.*` / `affix.*` 的 catalog key 绘制，
          // **禁止把文字烘焙进图**（协议 §2 第 99 行）。
          // 因此这里只贴底板；文字由 HUD 层按 key 画。
          _drawSpriteOrNull(
            canvas,
            kEliteNameplateAssetId,
            'normal',
            Offset(center.dx, center.dy - enemy.radius - 52),
            kEliteNameplateWidth / 2,
          );
        } else {
          // 未登记词缀：退回几何圆环，不猜。
          _stroke.color = const Color(0x88FFC24B);
          _stroke.strokeWidth = 4;
          canvas.drawCircle(center, enemy.radius + 12, _stroke);
          _stroke.strokeWidth = 3;
        }
      }

      // 优先使用正式素材（含 idle / critical 等语义状态）。
      // ⚠️ **机体贴图必须来自配置（`bodyAssetId`），不能用事件路由。**
      //
      // `router.routeFor(entityId)` 映射的是**事件视觉**（预警线、受击闪光
      // 等），把它当作机体贴图来源是语义错误：一旦该敌人身上刚发生过
      // 某个事件，路由就会返回那个事件的资源；该资源在当前状态下解析不出
      // 图时，`_drawSpriteOrNull` 返回 false → **退回程序化图形**。
      // 这正是玩家看到的"三角形 / 五边形"（F-28）。
      //
      // 事件路由继续用于**叠层表现**（预警、命中特效），不参与机体选择。
      final drewSprite = _drawSpriteOrNull(
        canvas,
        enemy.assetId,
        enemy.visualState,
        center,
        enemy.radius,
      );
      if (drewSprite) {
        enemySpriteDrawn++;
        _drawEnemyHealthBar(canvas, enemy, center);
        continue;
      }
      // ⚠️ **不再绘制程序化回退图形**（v2.0.6 接入说明）。
      //
      // 此前素材缺失时会退回"尖锐剪影"，玩家看到的三角形/五边形
      // 正是它 —— 让人**以为游戏长这样**，而不是**以为出了问题**。
      // 素材侧已交付 5 类敌机的独立图形，因此这里不再保留正常显示分支：
      // 取不到图就**不画**，并计入诊断（`enemyFallbackDrawn`），
      // 由资源就绪检查负责暴露问题。
      enemyFallbackDrawn++;

      _drawEnemyHealthBar(canvas, enemy, center);
    }
  }

  /// 敌人血条（表现层：受性能上限控制，不参与规则）。
  ///
  /// 它属于"非关键粒子"档位之后才被牺牲的装饰 —— 但只要还有余量就画，
  /// 因为它帮助玩家判断该打谁。
  void _drawEnemyHealthBar(Canvas canvas, EntityView enemy, Offset center) {
    if (enemy.hpRatio >= 1.0) {
      return;
    }
    if (!degradation.allows(DegradationLevel.particles)) {
      return;
    }
    final barWidth = enemy.radius * 1.6;
    final top = center.dy - enemy.radius - 14;
    canvas.drawRect(
      Rect.fromLTWH(center.dx - barWidth / 2, top, barWidth, 4),
      Paint()..color = const Color(0x55000000),
    );
    canvas.drawRect(
      Rect.fromLTWH(center.dx - barWidth / 2, top, barWidth * enemy.hpRatio, 4),
      Paint()..color = const Color(0xFFFF5C8A),
    );
  }

  void _drawProjectiles(Canvas canvas) {
    for (final projectile in snapshot.projectiles) {
      final center = Offset(projectile.position.x, projectile.position.y);
      if (_drawSpriteOrNull(
        canvas,
        projectile.assetId,
        null,
        center,
        projectile.radius,
      )) {
        continue;
      }
      _fill.color = projectile.isPlayerProjectile
          ? const Color(0xFF7CF9FF) // 我方：青白
          : const Color(0xFFFF4BD8); // 敌方：洋红
      canvas.drawCircle(center, projectile.radius, _fill);
    }
  }


  void _drawHazards(Canvas canvas) {
    for (final hazard in snapshot.hazards) {
      final center = Offset(hazard.position.x, hazard.position.y);
      if (hazard.isWarning) {
        _stroke.color = const Color(0x99FFB03A);
        canvas.drawCircle(center, hazard.radius, _stroke);
      } else {
        _fill.color = const Color(0x33FF4BD8);
        canvas.drawCircle(center, hazard.radius, _fill);
      }

      // F-12：**颜色之外的第二识别维度**。
      //
      // 裁决明确：「**必须实际合成正式 PNG 素材，禁止用 Canvas 或
      // 程序化几何等价替代**」。因此这里贴的是
      // `UI-COLORBLIND-PATTERN-DANGER` 本身，而不是我先前画的几何斜线。
      //
      // **始终绘制，不受任何设置门控**（没有"色弱开关"这回事）。
      if (hazardNeedsDangerPattern(
        isWarning: hazard.isWarning,
        dealsDamage: !hazard.isWarning,
      )) {
        _drawColorblindPattern(
          canvas,
          ColorblindPattern.danger,
          center,
          hazard.radius,
        );
      }
    }
  }

  /// 合成色弱叠层素材（F-12 裁决：**必须用正式 PNG，不得几何替代**）。
  ///
  /// 素材状态取 `normal`（三套叠层都有 normal/pressed/disabled/focus
  /// 四个状态，正常显示用 `normal`）。
  ///
  /// 返回是否真的贴上了图 —— **贴不上不能静默**：
  /// 发布构建里色弱叠层缺失属于资源验收失败，因此这里回传结果供
  /// 上层/测试核对，而不是悄悄画个圆了事。
  bool _drawColorblindPattern(
    Canvas canvas,
    ColorblindPattern pattern,
    Offset center,
    double radius,
  ) {
    return _drawSpriteOrNull(
      canvas,
      pattern.assetId,
      'normal',
      center,
      radius,
    );
  }
}

/// 供 HUD 判断是否需要在屏幕空间做 letterbox 补偿（T-UI-01）。
///
/// 固定分辨率视口下，逻辑世界按比例缩放并居中，多出来的区域是黑边；
/// 黑边**不得吞掉输入**，因此输入映射必须用同一套比例。
class ViewportMath {
  const ViewportMath({required this.viewportSize});

  final Size viewportSize;

  double get scale => math.min(
    viewportSize.width / kLogicalWidth,
    viewportSize.height / kLogicalHeight,
  );

  Size get letterboxedSize =>
      Size(kLogicalWidth * scale, kLogicalHeight * scale);

  Offset get origin => Offset(
    (viewportSize.width - letterboxedSize.width) / 2,
    (viewportSize.height - letterboxedSize.height) / 2,
  );

  /// 屏幕坐标 → 逻辑坐标。落在黑边上时仍返回夹紧后的逻辑坐标，
  /// 从而"letterbox 不吞输入"。
  Offset toLogical(Offset screen) {
    if (scale <= 0) {
      return Offset.zero;
    }
    final local = (screen - origin) / scale;
    return Offset(
      local.dx.clamp(0.0, kLogicalWidth),
      local.dy.clamp(0.0, kLogicalHeight),
    );
  }
}
