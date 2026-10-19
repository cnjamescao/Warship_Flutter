// ================================================================
// lib/game/presentation/v21_result_emblem.dart —— 结果徽记组件（无文字，图形 + Semantics）
//
// **架构位置**：Presentation 层。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**：
//   * **视觉层无文字** —— 本组件内部**不得出现任何 `Text`**；
//     完整说明只走 `Semantics(label:)`；
//   * 图形按 `frameRect` 从 sheet 裁切（`V21SheetCell`），
//     **不得**直出整张 sheet；
//   * 尺寸/位置由 `emblemRectFor()` 决定，缩放与不透明度由
//     `V21EmblemTiming` 决定 —— 本组件不自己算时序。
//
// **依据**：`Spec/01_产品/v2.1/Warship_v2.1功能冻结表.md` §2.3。
// ================================================================

import 'package:flutter/material.dart';

import '../content/content_catalog.dart';
import 'v21_result_notice.dart';
import 'v21_sheet_cell.dart';

/// **v2.1-R2 结果徽记**（冻结表 §2.3）。
///
/// 视觉层**无文字**：这里**不出现任何 `Text`**，只有一枚真实素材图形。
/// 强制结果、风险结果、超载奖励都共用它，只是 `kind` 不同。
class V21ResultEmblem extends StatelessWidget {
  const V21ResultEmblem({
    super.key,
    required this.kind,
    required this.args,
    required this.elapsedMs,
    required this.catalog,
  });

  final V21ResultKind kind;

  /// 语义模板参数（值为 **catalog key**，本组件负责逐级解析）。
  final Map<String, Object?> args;

  /// 已播放毫秒数（0…1000）。
  final int elapsedMs;

  final ContentCatalog catalog;

  @override
  Widget build(BuildContext context) {
    // **两级解析**：`args` 里是 catalog key，必须先解析成中文，
    // 再套进语义模板 —— 否则读屏会念出 `up.pulseRate.name` 原文 ✗。
    final resolved = <String, Object?>{
      if (args.containsKey('name')) 'name': catalog.text('${args['name']}'),
      if (args.containsKey('level')) 'level': args['level'],
      if (args.containsKey('description'))
        'description': catalog.text('${args['description']}'),
      if (args.containsKey('effect')) 'effect': catalog.text('${args['effect']}'),
    };
    final label = catalog.text(kind.ariaKey, resolved);

    final record = catalog.manifest.lookup(kind.assetId);
    final spec = record?.renderStates['default'];
    final files = spec != null && spec.runtimeFiles.isNotEmpty
        ? spec.runtimeFiles
        : (record?.runtimeFiles ?? const <String>[]);
    final rect = (spec?.frameRects.isNotEmpty ?? false)
        ? spec!.frameRects.first
        : null;

    final scale = V21EmblemTiming.scaleAt(elapsedMs);
    final opacity = V21EmblemTiming.opacityAt(elapsedMs);

    final graphic = files.isEmpty
        ? const SizedBox.shrink()
        : V21SheetCell(
            imagePath: files.first,
            frameRect: rect,
            size: 132,
          );

    return Semantics(
      // 完整说明**只在这里**（视觉层无文字）。
      label: label,
      container: true,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: scale,
          // 按源图纵横比 contain 进目标区域（不拉伸）。
          child: Center(
            child: AspectRatio(aspectRatio: 132 / 176, child: graphic),
          ),
        ),
      ),
    );
  }
}

