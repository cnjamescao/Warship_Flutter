// ================================================================
// test/unit/presentation/entity_vs_event_visual_test.dart —— F-28 / F-31
// ================================================================
// 这一整类缺陷的共同点：**把"事件视觉"当成"实体外观"**。
//
//   * F-28：`_drawEnemies` 用 `route?.assetId ?? enemy.assetId`
//           → 敌机身上刚发生过事件（预警/受击）时，机体被换成那个
//             事件的资源；解析不出图就退回程序化图形
//             （玩家看到的"三角形 / 五边形"）。
//   * F-31：`_drawPlayer` 同样写法
//             → **一被打中，战舰就被换成 `GFX-PLAYER-SHIELD-HIT`**，
//               而不是"机体 + 闪光叠层"（玩家："被击中没效果，
//               子弹像穿透过去"）。
//
// 正确语义：**实体外观来自配置**（`bodyAssetId` / 机体素材），
// **事件视觉只作为叠层**。本文件守住这条分工 ——
// 它是一条**静态检查**，所以不会再出现"我只修了敌机、忘了玩家"。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('F-28/F-31 实体外观不得用事件路由作为来源', () {
    final source = File(
      'lib/game/presentation/warship_v2_game.dart',
    ).readAsStringSync();

    // 反面模式：`route?.assetId ?? ...` 出现在实体绘制处。
    // 允许 `route` 只用于**叠层**（先画实体、再用 route 补一层）。
    final offenders = <String>[];
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // ⚠️ 跳过注释：本文件的说明里就**引用了**被禁止的写法，
      // 不跳过的话静态检查会报它自己（我第一版就是这样）。
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//')) {
        continue;
      }
      if (line.contains('route?.assetId ??') ||
          line.contains('playerRoute?.assetId ??') ||
          line.contains('playerRoute?.renderState ??')) {
        // `?? enemy.assetId` / `?? player.assetId` 正是被禁止的写法：
        // 它让事件资源**优先于**实体外观。
        offenders.add('第 ${i + 1} 行：${line.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '实体外观被事件路由覆盖了 —— 这会让"身上刚发生过事件的实体"'
          '被换成事件的资源（F-28 的三角形/五边形、F-31 的战舰被换掉）。\n'
          '正确做法：实体只取配置里的外观；事件视觉另画一层叠层。\n'
          '违规处：\n${offenders.join('\n')}',
    );
  });

  test('F-31 玩家受击表现确实作为叠层绘制（存在独立的一次绘制）', () {
    final source = File(
      'lib/game/presentation/warship_v2_game.dart',
    ).readAsStringSync();

    // 机体绘制必须用玩家自己的 assetId。
    expect(
      source.contains('player.assetId,'),
      isTrue,
      reason: '玩家机体应取 `player.assetId`（配置里的正式机体素材）',
    );
    // 受击表现必须另有一次绘制（叠层），而不是替换机体。
    expect(
      source.contains('playerRoute'),
      isTrue,
      reason: '受击表现应以叠层形式存在（否则被击中就没有任何画面反馈）',
    );
  });
}
