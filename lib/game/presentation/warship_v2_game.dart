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

import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart' hide Image;

import '../content/asset_manifest.dart';
import '../core/game_runtime.dart';
import '../domain/values.dart';
import '../core/render_snapshot.dart';
import '../infrastructure/performance_monitor.dart';
import 'asset_cache.dart';
import 'visual_effects.dart';
import 'input_gateway.dart';

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

  /// 帧时间采样与降级决策。
  final PerformanceMonitor performance;

  /// 事件驱动的纯表现特效（碎片、伤害数字）。
  final VisualEffects effects = VisualEffects();

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
    // 预载 firstRun 分组（协议 §7）。单张失败不阻断，走矢量占位。
    await visualAssets.loadGroup(AssetLoadGroup.firstRun);

    _battlefield = BattlefieldComponent(
      runtime: runtime,
      assets: visualAssets,
      effects: effects,
    )..degradation = performance.level;
    world.add(_battlefield);
  }

  @override
  void update(double dt) {
    // 0. 帧时间采样 → 降级决策（产品基线 §2 的 95%/99% 预算）。
    performance.recordFrame(dt);
    _battlefield.degradation = performance.level;

    // 1. 取本帧输入（锁定后交给运行时）。
    final frame = input.consume();

    // 2. 推进逻辑。非 Playing 状态内部会自动冻结。
    runtime.advance(dt, frame);

    // 3. 生成快照并交给表现层与 HUD。
    latestSnapshot = runtime.snapshot();
    _battlefield.snapshot = latestSnapshot;

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
  });

  final GameRuntime runtime;
  final VisualAssetCache assets;
  final VisualEffects effects;

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

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    _drawBackground(canvas);
    _drawHazards(canvas);
    _drawEnemies(canvas);
    _drawProjectiles(canvas);
    _drawPlayer(canvas);
    _drawEffects(canvas);
  }

  /// 命中碎片与伤害数字 —— 降级顺序里最外层，最后才被牺牲。
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

    // 优先使用正式素材；缺失时回退矢量机体（青蓝、对称轮廓）。
    final drewSprite = _drawSpriteOrNull(
      canvas,
      player.assetId,
      player.visualState,
      center,
      player.radius,
    );
    if (drewSprite) {
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

      // 精英光环（素材规范的"精英词缀可读性"要求）。
      if (enemy.isElite) {
        _stroke.color = const Color(0x88FFC24B);
        _stroke.strokeWidth = 4;
        canvas.drawCircle(center, enemy.radius + 12, _stroke);
        _stroke.strokeWidth = 3;
      }

      // 优先使用正式素材（含 idle / critical 等语义状态）。
      final drewSprite = _drawSpriteOrNull(
        canvas,
        enemy.assetId,
        enemy.visualState,
        center,
        enemy.radius,
      );
      if (drewSprite) {
        _drawEnemyHealthBar(canvas, enemy, center);
        continue;
      }

      // 回退：深紫/洋红、尖锐剪影（与玩家的青蓝明确区分）。
      _fill.color = enemy.hpRatio <= 0.25
          ? const Color(0xFFFF5C8A) // 临界
          : const Color(0xFF9B4BFF);

      final path = Path()
        ..moveTo(center.dx, center.dy + enemy.radius)
        ..lineTo(center.dx + enemy.radius * 0.85, center.dy - enemy.radius * 0.6)
        ..lineTo(center.dx, center.dy - enemy.radius * 0.2)
        ..lineTo(center.dx - enemy.radius * 0.85, center.dy - enemy.radius * 0.6)
        ..close();
      canvas.drawPath(path, _fill);

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
    }
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
