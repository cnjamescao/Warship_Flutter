import 'package:flutter_test/flutter_test.dart';

import 'package:warship_flutter/main.dart';

void main() {
  testWidgets('tap Play and simulate frames without crash', (tester) async {
    await tester.pumpWidget(const WarshipApp());

    // 使用真实异步等待图片资源加载完成
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    expect(find.text('Play'), findsOneWidget);

    await tester.tap(find.text('Play'));
    await tester.pump();

    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(tester.takeException(), isNull);
    expect(find.text('Game Over'), findsNothing);
  });
}
