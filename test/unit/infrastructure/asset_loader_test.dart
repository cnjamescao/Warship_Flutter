// ================================================================
// test/unit/infrastructure/asset_loader_test.dart —— 事件→资源路由
// ================================================================
// 覆盖 P0：T-ASSET-01 / T-ASSET-02
//
// 表驱动：遍历真实 manifest 的每一条绑定，用它的 when 反构造事件负载
// 再解析回去，验证该绑定确实出现在结果里。
//
// 关于"多层"：一个事件可以合法地驱动多个视觉层。例如
// `EnemyAttackTelegraphed{EN-SNIPER, sniper_line}` 同时命中
// `GFX-EN-SNIPER#charge`（机体蓄力）与 `GFX-WARN-LINE`（地面预警线）。
// 因此解析结果是**列表**；需要唯一结果的场合用 visualMatchStatus 判定。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_bootstrap.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/infrastructure/asset_loader.dart';

const String kConfigDir = 'assets/config/v2';

Map<String, Object?> loadManifestJson() =>
    jsonDecode(File('$kConfigDir/manifest.json').readAsStringSync())
        as Map<String, Object?>;

/// 展开 manifest 里的全部绑定，并附上所属资源的关键字段。
List<Map<String, Object?>> allBindings(Map<String, Object?> json) {
  final result = <Map<String, Object?>>[];
  for (final raw in (json['assets'] as List).cast<Map>()) {
    final asset = raw.cast<String, Object?>();
    for (final b in ((raw['eventBindings'] as List?) ?? const <Object?>[])
        .cast<Map>()) {
      result.add(<String, Object?>{
        ...b.cast<String, Object?>(),
        'assetId': asset['assetId'],
        'category': asset['category'],
      });
    }
  }
  return result;
}

/// 由 `when` 反构造事件负载。
///
/// 关键：`hpRatioLte: 0.25` 这类条件描述的是**事件负载里的 `hpRatio`**，
/// 所以参数名要去掉 `Lte` / `Gt` 后缀，值取条件里的数字。
Map<String, Object?> paramsOf(Map<String, Object?> binding) {
  final when = binding['when'];
  if (when is! Map) {
    return const <String, Object?>{};
  }
  final params = <String, Object?>{};
  for (final entry in when.entries) {
    final key = entry.key as String;
    if (key.endsWith('Lte')) {
      // `≤ 阈值`：阈值本身即满足。
      params[key.substring(0, key.length - 3)] = entry.value;
    } else if (key.endsWith('Gt')) {
      // `> 阈值`：严格大于，喂阈值本身**不满足**，必须略高一点。
      params[key.substring(0, key.length - 2)] =
          (entry.value as num) + 1e-6;
    } else {
      params[key] = entry.value;
    }
  }
  return params;
}

bool isVisual(Map<String, Object?> binding) =>
    binding['category'] == 'graphic' || binding['category'] == 'ui';

void main() {
  late AssetManifest manifest;
  late AssetBindingTable table;
  late Map<String, Object?> json;
  late List<Map<String, Object?>> bindings;

  setUpAll(() {
    json = loadManifestJson();
    final parsed = AssetManifest.parse(
      json,
      expectedVersion: kActiveContentVersion,
    );
    expect(parsed.isSuccess, isTrue, reason: parsed.describeErrors());
    manifest = parsed.requireValue;
    table = const AssetLoader().build(manifest);
    bindings = allBindings(json);
  });

  group('T-ASSET-01 路由表覆盖', () {
    test('manifest 里的每条绑定都能在解析结果中找到自己', () {
      var visual = 0;
      var audio = 0;

      for (final binding in bindings) {
        final event = binding['event'] as String;
        final params = paramsOf(binding);
        final assetId = binding['assetId'] as String;

        if (isVisual(binding)) {
          final matches = table.resolveVisuals(event, params);
          expect(
            matches.map((m) => m.assetId.value),
            contains(assetId),
            reason:
                '$assetId 的 $event 绑定没有出现在解析结果里，'
                '条件=$params；实际命中=${matches.map((m) => m.assetId.value).toList()}',
          );
          visual++;
        } else {
          final matches = table.resolveCues(event, params);
          expect(
            matches.map((m) => m.assetId.value),
            contains(assetId),
            reason: '$assetId 的 $event cue 绑定没有出现在解析结果里，条件=$params',
          );
          audio++;
        }
      }

      expect(visual, greaterThan(0));
      expect(audio, greaterThan(0));
      expect(visual + audio, bindings.length);
    });

    test('每条绑定的 renderState 都能被精确解析回来', () {
      for (final binding in bindings) {
        if (!isVisual(binding)) {
          continue;
        }
        final state = binding['renderState'];
        final matches = table.resolveVisuals(
          binding['event'] as String,
          paramsOf(binding),
        );
        final mine = matches.firstWhere(
          (m) => m.assetId.value == binding['assetId'],
        );
        expect(mine.renderState, state, reason: '${binding['assetId']}');
        expect(mine.runtimeFiles, isNotEmpty);
        if (state != null) {
          expect(mine.stateSpec, isNotNull);
        }
      }
    });

    test('敌方攻击绑定必须同时带 enemyId 与 attackId（协议 §3.1）', () {
      for (final binding in bindings) {
        final event = binding['event'] as String;
        if (event != 'EnemyAttackTelegraphed' && event != 'EnemyAttackFired') {
          continue;
        }
        final when = (binding['when'] as Map).cast<String, Object?>();
        expect(when.containsKey('enemyId'), isTrue, reason: '$event 缺 enemyId');
        expect(when.containsKey('attackId'), isTrue, reason: '$event 缺 attackId');
      }
    });

    test('Boss 攻击绑定必须带 attackId', () {
      const bossEvents = <String>{
        'BossAttackTelegraphed',
        'BossAttackFired',
        'BossAttackEnded',
      };
      for (final binding in bindings) {
        final event = binding['event'] as String;
        if (!bossEvents.contains(event)) {
          continue;
        }
        final when = (binding['when'] as Map).cast<String, Object?>();
        expect(
          when.containsKey('attackId'),
          isTrue,
          reason: '${binding['assetId']} 的 $event 缺少 attackId',
        );
      }
    });

    test('38 种表现事件全部有绑定（v2.1 新增 2 种）', () {
      expect(table.boundEvents.length, 38);
      for (final event in <String>[
        'DashStarted',
        'DashEnded',
        'EnemyAttackTelegraphed',
        'BossAttackFired',
        'PlayerVitalStateChanged',
        'EnemyDefenseStateChanged',
        'RunEnded',
        'WeaponSustainStarted',
        'WeaponSustainStopped',
        // v2.1 新增的两种无条件路由事件（蓝图 §2.2）。
        'AutoUpgradeGranted',
        'SectorClearStarted',
      ]) {
        expect(
          table.hasVisualBinding(event) || table.hasAudioBinding(event),
          isTrue,
          reason: '事件 $event 没有任何表现绑定',
        );
      }
    });

    test('音频绑定带出总线、循环与并发参数', () {
      final tap = table.resolveCues(
        'UiCommand',
        <String, Object?>{'command': 'confirm'},
      ).single;
      expect(tap.cueId, isNotNull);
      expect(tap.bus, isNotNull);
      expect(tap.maxVoices, greaterThan(0));

      final bgm = table.resolveCues(
        'UiCommand',
        <String, Object?>{'command': 'homeOpened'},
      ).single;
      expect(bgm.loop, isTrue, reason: 'BGM-HOME 是循环音');
    });
  });

  group('T-ASSET-02 匹配语义', () {
    test('缺少区分参数时无匹配，而不是命中宽泛绑定', () {
      expect(table.resolveVisuals('EnemyAttackTelegraphed'), isEmpty);
    });

    test('参数不匹配时无匹配', () {
      expect(
        table.resolveVisuals('EnemyAttackTelegraphed', <String, Object?>{
          'enemyId': 'EN-NOT-REAL',
          'attackId': 'nope',
        }),
        isEmpty,
      );
    });

    test('条件匹配是"全部满足"而不是"任一满足"', () {
      expect(
        table.resolveVisuals('EnemyAttackTelegraphed', <String, Object?>{
          'enemyId': 'EN-SNIPER',
        }),
        isEmpty,
      );
      expect(
        table.resolveVisuals('EnemyAttackTelegraphed', <String, Object?>{
          'attackId': 'sniper_line',
        }),
        isEmpty,
      );
    });

    test('狙击机预警同时命中机体蓄力与地面预警线（多层是设计使然）', () {
      final matches = table.resolveVisuals(
        'EnemyAttackTelegraphed',
        <String, Object?>{'enemyId': 'EN-SNIPER', 'attackId': 'sniper_line'},
      );

      final byAsset = <String, ResolvedVisual>{
        for (final m in matches) m.assetId.value: m,
      };

      expect(byAsset.keys, containsAll(<String>['GFX-EN-SNIPER', 'GFX-WARN-LINE']));
      expect(byAsset['GFX-EN-SNIPER']!.renderState, 'charge');
      expect(byAsset['GFX-WARN-LINE']!.renderState, 'default');
    });

    test('数值条件按 Lte 正确比较：低血命中 critical，高血不命中', () {
      final low = table.resolveVisuals(
        'EnemyVitalStateChanged',
        <String, Object?>{'enemyId': 'EN-SCOUT', 'hpRatio': 0.25},
      );
      final high = table.resolveVisuals(
        'EnemyVitalStateChanged',
        <String, Object?>{'enemyId': 'EN-SCOUT', 'hpRatio': 0.9},
      );

      expect(low.single.assetId.value, 'GFX-EN-SCOUT');
      expect(low.single.renderState, 'critical');
      expect(high, isEmpty, reason: '0.9 不满足 ≤0.25');
    });

    test('空 when 的生命周期事件可以解析（例如 DashStarted）', () {
      final matches = table.resolveVisuals('DashStarted');
      expect(matches, isNotEmpty);
      expect(matches.first.renderState, isNotNull);
    });

    test('完全未绑定的事件返回空列表而不抛异常', () {
      expect(table.resolveVisuals('NoSuchEventEver'), isEmpty);
      expect(table.resolveCues('NoSuchEventEver'), isEmpty);
      expect(table.hasVisualBinding('NoSuchEventEver'), isFalse);
    });

    test('visualMatchStatus 能区分唯一命中、无命中与歧义', () {
      // 唯一命中：某个敌人自身的 critical。
      expect(
        table.visualMatchStatus('EnemyVitalStateChanged', <String, Object?>{
          'enemyId': 'EN-SCOUT',
          'hpRatio': 0.2,
        }),
        BindingMatchStatus.matched,
      );
      // 无命中。
      expect(
        table.visualMatchStatus('EnemyVitalStateChanged', <String, Object?>{
          'enemyId': 'EN-NOPE',
          'hpRatio': 0.2,
        }),
        BindingMatchStatus.noMatch,
      );
      // 歧义 / 多层：狙击预警同时命中两条。
      expect(
        table.visualMatchStatus('EnemyAttackTelegraphed', <String, Object?>{
          'enemyId': 'EN-SNIPER',
          'attackId': 'sniper_line',
        }),
        BindingMatchStatus.ambiguous,
      );
    });
  });

  group('绑定表结构', () {
    test('表是不可变的（外部无法改写入索引）', () {
      expect(
        () => table.visualByEvent['DashStarted'] = const <IndexedBinding>[],
        throwsUnsupportedError,
      );
    });

    test('每个事件的绑定列表本身也不可变', () {
      final list = table.visualByEvent['DashStarted']!;
      expect(() => list.add(list.first), throwsUnsupportedError);
    });

    test('未绑定事件不会出现在索引中', () {
      expect(table.boundEvents, isNot(contains('NoSuchEventEver')));
    });
  });
}
