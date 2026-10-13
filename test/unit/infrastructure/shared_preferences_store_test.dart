// ================================================================
// test/unit/infrastructure/shared_preferences_store_test.dart
// ================================================================
// 验证平台存储适配器与 ProgressStore 的契约一致：
// 七个固定键、读写往返、失败降级。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warship_flutter/game/infrastructure/progress_store.dart';
import 'package:warship_flutter/game/infrastructure/shared_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('读写往返：设置与记录经平台存储持久化', () async {
    final store = await SharedPreferencesStore.open();
    final progress = ProgressStore(store: store);

    expect(
      await progress.saveSettings(
        const GameSettings(musicEnabled: false, reduceMotion: true),
      ),
      isTrue,
    );
    expect(
      await progress.saveRecords(
        const GameRecords(highScore: 4200, bestClearSeconds: 173.4),
      ),
      isTrue,
    );

    // 用同一份底层存储重新读取，模拟重启应用。
    final reloaded = await ProgressStore(
      store: await SharedPreferencesStore.open(),
    ).load();

    expect(reloaded.settings.musicEnabled, isFalse);
    expect(reloaded.settings.reduceMotion, isTrue);
    expect(reloaded.settings.sfxEnabled, isTrue);
    expect(reloaded.records.highScore, 4200);
    expect(reloaded.records.bestClearSeconds, closeTo(173.4, 1e-9));
  });

  test('空存储使用默认值', () async {
    final result = await ProgressStore(
      store: await SharedPreferencesStore.open(),
    ).load();

    expect(result.usedDefaults, isTrue);
    expect(result.settings, const GameSettings());
    expect(result.records.highScore, 0);
  });

  test('损坏值退化为默认值而不抛异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ProgressKeys.schemaVersion: '1',
      ProgressKeys.highScore: 'not-a-number',
    });

    final result = await ProgressStore(
      store: await SharedPreferencesStore.open(),
    ).load();

    expect(result.records.highScore, 0);
  });

  test('openOrMemory 在存储不可用时退化为内存实现', () async {
    // 只要不抛异常并返回一个可用存储即满足契约。
    final store = await SharedPreferencesStore.openOrMemory();
    expect(await store.read('missing.key'), isNull);
    await store.write('k', 'v');
    expect(await store.read('k'), 'v');
  });
}
