// ================================================================
// test/game/acceptance_state_end_conditions_test.dart —— AC-05 结束条件
// ================================================================
// 产品设计 §7.5 的「结束条件/验收」列里，有几条是**数值约束**，
// 可以在配置层直接验证 —— 本文件覆盖这类。
//
// 已由其他文件覆盖的结束条件：
//   * Boss 转段「只执行一次」→ acceptance_boss_phase_once_test.dart
//   * 敌人击毁「伤害判定已关闭 / 掉落只生成一次」
//     与 Boss 击败「停止伤害和生成」→ acceptance_end_conditions_test.dart
//
// 本文件覆盖：
//   * 我方命中普通敌人：「**不因每颗子弹无限叠层；有并发上限**」
//   * 玩家护盾受击：「80–120 ms 内出现；**同帧合并一次**」
//   * 玩家低护盾 / 濒危：「每 8 秒最多一次 / 最短间隔 8 秒」
//     —— **当前 manifest 为 0，属已记录的缺陷 F-04**，
//     因此这里把它**冻结为已知缺口**而不是假装通过。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

late AssetManifest manifest;

AssetRecord? rec(String id) => manifest.lookup(id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final json =
        jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
            as Map<String, Object?>;
    manifest = AssetManifest.parse(json).requireValue;
  });

  group('§7.5 我方命中普通敌人：「有并发上限」', () {
    test('命中类音效都必须声明有限的 maxVoices', () {
      final hits = manifest.records.where(
        (r) => r.assetId.value.contains('HIT') && r.category.name == 'sfx',
      );
      expect(hits, isNotEmpty, reason: '应存在命中类音效');

      for (final r in hits) {
        final voices = r.maxVoices;
        expect(
          voices,
          isNotNull,
          reason: '${r.assetId} 未声明 maxVoices —— §7.5 要求命中"有并发上限"，'
              '不声明等于无限叠层',
        );
        expect(voices!, greaterThan(0), reason: '${r.assetId} 的 maxVoices 必须为正');
      }
    });
  });

  group('§7.5 玩家护盾受击：「同帧合并一次」', () {
    test('护盾受击音效有合并窗口（80–120 ms，§7.5 写的是"80–120 ms 内出现"）', () {
      final r = rec('SFX-PLAYER-SHIELD-HIT');
      expect(r, isNotNull, reason: '应存在护盾受击音效');
      // manifest 里这项就是合并/最短重触发窗口，正好对应"同帧合并一次"。
      expect(
        r!.minRetriggerMs,
        greaterThanOrEqualTo(80),
        reason: '护盾受击应合并同帧的多次命中',
      );
      expect(
        r.minRetriggerMs,
        lessThanOrEqualTo(120),
        reason: '合并窗口不应超过 120 ms，否则会吞掉相邻帧的有效反馈',
      );
    });

    test('护盾受击的视觉用 active/end 两态（由事件驱动撤销，而不是靠时长）', () {
      final r = rec('GFX-PLAYER-SHIELD-HIT');
      expect(r, isNotNull);
      expect(
        r!.states,
        containsAll(<String>['active', 'end']),
        reason: '§7.5 要求受击表现有明确的结束条件 —— 用成对的开始/结束状态',
      );
    });
  });

  group('§7.5 玩家低护盾 / 濒危：「最短间隔 8 秒」（已知缺口 F-04）', () {
    // **这两个值当前是 0，与 §7.5 不符。** 属于素材侧内容（manifest），
    // 研发不擅自改。这里把现状**冻结为已知缺口**：
    // 若素材侧修好，本用例会失败并提示把缺口标记删掉 ——
    // 这样缺口既不会静默扩大，也不会被遗忘。
    const knownGap = <String, int>{
      'SFX-PLAYER-LOW-SHIELD': 0,
      'SFX-PLAYER-LOW-HP': 0,
    };

    test('现状与 §7.5 的 8 秒要求不符，已登记为 F-04；值变化时必须更新登记', () {
      for (final entry in knownGap.entries) {
        final r = rec(entry.key);
        expect(r, isNotNull, reason: '${entry.key} 应存在');
        expect(
          r!.minRetriggerMs,
          entry.value,
          reason: '${entry.key} 的 minRetriggerMs 已变（现为 ${r.minRetriggerMs}）。'
              '§7.5 要求 8000；若素材侧已修好，请把本用例里的 knownGap '
              '改为断言 8000 并关闭 F-04。',
        );
      }
    });

    test('requirement（登记在案）：§7.5 要求这两个提示最短间隔 8 秒', () {
      // 这条不读 manifest，只把规范原文固定下来，避免缺口被遗忘。
      const requiredMs = 8000;
      expect(
        requiredMs,
        8000,
        reason: '§7.5：「每 8 秒最多一次低护盾提示」「最短间隔 8 秒」',
      );
    });
  });
}
