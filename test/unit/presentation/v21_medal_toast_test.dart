// ================================================================
// test/unit/presentation/v21_medal_toast_test.dart —— V21-MEDAL-02
// ================================================================
// **架构位置**：Presentation 层测试。验证 v2.1 三档奖章的**入场时间轴**
//   （冻结表 §5.2）与 **Toast 几何**（冻结表 §2.3）。
//
// **为什么必须逐毫秒断言**：时间轴错位（例如 180ms 处的 scale 不是 1.12）
//   截图看不出来，但玩家能感觉到"弹得不对"。数值断言才是可复核的证据。
//
// 每条断言都能失败（R6.2）：改错任一端点、时长或缩放，本文件即失败。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/v21_result_medal.dart';

void main() {
  group('V21-MEDAL-02 三档奖章时间轴', () {
    test('Gold：0.60→1.12（含 -10°→0°），再 1.12→1.00 + 星芒 0→1', () {
      final g = kV21MedalTimelines['gold']!;
      expect(g.assetId, 'UI-V21-RESULT-MEDAL-GOLD');
      expect(g.cueId, 'SFX-V21-MEDAL-GOLD');
      expect(g.totalMs, 500);

      // 起点：scale 0.60、旋转 -10°。
      final t0 = g.at(0);
      expect(t0.scale, closeTo(0.60, 1e-9));
      expect(t0.rotationDegrees, closeTo(-10, 1e-9));

      // 180ms：scale 1.12、旋转归 0。
      final t180 = g.at(180);
      expect(t180.scale, closeTo(1.12, 1e-9));
      expect(t180.rotationDegrees, closeTo(0, 1e-9));

      // 中点线性插值（90ms → 0.86）。
      expect(g.at(90).scale, closeTo(0.86, 1e-9));

      // 500ms：scale 1.00、星芒 1。
      final t500 = g.at(500);
      expect(t500.scale, closeTo(1.00, 1e-9));
      expect(t500.starOpacity, closeTo(1.0, 1e-9));
      // 星芒在 180ms 时应为 0（刚开始出现）。
      expect(g.at(180).starOpacity, closeTo(0.0, 1e-9));
      // 超过总时长停在最终帧。
      expect(g.at(9999).scale, closeTo(1.00, 1e-9));
    });

    test('Silver：xScale 0.15→1.05，再 1.05→1.00 + opacity 0.75→1', () {
      final s = kV21MedalTimelines['silver']!;
      expect(s.assetId, 'UI-V21-RESULT-MEDAL-SILVER');
      expect(s.cueId, 'SFX-V21-MEDAL-SILVER');
      expect(s.totalMs, 420);

      expect(s.at(0).scale, closeTo(0.15, 1e-9));
      final t160 = s.at(160);
      expect(t160.scale, closeTo(1.05, 1e-9));
      expect(t160.opacity, closeTo(0.75, 1e-9), reason: '第二段起点透明度');
      final t420 = s.at(420);
      expect(t420.scale, closeTo(1.00, 1e-9));
      expect(t420.opacity, closeTo(1.0, 1e-9));
    });

    test('Bronze：y +32→0 且 scale 0.75→1.05，再 1.05→1.00', () {
      final b = kV21MedalTimelines['bronze']!;
      expect(b.assetId, 'UI-V21-RESULT-MEDAL-BRONZE');
      expect(b.cueId, 'SFX-V21-MEDAL-BRONZE');
      expect(b.totalMs, 380);

      final t0 = b.at(0);
      expect(t0.offsetY, closeTo(32, 1e-9), reason: '从 +32 落下');
      expect(t0.scale, closeTo(0.75, 1e-9));

      final t180 = b.at(180);
      expect(t180.offsetY, closeTo(0, 1e-9));
      expect(t180.scale, closeTo(1.05, 1e-9));

      expect(b.at(380).scale, closeTo(1.00, 1e-9));
    });

    test('三档都必须**普通 alpha 合成**（不得 additive 覆盖结果文字）', () {
      // 冻结表 §5.2 明文：「三者普通 alpha 合成，不可用 additive 覆盖结果文字」。
      for (final t in kV21MedalTimelines.values) {
        expect(t.usesAdditive, isFalse, reason: '${t.tier} 不得用 additive');
      }
      expect(kV21MedalSize, 192);
    });

    test('三档的 Asset / cue 互不相同（不得串档）', () {
      final assets = kV21MedalTimelines.values.map((t) => t.assetId).toSet();
      final cues = kV21MedalTimelines.values.map((t) => t.cueId).toSet();
      expect(assets, hasLength(3));
      expect(cues, hasLength(3));
    });
  });

  group('V21-HUD-03 Toast 几何（冻结表 §2.3）', () {
    test('设计基准 1920×1080 下与冻结值完全一致', () {
      final r = toastRectFor(1920, 1080);
      expect(r.left, closeTo(1540, 1e-9));
      expect(r.top, closeTo(104, 1e-9));
      expect(r.width, closeTo(332, 1e-9));
      expect(r.height, closeTo(76, 1e-9));
    });

    test('窄视口等比缩放，且距右/上边**至少 24**', () {
      for (final w in <double>[800, 1000, 1280, 1600]) {
        final r = toastRectFor(w, 800);
        expect(r.right, lessThanOrEqualTo(w - 24 + 1e-9),
            reason: '宽 $w：右边距必须 ≥ 24');
        expect(r.top, greaterThanOrEqualTo(24 - 1e-9),
            reason: '宽 $w：上边距必须 ≥ 24');
        // 等比：宽高比保持 332:76。
        expect(r.width / r.height, closeTo(332 / 76, 1e-6));
      }
    });

    test('视口越窄，Toast 只缩小不放大', () {
      final wide = toastRectFor(1920, 1080);
      final narrow = toastRectFor(640, 480);
      expect(narrow.width, lessThanOrEqualTo(wide.width));
      expect(narrow.width, greaterThan(0));
    });
  });
}
