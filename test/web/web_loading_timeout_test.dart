// ================================================================
// test/web/web_loading_timeout_test.dart —— WEB-T-05（加载超时）
// ================================================================
// **架构位置**：Web 平台验收测试（加载超时侧）。
//
// **依据**（WEB-T-05 后半句）：
//   「加载失败显示重试，**20 秒超时不伪造"已加载"**」。
//
// **为什么这条必须自动化**：超时是**时间相关**的行为，
//   人眼很难判断"到底等了 20 秒还是 18 秒" ✗，
//   而"没超时就假装加载好了"是**最坏**的失败方式
//   （玩家进不去，却看不到任何错误）✗。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_app_flow.dart';

void main() {
  test('WEB-T-05d 超时阈值是 **20 秒**（规范固定值）', () {
    expect(kLoadingTimeoutSeconds, 20);
  });

  testWidgets('WEB-T-05e 超时前一直转圈，超时后出现**重试**', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LoadingSurface(onRetry: () => retried++),
      ),
    );

    // 超时前：有进度圈，无"重试"。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('重试'), findsNothing);

    // 推进 19 秒：**仍未超时**。
    await tester.pump(const Duration(seconds: 19));
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '19 秒时不应超时');
    expect(find.text('重试'), findsNothing);

    // 推进到 20 秒：出现"加载超时"与"重试"。
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('加载超时'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // **关键**：不得伪造"已加载" —— 进度圈应消失，但不进入任何游戏界面。
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 点重试：回调被调用一次，且回到转圈状态。
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retried, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
