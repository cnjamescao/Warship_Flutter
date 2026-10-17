// ================================================================
// lib/game/presentation/v21_sheet_cell.dart —— 从 sheet 裁切单格（v2.1 素材）
//
// **架构位置**：Presentation 层。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**：
//   * 只用 `frameRect` 裁切，**不得**从文件名或格子等分推断帧；
//   * **不得**直接 `Image.asset` 出整张 sheet —— 那会画出相邻几格；
//   * 本组件**只负责显示**，不解析 manifest（调用方传 rect）。
// ================================================================

import 'package:flutter/material.dart';

/// 从一张 **sheet** 里裁出 [frameRect] 指定的那一格并缩放到 [size]。
///
/// **为什么必须裁切**：v2.1 的素材是 `2172×724` 的 sheet，
/// 一格只有 `724×724` 之类 —— 直接 `Image.asset` 会画出**整张多格** ✗。
/// 这与 v2.0 犯过的"用画布高度当带宽导致 7 倍拉伸"是**同一类错误**
/// （用整张图的尺寸代替内容的尺寸）。
///
/// 实现用 `ClipRect + Align(widthFactor/heightFactor)`：
/// 不需要异步加载 `ui.Image`，也不引入额外依赖。
class V21SheetCell extends StatelessWidget {
  const V21SheetCell({
    super.key,
    required this.imagePath,
    required this.frameRect,
    required this.size,
    this.sheetWidth = 2172,
    this.sheetHeight = 724,
    this.filterQuality = FilterQuality.medium,
  });

  final String imagePath;

  /// `[x, y, w, h]`；null 表示"整张图即一帧"（v2.0 素材）。
  final List<int>? frameRect;

  /// 目标显示尺寸（正方形）。
  final double size;

  /// 整张 sheet 的像素尺寸（v2.1 素材规范 §2：全部为 2172×724）。
  final double sheetWidth;
  final double sheetHeight;

  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    final rect = frameRect;
    if (rect == null) {
      return Image.asset(
        imagePath,
        width: size,
        height: size,
        filterQuality: filterQuality,
        errorBuilder: (_, _, _) => SizedBox(width: size, height: size),
      );
    }
    final x = rect[0].toDouble();
    final y = rect[1].toDouble();
    final w = rect[2].toDouble();
    final h = rect[3].toDouble();
    if (w <= 0 || h <= 0) {
      return SizedBox(width: size, height: size);
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipRect(
        child: Align(
          alignment: Alignment(
            w >= sheetWidth ? 0 : (x / (sheetWidth - w)) * 2 - 1,
            h >= sheetHeight ? 0 : (y / (sheetHeight - h)) * 2 - 1,
          ),
          widthFactor: w / sheetWidth,
          heightFactor: h / sheetHeight,
          child: Image.asset(
            imagePath,
            width: size * (sheetWidth / w),
            height: size * (sheetHeight / h),
            filterQuality: filterQuality,
            errorBuilder: (_, _, _) => SizedBox(width: size, height: size),
          ),
        ),
      ),
    );
  }
}

