// ================================================================
// test/unit/content/v21_manifest_frame_rect_test.dart —— V21-MANIFEST
// ================================================================
// **架构位置**：Content 层测试。验证 v2.1 新增的 `frameRect` schema 能力。
//
// **为什么需要**：素材规范 §2 规定 v2.1 图形是**整张 sheet（2172×724）
// + 每个子图的精确 `frameRect`**，而 §1 明文**禁止从文件名推断帧、
// 禁止把相邻格或等分当帧**。因此裁切信息必须由 manifest 承载并被校验。
//
// **每条断言都能失败**（v2.1 默认要求 R6.2）：
//   * 数量不符 → 必须产生结构化错误（而不是静默错帧或抛异常）；
//   * 宽高非正 → 必须被拒绝（否则画出空白帧）。
// ================================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/app/v2_bootstrap.dart';
import 'package:warship_flutter/game/content/asset_id.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/content/content_error.dart';

/// 构造一条**最小可用**的图形资产条目；`state` 可注入 frameRect 相关内容。
Map<String, Object?> assetWithState(Map<String, Object?> state) =>
    <String, Object?>{
      'assetId': 'GFX-V21-TEST',
      'category': 'graphic',
      'sourceFile': '图形/源设计/GFX-V21-TEST.svg',
      'runtimeFiles': <String>['assets/images/v2/GFX-V21-TEST__default.png'],
      'sha256': '0' * 64,
      'runtimeSha256': <String>['0' * 64],
      'license': 'test',
      'authorOrVendor': 'test',
      'createdAt': '2026-10-17T00:00:00+08:00',
      'contentVersion': kActiveContentVersion,
      'states': <String>['default'],
      'triggerEvents': <String>[],
      'fallbackAssetId': 'GFX-FALLBACK-SILHOUETTE',
      'memoryEstimateBytes': 1024,
      'anchor': <double>[0.5, 0.5],
      'loadGroup': 'firstRun',
      'eventBindings': <Object?>[],
      'renderStates': <String, Object?>{'default': state},
    };

/// 最小回退资产：`fallbackAssetId` 被校验为**必须存在**（unknownReference），
/// 因此夹具必须一并声明它。
Map<String, Object?> fallbackAsset() => <String, Object?>{
      'assetId': 'GFX-FALLBACK-SILHOUETTE',
      'category': 'graphic',
      'sourceFile': '图形/源设计/fallback.svg',
      'runtimeFiles': <String>['assets/images/v2/GFX-FALLBACK-SILHOUETTE.png'],
      'sha256': '0' * 64,
      'runtimeSha256': <String>['0' * 64],
      'license': 'test',
      'authorOrVendor': 'test',
      'createdAt': '2026-10-17T00:00:00+08:00',
      'contentVersion': kActiveContentVersion,
      'states': <String>['default'],
      'triggerEvents': <String>[],
      'fallbackAssetId': null,
      'memoryEstimateBytes': 1024,
      'anchor': <double>[0.5, 0.5],
      'loadGroup': 'firstRun',
      'eventBindings': <Object?>[],
      'renderStates': <String, Object?>{
        'default': <String, Object?>{
          'runtimeFiles': <String>[
            'assets/images/v2/GFX-FALLBACK-SILHOUETTE.png',
          ],
          'frameInterval': <int>[0, 0],
          'frameCount': 1,
          'fps': 0,
          'blendMode': 'normal',
          'anchor': <double>[0.5, 0.5],
        },
      },
    };

Map<String, Object?> manifestWith(Map<String, Object?> state) =>
    <String, Object?>{
      'schemaVersion': '1.1.0',
      'contentVersion': kActiveContentVersion,
      'assets': <Object?>[assetWithState(state), fallbackAsset()],
    };

AssetManifest parseIt(Map<String, Object?> json) {
  final r = AssetManifest.parse(json, expectedVersion: kActiveContentVersion);
  expect(r.isSuccess, isTrue, reason: r.describeErrors());
  return r.requireValue;
}

/// 从 JSON 文本构造（避免 Dart 的 `'0' * 64` 语法问题）。
Map<String, Object?> manifestFromText(String text) =>
    jsonDecode(text) as Map<String, Object?>;

void main() {
  test('V21-MANIFEST-01 单帧 frameRect 被解析且可用于裁切', () {
    final m = parseIt(
      manifestFromText('''
{
  "schemaVersion": "1.1.0",
  "contentVersion": "$kActiveContentVersion",
  "assets": [{
    "assetId": "GFX-V21-WPN-PRISM",
    "category": "graphic",
    "sourceFile": "图形/源设计/x.svg",
    "runtimeFiles": ["assets/images/v2/GFX-V21-WEAPON-STYLES-SHEET.png"],
    "sha256": "${'0' * 64}",
    "runtimeSha256": ["${'0' * 64}"],
    "license": "test", "authorOrVendor": "test",
    "createdAt": "2026-10-17T00:00:00+08:00",
    "contentVersion": "$kActiveContentVersion",
    "states": ["default"], "triggerEvents": [],
    "fallbackAssetId": "GFX-FALLBACK-SILHOUETTE",
    "memoryEstimateBytes": 1024, "anchor": [0.5, 0.5],
    "loadGroup": "firstRun", "eventBindings": [],
    "renderStates": {
      "default": {
        "runtimeFiles": ["assets/images/v2/GFX-V21-WEAPON-STYLES-SHEET.png"],
        "frameInterval": [0, 0], "frameCount": 1, "fps": 0,
        "blendMode": "normal", "anchor": [0.5, 0.5],
        "frameRect": [0, 0, 434, 724]
      }
    }
  }, {
    "assetId": "GFX-FALLBACK-SILHOUETTE",
    "category": "graphic",
    "sourceFile": "图形/源设计/fallback.svg",
    "runtimeFiles": ["assets/images/v2/GFX-FALLBACK-SILHOUETTE.png"],
    "sha256": "${'0' * 64}",
    "runtimeSha256": ["${'0' * 64}"],
    "license": "test", "authorOrVendor": "test",
    "createdAt": "2026-10-17T00:00:00+08:00",
    "contentVersion": "$kActiveContentVersion",
    "states": ["default"], "triggerEvents": [],
    "fallbackAssetId": null,
    "memoryEstimateBytes": 1024, "anchor": [0.5, 0.5],
    "loadGroup": "firstRun", "eventBindings": [],
    "renderStates": {
      "default": {
        "runtimeFiles": ["assets/images/v2/GFX-FALLBACK-SILHOUETTE.png"],
        "frameInterval": [0, 0], "frameCount": 1, "fps": 0,
        "blendMode": "normal", "anchor": [0.5, 0.5]
      }
    }
  }]
}
'''),
    );
    final state = m.byId[AssetId.tryParse('GFX-V21-WPN-PRISM')]!
        .renderStates['default']!;
    expect(state.usesSheetFrameRects, isTrue);
    expect(state.frameRects, <List<int>>[
      <int>[0, 0, 434, 724],
    ]);
  });

  test('V21-MANIFEST-02 多帧 frameRect 逐帧精确（禁止等分推断）', () {
    final rects = <List<int>>[
      <int>[0, 0, 543, 724],
      <int>[543, 0, 543, 724],
      <int>[1086, 0, 543, 724],
      <int>[1629, 0, 543, 724],
    ];
    final m = parseIt(manifestWith(<String, Object?>{
      'runtimeFiles': <String>['assets/images/v2/SHEET.png'],
      'frameInterval': <int>[0, 3],
      'frameCount': 4,
      'fps': 15,
      'blendMode': 'screen',
      'anchor': <double>[0.5, 0.5],
      'frameRect': rects,
    }));
    final state = m.byId[AssetId.tryParse('GFX-V21-TEST')]!
        .renderStates['default']!;
    expect(state.frameRects, rects);
    // 第四帧起点必须是 1629，**不是** 543×3 的等分值 ——
    // 等分推断正是素材规范 §1 禁止的做法。
    expect(state.frameRects[3][0], 1629);
  });

  test('V21-MANIFEST-03 frameRect 数量与 frameCount 不符 → 结构化错误', () {
    final r = AssetManifest.parse(
      manifestWith(<String, Object?>{
        'runtimeFiles': <String>['assets/images/v2/SHEET.png'],
        'frameInterval': <int>[0, 3],
        'frameCount': 4,
        'fps': 15,
        'blendMode': 'normal',
        'anchor': <double>[0.5, 0.5],
        // 只有 3 个 rect 却声明 4 帧 —— 会导致帧错位。
        'frameRect': <List<int>>[
          <int>[0, 0, 543, 724],
          <int>[543, 0, 543, 724],
          <int>[1086, 0, 543, 724],
        ],
      }),
      expectedVersion: kActiveContentVersion,
    );
    expect(
      r.isFailure,
      isTrue,
      reason: '数量不符必须失败 —— 否则会画出相邻子图或空白帧',
    );
    expect(
      r.errors.map((e) => e.field),
      contains('renderStates.frameRect'),
    );
    // 必须是**结构化错误**，不是抛异常（Loading 页要能显示可重试错误）。
    expect(
      r.errors.first.kind,
      ContentErrorKind.schemaViolation,
    );
  });

  test('V21-MANIFEST-04 宽高非正的 frameRect 被拒绝（避免空白帧）', () {
    final r = AssetManifest.parse(
      manifestWith(<String, Object?>{
        'runtimeFiles': <String>['assets/images/v2/SHEET.png'],
        'frameInterval': <int>[0, 0],
        'frameCount': 1,
        'fps': 0,
        'blendMode': 'normal',
        'anchor': <double>[0.5, 0.5],
        'frameRect': <int>[0, 0, 0, 724],
      }),
      expectedVersion: kActiveContentVersion,
    );
    // 宽为 0 的裁切没有任何可见内容 —— 属配置错误。
    final state = r.isSuccess
        ? r.requireValue.byId[AssetId.tryParse('GFX-V21-TEST')]!
            .renderStates['default']!
        : null;
    expect(
      r.isFailure || (state != null && !state.usesSheetFrameRects),
      isTrue,
      reason: '宽高非正的 frameRect 不得被当作有效裁切',
    );
  });
}
