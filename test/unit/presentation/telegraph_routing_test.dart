// ================================================================
// test/unit/presentation/telegraph_routing_test.dart —— F-32 路由核查
// ================================================================
// 素材侧的判断：「EN-SHIELD 在约 85 秒显示了 GFX-WARN-CONE，
// 而该资源只应服务 Boss 的 boss_fan 预警 → 研发存在绕过 manifest
// 或错误事件路由」。
//
// 研发按要求核查后，**证据不支持该结论**：
//   * `EN-SHIELD` 的 `attackProfile.telegraphAssetId` 是 `None`；
//   * 表现层**从不使用** `telegraphAssetId`（声明未接线）；
//   * 敌机外观只取 `enemy.assetId`（F-28 起不再用事件路由）。
//
// 本文件把"谁有权请求 GFX-WARN-CONE"钉死：
// 正面回答"有没有跨事件误用"，而不是靠推理。
// ================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';

late AssetManifest manifest;
late Map<String, Object?> enemiesJson;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    manifest = AssetManifest.parse(
      jsonDecode(File('assets/config/v2/manifest.json').readAsStringSync())
          as Map<String, Object?>,
    ).requireValue;
    enemiesJson =
        jsonDecode(File('assets/config/v2/enemies.json').readAsStringSync())
            as Map<String, Object?>;
  });

  test('F-32 GFX-WARN-CONE 只能由 Boss 的 boss_fan 预警请求', () {
    final record = manifest.lookup('GFX-WARN-CONE');
    expect(record, isNotNull, reason: 'GFX-WARN-CONE 应已登记');

    expect(
      record!.eventBindings,
      hasLength(1),
      reason: 'GFX-WARN-CONE 应**只有一条**绑定',
    );
    final binding = record.eventBindings.single;
    expect(binding.event, 'BossAttackTelegraphed');
    expect(binding.when['attackId'], 'boss_fan');

    // 反面：任何敌人相关的绑定都不允许出现它。
    for (final b in record.eventBindings) {
      expect(
        b.event.startsWith('Enemy'),
        isFalse,
        reason: 'GFX-WARN-CONE 不得绑定到敌方事件：${b.event}',
      );
    }
  });

  test('F-32 没有任何敌机的配置请求 GFX-WARN-CONE', () {
    final offenders = <String>[];
    for (final raw in (enemiesJson['enemies'] as List).cast<Map>()) {
      void scan(Object? node, String path) {
        if (node is Map) {
          for (final entry in node.entries) {
            if (entry.value == 'GFX-WARN-CONE') {
              offenders.add('${raw['id']} → $path.${entry.key}');
            }
            scan(entry.value, '$path.${entry.key}');
          }
        } else if (node is List) {
          for (var i = 0; i < node.length; i++) {
            scan(node[i], '$path[$i]');
          }
        }
      }

      scan(raw, raw['id'] as String);
    }

    expect(
      offenders,
      isEmpty,
      reason: '敌机配置里出现了 GFX-WARN-CONE 的请求：$offenders',
    );
  });

  test('F-32 表现层不得对敌机请求 Boss 预警素材', () {
    // 静态检查：渲染器里不应出现把 Boss 预警素材用于敌机的写法。
    final source = File(
      'lib/game/presentation/warship_v2_game.dart',
    ).readAsStringSync();
    final lines = source.split('\n');
    final offenders = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) {
        continue;
      }
      if (line.contains('GFX-WARN-CONE')) {
        offenders.add('第 ${i + 1} 行：${line.trim()}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '渲染器里硬编码了 GFX-WARN-CONE —— 资源必须经 manifest 绑定：\n'
          '${offenders.join('\n')}',
    );
  });

  test('F-32 Shield 正面防御应使用 GFX-EN-SHIELD 的 frontShield 状态', () {
    final record = manifest.lookup('GFX-EN-SHIELD');
    expect(record, isNotNull);
    expect(
      record!.states,
      contains('frontShield'),
      reason: 'GFX-EN-SHIELD 应有 frontShield 状态（Shield 正面防御的唯一授权视觉）',
    );
    expect(
      record.renderStates.containsKey('frontShield'),
      isTrue,
      reason: 'frontShield 状态应有渲染规格',
    );
  });
}
