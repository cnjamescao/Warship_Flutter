// ================================================================
// test/unit/content/asset_manifest_test.dart —— 正式资源清单校验
// ================================================================
// 覆盖：交付清单 §5 第 0 步「建立 v2.0 内容加载、manifest 校验和
//       资源构建复制链路 → 版本/hash/交叉引用校验测试通过」
//       以及 04_测试计划 的 T-ASSET-01 中可由单测覆盖的部分。
//
// 这里的测试直接读取**真实**构建产物 assets/config/v2/manifest.json
// （由 `dart run tool/build_v2_assets.dart` 生成），
// 因此它同时验证"构建复制链路"与"解析器/校验器"两侧。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_bootstrap.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/content/content_error.dart';

/// 构建复制品路径（相对仓库根目录）。
const String kBuiltManifestPath = 'assets/config/v2/manifest.json';

Map<String, Object?> loadBuiltManifest() {
  final file = File(kBuiltManifestPath);
  expect(
    file.existsSync(),
    isTrue,
    reason: '请先运行 `dart run tool/build_v2_assets.dart` 生成构建复制品',
  );
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void main() {
  group('构建复制链路', () {
    test('构建复制品存在且内容版本为 2.1.0-neon-flow', () {
      final json = loadBuiltManifest();
      expect(json['contentVersion'], '2.1.0-neon-flow');
      expect(json['schemaVersion'], AssetManifest.expectedSchemaVersion);
    });

    test('运行时文件已复制到 Flutter 资源目录且真实存在', () {
      final json = loadBuiltManifest();
      final assets = (json['assets'] as List).cast<Map>();

      var visual = 0;
      var audio = 0;
      for (final record in assets) {
        // 字体记录没有 runtimeFiles —— 它是系统字体声明。
        final files = (record['runtimeFiles'] as List?) ?? const <Object?>[];
        for (final path in files.whereType<String>()) {
          expect(
            File(path).existsSync(),
            isTrue,
            reason: '${record['assetId']} 的运行时文件未复制：$path',
          );
          if (path.startsWith('assets/images/v2/')) {
            visual++;
          } else if (path.startsWith('assets/audio/v2/')) {
            audio++;
          } else {
            fail('运行时文件落在预期目录之外：$path');
          }
        }
      }

      expect(visual, 374, reason: '图形/UI 状态文件数量应与素材包一致');
      expect(audio, 67, reason: '物理音频数量应与素材包一致');
    });

    test('图形资源带状态文件，音频资源带 cueId', () {
      final json = loadBuiltManifest();
      final assets = (json['assets'] as List).cast<Map>();

      for (final record in assets) {
        final category = record['category'];
        if (category == 'graphic' || category == 'ui') {
          final renderStates = record['renderStates'] as Map?;
          expect(
            renderStates,
            isNotNull,
            reason: '${record['assetId']} 缺少 renderStates',
          );
          for (final state in (record['states'] as List).whereType<String>()) {
            expect(
              renderStates!.containsKey(state),
              isTrue,
              reason: '${record['assetId']} 的声明状态 $state 没有映射',
            );
          }
        } else if (category == 'sfx' || category == 'bgm') {
          final cueId = record['cueId'];
          expect(
            cueId,
            isA<String>().having((s) => s.isNotEmpty, '非空', isTrue),
            reason: '${record['assetId']} 缺少 cueId',
          );
        }
      }
    });
  });

  group('解析真实 manifest', () {
    late AssetManifest manifest;

    setUpAll(() {
      final result = AssetManifest.parse(
        loadBuiltManifest(),
        expectedVersion: kActiveContentVersion,
      );
      expect(
        result.isSuccess,
        isTrue,
        reason: '正式清单必须能通过校验：\n${result.describeErrors()}',
      );
      manifest = result.requireValue;
    });

    test('共 199 条记录，分五大类', () {
      expect(manifest.length, 199);

      int countOf(AssetCategory category) =>
          manifest.records.where((r) => r.category == category).length;

      expect(countOf(AssetCategory.ui), 74);
      expect(countOf(AssetCategory.graphic), 55);
      expect(countOf(AssetCategory.sfx), 63);
      expect(countOf(AssetCategory.bgm), 5);
      expect(countOf(AssetCategory.font), 2);
    });

    test('三条统一回退资源都存在（素材规范 §1.1）', () {
      for (final id in <String>[
        'GFX-FALLBACK-SILHOUETTE',
        'UI-FALLBACK-ICON',
        'SFX-FALLBACK-SILENT',
      ]) {
        expect(manifest.lookup(id), isNotNull, reason: '缺少统一回退：$id');
      }
    });

    test('每条记录的许可证非空（发布门槛 §6.1）', () {
      for (final record in manifest.records) {
        expect(
          record.license.trim().isNotEmpty,
          isTrue,
          reason: '${record.assetId} 缺少许可证记录',
        );
      }
    });

    test('firstRun 预载集合可独立计算，且不超过首屏预算', () {
      final firstRun = manifest.inLoadGroup(AssetLoadGroup.firstRun).toList();
      expect(firstRun, isNotEmpty, reason: '必须存在 firstRun 资源用于首屏预载');

      final bytes = firstRun.fold<int>(0, (sum, r) => sum + r.memoryEstimateBytes);
      // 产品基线 §2：首屏压缩资源 ≤ 18 MB（此处用 manifest 的解码内存估算上界）。
      expect(
        bytes,
        lessThan(96 * 1024 * 1024),
        reason: 'firstRun 常驻解码内存应远低于 96 MB 上限',
      );
    });

    test('五类敌人的多状态资源均可解析', () {
      for (final enemyId in <String>[
        'GFX-EN-SCOUT',
        'GFX-EN-WING',
        'GFX-EN-SNIPER',
        'GFX-EN-BOMBER',
        'GFX-EN-SHIELD',
      ]) {
        final record = manifest.lookup(enemyId);
        expect(record, isNotNull, reason: '缺少敌人资源 $enemyId');
        expect(record!.hasState('hit'), isTrue, reason: '$enemyId 缺少 hit 状态');
        expect(
          record.hasState('critical'),
          isTrue,
          reason: '$enemyId 缺少 critical 状态（产品 §7.5 要求 HP ≤25% 可视）',
        );
        expect(record.hasState('destroy'), isTrue);
      }
    });

    test('Shield 具备 body/frontShield 互斥状态（产品 §7.5）', () {
      final shield = manifest.lookup('GFX-EN-SHIELD')!;
      expect(shield.hasState('body'), isTrue);
      expect(shield.hasState('frontShield'), isTrue);

      final states = shield.eventBindings
          .where((b) => b.event == 'EnemyDefenseStateChanged')
          .map((b) => b.renderState)
          .toSet();
      expect(
        states,
        containsAll(<String>['body', 'frontShield']),
        reason: '由 EnemyDefenseStateChanged 互斥切换',
      );
    });

    test('敌方攻击绑定必须同时带 enemyId 与 attackId（协议 §3.1）', () {
      const attackEvents = <String>{
        'EnemyAttackTelegraphed',
        'EnemyAttackFired',
      };
      for (final record in manifest.records) {
        for (final binding in record.eventBindings) {
          if (!attackEvents.contains(binding.event)) {
            continue;
          }
          expect(
            binding.when.isEmpty,
            isFalse,
            reason:
                '${record.assetId} 的 ${binding.event} 绑定不允许空 when（必须精确路由）',
          );
          expect(
            binding.hasCondition('enemyId'),
            isTrue,
            reason: '${record.assetId} 的 ${binding.event} 缺少 enemyId',
          );
          expect(
            binding.hasCondition('attackId'),
            isTrue,
            reason: '${record.assetId} 的 ${binding.event} 缺少 attackId',
          );
        }
      }
    });

    test('Boss 攻击绑定必须带 attackId', () {
      const bossAttackEvents = <String>{
        'BossAttackTelegraphed',
        'BossAttackFired',
        'BossAttackEnded',
      };
      for (final record in manifest.records) {
        for (final binding in record.eventBindings) {
          if (!bossAttackEvents.contains(binding.event)) {
            continue;
          }
          expect(
            binding.hasCondition('attackId'),
            isTrue,
            reason: '${record.assetId} 的 ${binding.event} 缺少 attackId',
          );
        }
      }
    });

    test('attackId 取值来自协议 §3.1 的稳定枚举', () {
      const allowed = <String>{
        'scout_shot',
        'wing_shot',
        'sniper_line',
        'bomber_drop',
        'shield_shot',
        'boss_fan',
        'boss_charge',
        'boss_ring',
        'boss_summon',
        'boss_laser',
      };
      for (final record in manifest.records) {
        for (final binding in record.eventBindings) {
          final attackId = binding.stringCondition('attackId');
          if (attackId == null) {
            continue;
          }
          expect(
            allowed,
            contains(attackId),
            reason: '${record.assetId} 使用了未定义的 attackId：$attackId',
          );
        }
      }
    });

    test('hit 临时状态必须声明恢复语义，方向指示器不需要', () {
      // 协议 §3.1 的区分：
      //   * `hit` 是**覆盖在持久状态之上**的临时表现（120 ms），
      //     到期必须回读最后一份数值/防御状态，因此必须 restoreFromSnapshot；
      //   * 8 方向受击指示器这类"出现即消失"的一次性提示，
      //     到期直接隐藏即可，不应声明恢复快照。
      var hitBindings = 0;
      var indicatorBindings = 0;

      for (final record in manifest.records) {
        for (final binding in record.eventBindings) {
          if (binding.transientMs == null) {
            continue;
          }
          if (binding.renderState == 'hit') {
            hitBindings++;
            expect(
              binding.restoreFromSnapshot,
              isTrue,
              reason:
                  '${record.assetId} 的 hit 是临时表现，'
                  '到期必须回读最后一份数值状态（协议 §3.1）',
            );
            expect(
              binding.transientMs,
              120,
              reason: '${record.assetId} 的 hit 固定为 120 ms',
            );
          } else {
            indicatorBindings++;
          }
        }
      }

      expect(hitBindings, greaterThan(0), reason: '应存在 hit 临时绑定');
      expect(
        indicatorBindings,
        greaterThan(0),
        reason: '应存在一次性指示器绑定（8 方向受击提示）',
      );
    });
  });

  group('校验器拒绝非法清单', () {
    test('内容版本不符时返回 versionMismatch', () {
      final json = loadBuiltManifest()..['contentVersion'] = '1.0.0-old';

      final result = AssetManifest.parse(
        json,
        expectedVersion: kActiveContentVersion,
      );

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.versionMismatch),
      );
    });

    test('缺少 assets 数组时返回结构化错误而不是抛异常', () {
      final result = AssetManifest.parse(<String, Object?>{
        'schemaVersion': '1.1.0',
        'contentVersion': kActiveContentVersion,
      }, expectedVersion: kActiveContentVersion);

      expect(result.isFailure, isTrue);
      expect(result.errors.first.kind, ContentErrorKind.schemaViolation);
    });

    test('回退资源不存在时被拒绝', () {
      final json = loadBuiltManifest();
      final assets = (json['assets'] as List).cast<Map>();
      assets.first['fallbackAssetId'] = 'GFX-DOES-NOT-EXIST';

      final result = AssetManifest.parse(
        json,
        expectedVersion: kActiveContentVersion,
      );

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.unknownReference),
      );
    });

    test('AssetId 重复时被拒绝', () {
      final json = loadBuiltManifest();
      final assets = (json['assets'] as List).cast<Map>();
      assets.add(Map<String, Object?>.from(assets.first));

      final result = AssetManifest.parse(
        json,
        expectedVersion: kActiveContentVersion,
      );

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.invalidReference),
      );
    });

    test('许可证为空时被拒绝（发布门槛）', () {
      final json = loadBuiltManifest();
      final assets = (json['assets'] as List).cast<Map>();
      assets.first['license'] = '   ';

      final result = AssetManifest.parse(
        json,
        expectedVersion: kActiveContentVersion,
      );

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('许可证'));
    });

    test('声明的状态缺少 renderStates 映射时被拒绝', () {
      final json = loadBuiltManifest();
      final assets = (json['assets'] as List).cast<Map>();
      final graphic = assets.firstWhere(
        (a) => a['category'] == 'graphic' && (a['states'] as List).isNotEmpty,
      );
      (graphic['states'] as List).add('never-mapped');

      final result = AssetManifest.parse(
        json,
        expectedVersion: kActiveContentVersion,
      );

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('never-mapped'));
    });

    test('音频缺少 cueId 时被拒绝', () {
      final json = loadBuiltManifest();
      final assets = (json['assets'] as List).cast<Map>();
      final audio = assets.firstWhere((a) => a['category'] == 'sfx');
      audio.remove('cueId');

      final result = AssetManifest.parse(
        json,
        expectedVersion: kActiveContentVersion,
      );

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('cueId'));
    });

    test('非法 AssetId 被拒绝', () {
      final json = loadBuiltManifest();
      final assets = (json['assets'] as List).cast<Map>();
      assets.first['assetId'] = 'gfx-lowercase-and space';

      final result = AssetManifest.parse(
        json,
        expectedVersion: kActiveContentVersion,
      );

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.schemaViolation),
      );
    });
  });
}
