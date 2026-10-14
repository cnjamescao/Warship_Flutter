// ================================================================
// test/unit/content/content_catalog_test.dart —— 内容目录与交叉引用校验
// ================================================================
// 覆盖：Spec/02_技术/v2.0/02_运行时与数据协议.md §1.1 的拒绝规则
//       与交付清单 §5 第 0 步「版本/hash/交叉引用校验测试通过」。
//
// 测试读取**真实** assets/config/v2/*.json 与构建复制品 manifest，
// 因此它同时验证配置内容本身与加载/校验器两侧。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/content/content_catalog.dart';
import 'package:warship_flutter/game/content/content_error.dart';

const String kConfigDir = 'assets/config/v2';

Map<String, Map<String, Object?>> loadRealContent() {
  final result = <String, Map<String, Object?>>{};
  for (final name in ContentFiles.required) {
    final file = File('$kConfigDir/$name');
    expect(file.existsSync(), isTrue, reason: '缺少内容文件：$name');
    result[name] = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }
  return result;
}

AssetManifest loadRealManifest() {
  final file = File('$kConfigDir/manifest.json');
  expect(
    file.existsSync(),
    isTrue,
    reason: '请先运行 `dart run tool/build_v2_assets.dart`',
  );
  final result = AssetManifest.parse(
    jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
  );
  expect(result.isSuccess, isTrue, reason: result.describeErrors());
  return result.requireValue;
}

void main() {
  late AssetManifest manifest;
  late Map<String, Map<String, Object?>> files;

  setUpAll(() {
    manifest = loadRealManifest();
    files = loadRealContent();
  });

  group('正式内容可以通过全部校验', () {
    late ContentCatalog catalog;

    setUpAll(() {
      final result = ContentCatalog.load(files: files, manifest: manifest);
      expect(
        result.isSuccess,
        isTrue,
        reason: '正式内容必须通过校验：\n${result.describeErrors()}',
      );
      catalog = result.requireValue;
    });

    test('内容版本为 2.0.5-release', () {
      expect(catalog.contentVersion, '2.0.5-release');
    });

    test('五类敌人、十六张升级卡、六个武器系统均被加载', () {
      expect(catalog.enemyList.length, 5);
      expect(catalog.upgradeCards.length, 16);
      expect(catalog.weaponList.length, 6);

      for (final id in <String>[
        'EN-SCOUT',
        'EN-WING',
        'EN-SNIPER',
        'EN-BOMBER',
        'EN-SHIELD',
      ]) {
        expect(catalog.enemyById(id), isNotNull, reason: '缺少敌人 $id');
      }
    });

    test('升级经验阈值与产品基线 §4.2 一致', () {
      expect(catalog.xpThresholds, <int>[20, 55, 105, 170, 250, 345]);
      expect(catalog.upgrades['firstDraftEarliestSecond'], 15.0);
      expect(catalog.upgrades['maxDrafts'], 6);
    });

    test('保证卡规则引用的 ID 都真实存在', () {
      final guaranteed = catalog.upgrades['guaranteed'] as Map;
      final first = (guaranteed['firstDraft'] as List).cast<String>();
      final second = (guaranteed['secondDraftAnyOf'] as List).cast<String>();

      expect(first, contains('UP-PULSE-RATE'));
      for (final id in <String>[...first, ...second]) {
        expect(catalog.upgradeById(id), isNotNull, reason: '保证卡不存在：$id');
      }
    });

    test('激光与无人机在配置层面互斥（产品 §4.2）', () {
      final laser = catalog.upgradeById('UP-LASER-UNLOCK')!;
      final drone = catalog.upgradeById('UP-DRONE-UNLOCK')!;

      expect((laser['excludes'] as List), contains('UP-DRONE-UNLOCK'));
      expect((drone['excludes'] as List), contains('UP-LASER-UNLOCK'));
      expect(laser['maxLevel'], 1);
      expect(drone['maxLevel'], 1);
    });

    test('波次表共 31 行，风险门在 55 与 115 秒', () {
      expect(catalog.waveList.length, 31);

      final gateSeconds = catalog.waveList
          .where((w) => w['riskGateId'] != null)
          .map((w) => w['startSecond'])
          .toList();
      expect(gateSeconds, <int>[55, 115]);
    });

    test('150 秒行是 Boss 入场且不再生成普通敌人', () {
      final last = catalog.waveList.last;
      expect(last['startSecond'], 150);
      expect(last['bossEntry'], isTrue);
      expect((last['spawns'] as List), isEmpty);
      expect(last['clearEnemyBullets'], isTrue);
    });

    test('三个固定精英事件的敌人与词缀都存在', () {
      final elite = catalog.enemies['elite'] as Map;
      final events = (elite['fixedEvents'] as List).cast<Map>();

      expect(events.map((e) => e['second']).toList(), <int>[65, 105, 130]);
      for (final event in events) {
        expect(
          catalog.enemyById(event['enemyId'] as String),
          isNotNull,
          reason: '精英事件引用了未定义敌人：${event['enemyId']}',
        );
      }
    });

    test('Boss 五个招式都有 attackId，且造成伤害的招式都有预警', () {
      final ids = catalog.bossAttacks
          .map((a) => a['attackId'] as String)
          .toSet();
      expect(
        ids,
        containsAll(<String>[
          'boss_fan',
          'boss_charge',
          'boss_ring',
          'boss_summon',
          'boss_laser',
          'boss_weakpoint',
        ]),
      );

      for (final attack in catalog.bossAttacks) {
        final hasProjectile =
            (attack['projectile'] as Map?)?['damage'] is num;
        final hasDirect = attack['damage'] is num || attack['contactDamage'] is num;
        if (hasProjectile || hasDirect) {
          expect(
            attack['telegraphSeconds'],
            greaterThan(0),
            reason: '${attack['attackId']} 造成伤害却没有预警',
          );
        }
      }
    });

    test('Boss 阶段阈值与循环与产品基线 §7.2 一致', () {
      expect(catalog.boss['phaseThresholds'], <double>[0.70, 0.35]);
      expect(catalog.boss['hp'], 2600);

      final phases = (catalog.boss['phases'] as List).cast<Map>();
      expect(phases.map((p) => p['id']).toList(), <String>['P1', 'P2', 'P3']);
      expect(
        (phases.first['loop'] as List).cast<String>(),
        <String>['boss_fan', 'boss_charge'],
      );
    });

    test('玩家数值与产品基线 §3.3 / §3.4 一致', () {
      final player = catalog.player;
      expect((player['spawnPosition'] as List), <int>[960, 900]);
      expect(player['moveSpeed'], 340);
      expect((player['bodyHitbox'] as Map)['radius'], 30);
      expect((player['health'] as Map)['initial'], 100);
      expect((player['shield'] as Map)['initial'], 30);
      expect((player['shield'] as Map)['regenDelaySeconds'], 8.0);
      expect((player['shield'] as Map)['regenPerSecond'], 3);
      expect((player['dash'] as Map)['distance'], 360);
      expect((player['dash'] as Map)['maxCharges'], 2);
    });

    test('文案键完整：每张卡的名称与描述都有中文文本', () {
      for (final card in catalog.upgradeCards) {
        final id = card['id'] as String;
        expect(catalog.hasText(card['nameKey'] as String), isTrue,
            reason: '$id 缺少名称文案');
        expect(catalog.hasText(card['descKey'] as String), isTrue,
            reason: '$id 缺少描述文案');
      }
      // 缺失键返回 key 本身而不是崩溃
      expect(catalog.text('never.defined.key'), 'never.defined.key');
    });

    test('风险门保底选项一定是可选项之一', () {
      final options = (catalog.riskGates['options'] as List).cast<Map>();
      final optionIds = options.map((o) => o['id']).toSet();

      for (final gate in (catalog.riskGates['gates'] as List).cast<Map>()) {
        expect(optionIds, contains(gate['timeoutFallback']));
      }
      expect(catalog.riskGates['common'], isNotNull);
    });
  });

  group('校验器拒绝非法内容', () {
    ContentResult<ContentCatalog> loadWith(
      void Function(Map<String, Map<String, Object?>> files) mutate,
    ) {
      final copy = <String, Map<String, Object?>>{
        for (final entry in files.entries)
          entry.key: jsonDecode(jsonEncode(entry.value)) as Map<String, Object?>,
      };
      mutate(copy);
      return ContentCatalog.load(files: copy, manifest: manifest);
    }

    test('未知资产 ID 被拒绝', () {
      final result = loadWith((f) {
        (f[ContentFiles.player]!['assets'] as Map)['bodyAssetId'] =
            'GFX-NOT-IN-MANIFEST';
      });

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.unknownReference),
      );
    });

    test('波次引用未定义敌人被拒绝', () {
      final result = loadWith((f) {
        final waves = f[ContentFiles.waves]!['waves'] as List;
        ((waves.first as Map)['spawns'] as List).first['enemyId'] = 'EN-NOPE';
      });

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('EN-NOPE'));
    });

    test('波次秒重复被拒绝', () {
      final result = loadWith((f) {
        final waves = f[ContentFiles.waves]!['waves'] as List;
        (waves[1] as Map)['startSecond'] = 0;
      });

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.invalidReference),
      );
    });

    test('循环前置被拒绝', () {
      final result = loadWith((f) {
        final cards = f[ContentFiles.upgrades]!['cards'] as List;
        final missileSalvo = cards.firstWhere(
          (c) => (c as Map)['id'] == 'UP-MISSILE-SALVO',
        ) as Map;
        missileSalvo['prerequisites'] = ['UP-MISSILE-RADIUS'];
        final radius = cards.firstWhere(
          (c) => (c as Map)['id'] == 'UP-MISSILE-RADIUS',
        ) as Map;
        radius['prerequisites'] = ['UP-MISSILE-SALVO'];
      });

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('循环前置'));
    });

    test('互斥卡被同时写进同一保证组时被拒绝', () {
      final result = loadWith((f) {
        final guaranteed = f[ContentFiles.upgrades]!['guaranteed'] as Map;
        guaranteed['secondDraftAnyOf'] = [
          'UP-LASER-UNLOCK',
          'UP-DRONE-UNLOCK',
        ];
      });

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('互斥卡'));
    });

    test('未定义的难度门选项被拒绝', () {
      final result = loadWith((f) {
        final gates = f[ContentFiles.riskGates]!['gates'] as List;
        (gates.first as Map)['optionIds'] = ['RG-NOT-DEFINED'];
      });

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('RG-NOT-DEFINED'));
    });

    test('Boss 造成伤害却没有预警时被拒绝', () {
      final result = loadWith((f) {
        final attacks = f[ContentFiles.boss]!['attacks'] as List;
        final fan = attacks.firstWhere(
          (a) => (a as Map)['attackId'] == 'boss_fan',
        ) as Map;
        fan['telegraphSeconds'] = 0;
      });

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.missingTelegraph),
      );
    });

    test('负数 HP 被拒绝', () {
      final result = loadWith((f) {
        final enemies = f[ContentFiles.enemies]!['enemies'] as List;
        (enemies.first as Map)['hp'] = -5;
      });

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('不得为负'));
    });

    test('内容版本不符被拒绝', () {
      final result = loadWith((f) {
        f[ContentFiles.player]!['contentVersion'] = '1.0.0';
      });

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.versionMismatch),
      );
    });

    test('缺少必需内容文件被拒绝', () {
      final copy = <String, Map<String, Object?>>{...files}
        ..remove(ContentFiles.boss);

      final result = ContentCatalog.load(files: copy, manifest: manifest);

      expect(result.isFailure, isTrue);
      expect(
        result.errors.map((e) => e.kind),
        contains(ContentErrorKind.fileMissing),
      );
    });

    test('文案键缺失被拒绝（防止未翻译项进入发布）', () {
      final result = loadWith((f) {
        final cards = f[ContentFiles.upgrades]!['cards'] as List;
        (cards.first as Map)['nameKey'] = 'up.missing.name';
      });

      expect(result.isFailure, isTrue);
      expect(result.describeErrors(), contains('文案键不存在'));
    });
  });
}
