// ================================================================
// test/web/web_storage_degradation_test.dart —— WEB-T-05（存储降级）
// ================================================================
// **架构位置**：Web 平台验收测试（存储降级侧）。
//
// **依据**（`04_测试计划与验收用例.md` WEB-T-05）：
//   「localStorage 不可用/配额失败时设置与记录**退化为内存态**、
//     **无未捕获异常**；加载失败显示重试，**20 秒超时不伪造"已加载"**。」
//
// **为什么这条对 Web 特别重要**：浏览器的 localStorage 在
// *隐私模式*、*配额满*、*被策略禁用* 时都会**抛异常** ——
// 而桌面端几乎不会遇到。若存档失败把开局带崩，
// 玩家看到的是"网页打不开"，而日志里什么都没有 ✗。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/infrastructure/progress_store.dart';

/// 一个**读写都抛异常**的存储 —— 模拟 localStorage 被禁用/配额满。
class _ExplodingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async =>
      throw StateError('localStorage 不可用（模拟隐私模式）');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('配额已满（模拟 QuotaExceededError）');

  @override
  Future<void> delete(String key) async =>
      throw StateError('localStorage 不可用');
}

void main() {
  test('WEB-T-05a 存储**读失败**时降级为内存态，且不抛未捕获异常', () async {
    final store = ProgressStore(store: _ExplodingStore());
    // 关键：这句**不得抛**。
    final result = await store.load();
    expect(result.records.highScore, 0,
        reason: '读失败应退化为默认值（内存态）');
    expect(result.records.bestClearSeconds, isNull);
  });

  test('WEB-T-05b 存储**写失败**时 save 不抛出（记录在内部，不影响开局）', () async {
    final store = ProgressStore(store: _ExplodingStore());
    // 关键：这句**不得抛** —— 存档失败不能崩掉游戏（架构 §7）。
    // 返回 bool：写失败应返回 false，**不抛**。
    final ok = await store.saveRecords(
      const GameRecords(highScore: 1234, bestClearSeconds: 42.5),
    );
    expect(ok, isFalse, reason: "配额满时应报告失败而不是抛异常");
  });

  test('WEB-T-05c 降级后**同一进程内**仍可读到刚写的值（内存态可用）', () async {
    // 用一个"写失败但读可用"的存储，验证降级不是"什么都不做"。
    final store = ProgressStore(store: _WriteFailReadOkStore());
    await store.saveRecords(
      const GameRecords(highScore: 777, bestClearSeconds: 33.0),
    );
    final again = await store.load();
    expect(
      again.records.highScore,
      777,
      reason: '写盘失败后应保留在内存里，本次会话仍可见',
    );
  });
}

/// 写失败、读返回空（模拟"能读但配额满"）。
class _WriteFailReadOkStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('配额已满');
  @override
  Future<void> delete(String key) async {}
}
