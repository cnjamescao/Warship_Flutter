// ================================================================
// test/unit/presentation/v21_result_notice_test.dart —— V21-HUD-02
// ================================================================
// **架构位置**：Presentation 层测试。验证 v2.1-R2 的**结果徽记队列**
//   （冻结表 §2.3）。
//
// **批复原文要点**：
//   「并发事件按产生顺序进入**单一结果队列**，前项结束后才显示后项；
//     队列**不暂停战斗、不丢事件**。视觉层无文字。」
//   「时序固定为 90ms 弹出、580ms 停留、330ms 收束，总 1000ms。」
//   「固定目标区域 left=1728, top=28, width=132, height=176。」
//
// 每条断言都能失败（R6.2）：改错任一段时长、允许并发显示、或丢掉入队事件，
// 本文件即失败。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/presentation/v21_result_notice.dart';

V21ResultNotice notice(int ordinal, [V21ResultKind kind = V21ResultKind.upgrade]) =>
    V21ResultNotice(kind: kind, args: const <String, Object?>{}, ordinal: ordinal);

void main() {
  group('V21-HUD-02 时序', () {
    test('90 / 580 / 330，总计 1000ms', () {
      expect(V21EmblemTiming.popInMs, 90);
      expect(V21EmblemTiming.holdMs, 580);
      expect(V21EmblemTiming.outroMs, 330);
      expect(V21EmblemTiming.totalMs, 1000);
      expect(
        V21EmblemTiming.popInMs + V21EmblemTiming.holdMs + V21EmblemTiming.outroMs,
        V21EmblemTiming.totalMs,
      );
    });

    test('缩放：弹出 0.72→1.00，停留 1.00，收束降至 0.86', () {
      expect(V21EmblemTiming.scaleAt(0), closeTo(0.72, 1e-9));
      expect(V21EmblemTiming.scaleAt(45), closeTo(0.86, 1e-9));
      expect(V21EmblemTiming.scaleAt(90), closeTo(1.00, 1e-9));
      expect(V21EmblemTiming.scaleAt(300), closeTo(1.00, 1e-9), reason: '停留段');
      // 收束段 = 90+580=670ms 起，到 670+330=1000ms 止。
      expect(V21EmblemTiming.scaleAt(670), closeTo(1.00, 1e-9), reason: '收束起点');
      expect(V21EmblemTiming.scaleAt(835), closeTo(0.93, 1e-9), reason: '收束中点');
      expect(V21EmblemTiming.scaleAt(1000), closeTo(0.86, 1e-9), reason: '收束终点');
    });

    test('不透明度：弹出渐显、停留全显、收束淡出', () {
      expect(V21EmblemTiming.opacityAt(0), 0.0);
      expect(V21EmblemTiming.opacityAt(45), closeTo(0.5, 1e-9));
      expect(V21EmblemTiming.opacityAt(90), closeTo(1.0, 1e-9));
      expect(V21EmblemTiming.opacityAt(500), closeTo(1.0, 1e-9));
      expect(V21EmblemTiming.opacityAt(1000), 0.0);
    });
  });

  group('V21-HUD-02 单一队列', () {
    test('并发入队按产生顺序，前项结束才显示后项', () {
      final q = V21ResultNoticeQueue();
      q.enqueue(notice(0));
      q.enqueue(notice(1));
      q.enqueue(notice(2));
      expect(q.length, 3);

      // t=0：显示第 0 条。
      expect(q.advance(0)!.ordinal, 0);
      // t=0.5s：仍在第 0 条（**不得**并发显示第 1 条）。
      expect(q.advance(0.5)!.ordinal, 0);
      expect(q.length, 3);
      // t=1.0s：第 0 条结束 → 第 1 条。
      expect(q.advance(1.0)!.ordinal, 1);
      expect(q.length, 2);
      // t=2.0s：第 2 条。
      expect(q.advance(2.0)!.ordinal, 2);
      expect(q.length, 1);
      // t=3.0s：全部播完。
      expect(q.advance(3.0), isNull);
      expect(q.length, 0);
    });

    test('**不丢事件**：队列里每一条最终都会被显示', () {
      final q = V21ResultNoticeQueue();
      for (var i = 0; i < 5; i++) {
        q.enqueue(notice(i));
      }
      final seen = <int>[];
      for (var ms = 0; ms <= 5000; ms += 50) {
        final c = q.advance(ms / 1000);
        if (c != null && (seen.isEmpty || seen.last != c.ordinal)) {
          seen.add(c.ordinal);
        }
      }
      expect(seen, <int>[0, 1, 2, 3, 4], reason: '五条必须按序全部显示');
    });

    test('队列**不消耗战斗时间**：advance 只读逻辑时间，不改任何规则量', () {
      // 本类不含战斗状态 —— 这里以"同名方法不影响当前项之外的东西"来断言：
      // 反复 advance 到同一时刻，结果必须**幂等**（不会自行推进）。
      final q = V21ResultNoticeQueue();
      q.enqueue(notice(0));
      final a = q.advance(10.0)!.ordinal;
      final b = q.advance(10.0)!.ordinal;
      expect(a, b);
      expect(q.elapsedMsAt(10.0), 0);
      expect(q.elapsedMsAt(10.25), 250);
    });

    test('clear() 清空（重开一局无残留，AC-03）', () {
      final q = V21ResultNoticeQueue();
      q.enqueue(notice(0));
      q.enqueue(notice(1));
      q.advance(0);
      q.clear();
      expect(q.current, isNull);
      expect(q.pending, isEmpty);
      expect(q.length, 0);
      expect(q.advance(5.0), isNull);
    });
  });

  group('V21-HUD-02 几何与无文字', () {
    test('设计基准 1920×1080 下与冻结值完全一致', () {
      final r = emblemRectFor(1920, 1080);
      expect(r.left, closeTo(1728, 1e-9));
      expect(r.top, closeTo(28, 1e-9));
      expect(r.width, closeTo(132, 1e-9));
      expect(r.height, closeTo(176, 1e-9));
    });

    test('窄视口等比缩放，距右/上 **≥24**', () {
      for (final w in <double>[640, 800, 1024, 1600]) {
        final r = emblemRectFor(w, 720);
        expect(r.right, lessThanOrEqualTo(w - 24 + 1e-9), reason: '宽 $w 右边距');
        expect(r.top, greaterThanOrEqualTo(24 - 1e-9), reason: '宽 $w 上边距');
        expect(r.width / r.height, closeTo(132 / 176, 1e-6), reason: '纵横比保持');
      }
    });

    test('视觉层无文字：徽记只由**图形**表达（语义走 aria）', () {
      // 四种徽记各有 assetId，且语义 key 只有两个固定模板。
      expect(V21ResultKind.upgrade.assetId, 'UI-V21-AUTO-UPGRADE-EMBLEM');
      expect(V21ResultKind.supply.assetId, 'UI-V21-RISK-SUPPLY-EMBLEM');
      expect(V21ResultKind.bounty.assetId, 'UI-V21-RISK-BOUNTY-EMBLEM');
      expect(V21ResultKind.overload.assetId, 'UI-V21-RISK-OVERLOAD-EMBLEM');
      expect(V21ResultKind.upgrade.ariaKey, 'toast.upgradeAria');
      for (final k in <V21ResultKind>[
        V21ResultKind.supply, V21ResultKind.bounty, V21ResultKind.overload,
      ]) {
        expect(k.ariaKey, 'toast.riskAria', reason: '风险类共用同一模板');
      }
    });
  });
}
