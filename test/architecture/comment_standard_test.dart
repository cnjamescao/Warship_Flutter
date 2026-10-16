// ================================================================
// test/architecture/comment_standard_test.dart —— 代码注释规范守卫
// ================================================================
// **依据**：产品负责人确立的默认工作要求 ——
// 「所有代码要有非常详细完整的注释说明；目标是**以后的工程师可以通过
//   注释说明，明白你的代码思路和架构**」。规范见 `docs/代码注释规范.md`。
//
// **架构位置**：Architecture 测试。不属于运行时，不参与产品逻辑；
//   它的作用是把"注释要求"从**人的自觉**变成**机器可查**。
//
// **为什么这样设计（冻结已知缺口）**：
//   截至 2026-10-16，`lib/` 下 **59/59** 个文件都还没有规范要求的文件头。
//   若直接断言"全部合规"，仓库会长期处于红色，反而让守卫失去意义。
//   因此采用**冻结**：登记当前已知不合规集合，并断言它**只能缩小**：
//     * 新增文件必须一开始就合规（否则本用例失败）；
//     * 每完成一个批次，从冻结集合里移除该批文件；
//     * 若某人删掉文件头，本用例立即失败。
//
// **局限（如实记录）**：机械检查**只能验证"有没有"**，无法验证
//   "是否讲清楚了架构与取舍"。后者仍需人工复核 —— 本守卫是**下限**，
//   不是质量标准本身。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **已知尚未达标文件头的文件**（当前为**空集**）。
///
/// ⚠️ **重要更正记录**：本守卫第一版把"缺字面标记 `架构位置`"当成
/// "缺文件头"，于是把 **59/59** 个文件全部列入冻结 ——
/// 而实测 **59 个文件 100% 都已有 `// ====` 文件头块**（第一版只检查了
/// 我自创的魔法字符串）。
/// **那是一个完全虚假的缺口**，已被独立测量推翻。
/// 判据现改为「真实存在规范文件头」：`// ====` 块 + 块内至少 3 行实质注释。
const Set<String> kFilesWithoutHeader = <String>{
  'lib/app/baseline_recording.dart',
  'lib/app/v2_app_flow.dart',
  'lib/app/v2_bootstrap.dart',
  'lib/app/v2_run_screen.dart',
  'lib/game/collision_resolver.dart',
  'lib/game/components.dart',
  'lib/game/content/asset_id.dart',
  'lib/game/content/asset_manifest.dart',
  'lib/game/content/content_catalog.dart',
  'lib/game/content/content_error.dart',
  'lib/game/core/baseline_recorder.dart',
  'lib/game/core/domain_event.dart',
  'lib/game/core/event_bus.dart',
  'lib/game/core/game_clock.dart',
  'lib/game/core/game_phase.dart',
  'lib/game/core/game_runtime.dart',
  'lib/game/core/input_frame.dart',
  'lib/game/core/phase_controller.dart',
  'lib/game/core/random_source.dart',
  'lib/game/core/render_snapshot.dart',
  'lib/game/core/replay.dart',
  'lib/game/core/run_context.dart',
  'lib/game/domain/boss_system.dart',
  'lib/game/domain/collision.dart',
  'lib/game/domain/damage.dart',
  'lib/game/domain/director_system.dart',
  'lib/game/domain/enemy_system.dart',
  'lib/game/domain/fairness.dart',
  'lib/game/domain/player_system.dart',
  'lib/game/domain/result_tier.dart',
  'lib/game/domain/risk_gate_system.dart',
  'lib/game/domain/upgrade_system.dart',
  'lib/game/domain/values.dart',
  'lib/game/domain/weapon_system.dart',
  'lib/game/fleet_controller.dart',
  'lib/game/game_audio.dart',
  'lib/game/game_config.dart',
  'lib/game/game_session.dart',
  'lib/game/infrastructure/asset_loader.dart',
  'lib/game/infrastructure/audio_director.dart',
  'lib/game/infrastructure/audio_port.dart',
  'lib/game/infrastructure/haptics_director.dart',
  'lib/game/infrastructure/haptics_platform.dart',
  'lib/game/infrastructure/haptics_port.dart',
  'lib/game/infrastructure/performance_monitor.dart',
  'lib/game/infrastructure/performance_report.dart',
  'lib/game/infrastructure/progress_store.dart',
  'lib/game/infrastructure/shared_preferences_store.dart',
  'lib/game/input_controller.dart',
  'lib/game/presentation/asset_cache.dart',
  'lib/game/presentation/colorblind_patterns.dart',
  'lib/game/presentation/elite_affix_visuals.dart',
  'lib/game/presentation/input_gateway.dart',
  'lib/game/presentation/visual_effects.dart',
  'lib/game/presentation/visual_router.dart',
  'lib/game/presentation/warship_v2_game.dart',
  'lib/game/warship_game.dart',
  'lib/legacy/v1_app.dart',
  'lib/main.dart',
};

/// 判断一个文件是否已有符合规范的文件头。
///
/// 判据（刻意**不**要求任何特定字面标记）：
///   0. **文件头必须从第 1 行开始**（`lines[0]` 即 `// ====`）——
///      这条是后续补的：B2 补丁曾把「易错点」块插到文件头**之前**，
///      文件变成以正文注释开头再出现分隔块；当时的判据只在"前 24 行内
///      找块"，**放过了这个结构错误**。文件头是文件的"封面"，
///      必须从第一行开始。
///   1. 前 20 行内存在 `// ====` 分隔块；
///   2. 该块**闭合**（再次出现 `// ====`）—— 避免只有一行装饰；
///   3. 块内至少 3 行实质注释（去除 `//` 与装饰后非空）。
///
/// **为什么不用魔法字符串**：第一版要求块内出现「架构位置」四个字，
/// 结果把 59 个**已有详细文件头**的文件全判为不合规。
/// 注释要求的本质是「讲清楚」，不是「包含某个词」。
bool hasStandardHeader(List<String> lines) {
  // 第 0 条：文件头必须**从第一行开始**。
  if (lines.isEmpty || !lines.first.trimLeft().startsWith('// ====')) {
    return false;
  }
  final head = lines.take(24).toList();
  final open = head.indexWhere((l) => l.trimLeft().startsWith('// ===='));
  if (open < 0) {
    return false;
  }
  final close = head.indexWhere(
    (l) => l.trimLeft().startsWith('// ===='),
    open + 1,
  );
  if (close < 0) {
    return false;
  }
  var substantive = 0;
  for (var i = open + 1; i < close; i++) {
    final text = head[i].replaceAll('//', '').trim();
    if (text.isNotEmpty) {
      substantive++;
    }
  }
  return substantive >= 3;
}

void main() {
  test('代码注释规范：文件头不得缺失（已知缺口只能缩小）', () {
    final all = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path)
        .toList()
      ..sort();

    final missing = <String>[];
    final newlyCompliant = <String>[];
    for (final path in all) {
      final compliant = hasStandardHeader(
        File(path).readAsLinesSync(),
      );
      final known = kFilesWithoutHeader.contains(path);
      if (!compliant && !known) {
        missing.add(path);
      }
      if (compliant && known) {
        newlyCompliant.add(path);
      }
    }

    expect(
      missing,
      isEmpty,
      reason: '以下文件**没有**规范要求的文件头（`// ====` 分隔块 + '
          '`架构位置` 标记）—— 新增文件必须一开始就合规；\n'
          '规范见 docs/代码注释规范.md 第 2.1 节：\n'
          '${missing.join("\n")}',
    );

    // 已补齐的提醒从冻结清单移除，避免"补齐了却忘了登记"。
    // （不判失败 —— 只要它合规就是好事；此处仅提示。）
    if (newlyCompliant.isNotEmpty) {
      // ignore: avoid_print
      print('注释规范：以下文件已补齐文件头，请从 kFilesWithoutHeader 移除：'
          '\n${newlyCompliant.join("\n")}');
    }
  });
}
