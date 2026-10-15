// ================================================================
// test/unit/core/baseline_recorder_test.dart —— AC-06 基准录制器
// ================================================================
// 协议 §5.1：成功条件是「**180 秒前胜利且全程 `hpDamage=0`**
// （护盾承伤允许）」，且「**不得用脚本搜索、手工篡改 JSON 或
// '假回放'替代**」。
//
// 因此录制器必须有两条刚性：
//   1. **一票否决** —— 只要掉过一次 HP，这局就不能作为基准，
//      不能事后挑一局"看起来干净"的；
//   2. **只记录真实发生的事** —— 逐帧输入原样保存，选择来自真实事件。
// ================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/core/baseline_recorder.dart';
import 'package:warship_flutter/game/core/domain_event.dart';
import 'package:warship_flutter/game/core/input_frame.dart';
import 'package:warship_flutter/game/domain/values.dart';

BaselineRecording _newRecorder() => BaselineRecording(
  seed: 0x4E454F4E0001,
  contentVersion: '2.0.5-release',
  manifestSha256: 'sha-test',
);

void main() {
  test('一票否决：只要掉过一次 HP，就不能作为无伤基准', () {
    final r = _newRecorder()..victory = true;
    expect(r.isEligibleBaseline, isTrue, reason: '未受伤 + 胜利 = 合规');

    // 中途受了一次 HP 伤害。
    r.consume(
      const PlayerDamaged(
        sourceType: 'enemyProjectile',
        shieldDamage: 0,
        hpDamage: 3,
        hpAfter: 97,
        shieldAfter: 0,
      ),
    );

    expect(r.hpNeverDamaged, isFalse);
    expect(
      r.isEligibleBaseline,
      isFalse,
      reason: '§5.1 要求全程 hpDamage=0 —— 掉过一次即不合格，'
          '不允许事后挑一局"看起来干净"的',
    );
  });

  test('护盾承伤**不算**受伤（§5.1 明确"护盾承伤允许"）', () {
    final r = _newRecorder()..victory = true;
    r.consume(
      const PlayerDamaged(
        sourceType: 'enemyProjectile',
        shieldDamage: 12,
        hpDamage: 0, // 只掉护盾
        hpAfter: 100,
        shieldAfter: 18,
      ),
    );
    expect(r.hpNeverDamaged, isTrue);
    expect(r.isEligibleBaseline, isTrue);
  });

  test('失败局不能作为基准', () {
    final r = _newRecorder();
    r.consume(
      const RunEnded(
        result: 'defeat',
        durationSeconds: 40,
        score: 100,
        seed: 0x4E454F4E0001,
        bossHpRatio: 1.0,
        resultTier: 'bronze',
      ),
    );
    expect(r.victory, isFalse);
    expect(r.isEligibleBaseline, isFalse);
  });

  test('逐帧输入原样记录，且选卡/风险门选择来自真实事件', () {
    final r = _newRecorder();
    r.recordFrame(
      const InputFrame(moveDirection: Vec2(-1, 0), dashRequested: true),
    );
    r.recordFrame(const InputFrame(moveDirection: Vec2(0.5, -1)));
    r.consume(const UpgradeSelected(cardId: 'UP-PULSE-RATE', newLevel: 1));
    r.consume(
      const RiskSelected(
        gateId: 'RG-55',
        optionId: 'RG-SUPPLY',
        wasTimeout: false,
      ),
    );

    expect(r.frames, hasLength(2));
    expect(r.frames.first['x'], -1.0);
    expect(r.frames.first['dash'], true);
    expect(r.cardSelections.values, contains('UP-PULSE-RATE'));
    expect(r.riskSelections.values, contains('RG-SUPPLY'));
  });

  test('序列化包含 §5.1 要求的全部字段', () {
    final r = _newRecorder()..victory = true;
    r.recordFrame(const InputFrame(moveDirection: Vec2(1, 1)));
    r.consume(
      const RunEnded(
        result: 'victory',
        durationSeconds: 120,
        score: 5000,
        seed: 0x4E454F4E0001,
        bossHpRatio: 0,
        resultTier: 'gold',
      ),
    );
    final json = jsonDecode(r.encode()) as Map<String, Object?>;
    for (final key in <String>[
      'version',
      'seed',
      'contentVersion',
      'manifestSha256',
      'result',
      'score',
      'durationSeconds',
      'frames',
      'cardSelections',
      'riskSelections',
    ]) {
      expect(json.containsKey(key), isTrue, reason: '缺少 §5.1 要求的字段：$key');
    }
    expect(json['contentVersion'], '2.0.5-release');
  });
}
