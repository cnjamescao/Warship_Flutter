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

import '../core/game_runtime.dart';
import '../core/render_snapshot.dart';
import 'input_gateway.dart';

/// v2.0 逻辑世界尺寸（产品基线 §2）。
const double kLogicalWidth = 1920;
const double kLogicalHeight = 1080;

/// 主 Flame 游戏。
class WarshipV2Game extends FlameGame {
  WarshipV2Game({
    required this.runtime,
    required this.input,
    this.onSnapshot,
  });

  final GameRuntime runtime;
  final KeyboardInputGateway input;

  /// 每帧回调（HUD 用它刷新，避免 Widget 直接读 Flame 组件）。
  final void Function(RenderSnapshot snapshot)? onSnapshot;

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
    _battlefield = BattlefieldComponent(runtime: runtime);
    world.add(_battlefield);
  }

  @override
  void update(double dt) {
    // 1. 取本帧输入（锁定后交给运行时）。
    final frame = input.consume();

    // 2. 推进逻辑。非 Playing 状态内部会自动冻结。
    runtime.advance(dt, frame);

    // 3. 生成快照并交给表现层与 HUD。
    latestSnapshot = runtime.snapshot();
    _battlefield.snapshot = latestSnapshot;
    onSnapshot?.call(latestSnapshot);

    renderedFrames++;
    super.update(dt);
  }
}

/// 战场绘制组件。
class BattlefieldComponent extends Component {
  BattlefieldComponent({required this.runtime});

  final GameRuntime runtime;
  RenderSnapshot snapshot = RenderSnapshot.empty;

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
  }

  void _drawBackground(Canvas canvas) {
    // 深空底色 + 参考网格（纯表现，不参与碰撞）。
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, kLogicalWidth, kLogicalHeight),
      Paint()..color = const Color(0xFF05030F),
    );
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

    // 机体：青蓝、对称轮廓（素材规范的"玩家/可控"视觉语言）。
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

      // 普通敌人：深紫/洋红、尖锐剪影（与玩家的青蓝明确区分）。
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

      // 血条（表现层：受性能上限控制，不参与规则）。
      if (enemy.hpRatio < 1.0) {
        final barWidth = enemy.radius * 1.6;
        canvas.drawRect(
          Rect.fromLTWH(
            center.dx - barWidth / 2,
            center.dy - enemy.radius - 14,
            barWidth,
            4,
          ),
          Paint()..color = const Color(0x55000000),
        );
        canvas.drawRect(
          Rect.fromLTWH(
            center.dx - barWidth / 2,
            center.dy - enemy.radius - 14,
            barWidth * enemy.hpRatio,
            4,
          ),
          Paint()..color = const Color(0xFFFF5C8A),
        );
      }
    }
  }

  void _drawProjectiles(Canvas canvas) {
    for (final projectile in snapshot.projectiles) {
      final center = Offset(projectile.position.x, projectile.position.y);
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
