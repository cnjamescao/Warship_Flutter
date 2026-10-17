// ================================================================
// test/unit/presentation/v21_frame_rect_render_test.dart —— V21-FX-00
// ================================================================
// **架构位置**：Presentation 层测试。验证 v2.1 的 **sheet 裁切**能力。
//
// **为什么必须有这一条**：v2.1 的素材是"**整张 sheet + frameRect**"
// （素材规范 §2），而 v2.0 的表现层只会画**整张图**。
// 若忘记裁切，画面会是**整张 2172×724 的 sheet 被缩小塞进敌人大小**——
// 玩家看到的是"一格一格的小图拼在一张纸上"。
//
// 这与我在 v2.0 犯过的"用画布高度当带宽导致 7 倍拉伸"是**同一类错误**
// （用整张图的尺寸代替内容的尺寸），因此这里逐帧锁死。
//
// 每条断言都能失败（R6.2）：把 src 换回整张图，本文件即失败。
// ================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:warship_flutter/game/content/asset_manifest.dart';
import 'package:warship_flutter/game/presentation/asset_cache.dart';

import '../../support/v2_harness.dart';

late VisualAssetCache cache;
late AssetManifest manifest;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final catalog = await loadV2CatalogForTests();
    manifest = catalog.manifest;
    cache = VisualAssetCache(manifest: manifest);
  });

  test('V21-FX-00a v2.1 sheet 素材逐帧返回**不同**的裁切矩形', () {
    // 五帧形态表：每帧 434×724（末帧 436×724）。
    const id = 'GFX-V21-WPN-PRISM';
    final r0 = cache.frameRectFor(id, 'default', 0)!;
    expect(r0, <int>[0, 0, 434, 724], reason: '首帧应从头开始');
    // **关键**：不同帧的起点必须不同 —— 否则画出来永远是同一格。
    final loaded = <String>{};
    for (var i = 0; i < 5; i++) {
      final r = cache.frameRectFor('GFX-V21-WPN-${
          ['PRISM', 'ARC', 'PLASMA', 'NEEDLE', 'MISSILE'][i]}', 'default', 0)!;
      loaded.add(r.join(','));
    }
    expect(loaded, hasLength(5), reason: '五个形态必须取到五张不同的格子');
  });

  test('V21-FX-00b 帧宽**远小于**整张 sheet 宽（这是裁切生效的判据）', () {
    // sheet 是 2172 宽；单帧只有 434 宽。
    // 若有人把 src 换回整张图，这条会立刻失败。
    final rect = cache.frameRectFor('GFX-V21-WPN-PRISM', 'default', 0)!;
    expect(rect[2], 434);
    expect(rect[2], lessThan(2172), reason: '帧宽必须小于 sheet 宽');
    // 高度等于 sheet 高（这些 sheet 是横向等分）。
    expect(rect[3], 724);
  });

  test('V21-FX-00c 越界帧号被夹紧，不抛异常', () {
    // 防止"帧号算错 → 崩溃"或"取到空白"。
    final r = cache.frameRectFor('GFX-V21-WPN-PRISM', 'default', 99)!;
    expect(r, isNotEmpty);
    expect(r[2], greaterThan(0));
    expect(cache.frameRectFor('GFX-V21-WPN-PRISM', 'default', -5), isNotNull);
  });

  test('V21-FX-00d v2.0 素材（无 frameRect）返回 null ⇒ 画整张图', () {
    // 保证既有素材行为不变（v2.1 不得污染 v2.0 的渲染）。
    expect(
      cache.frameRectFor('GFX-PLAYER-BASE', 'default', 0),
      isNull,
      reason: 'v2.0 的每帧一文件模型不应有 frameRect',
    );
    expect(cache.frameRectFor(null, null, 0), isNull);
    expect(cache.frameRectFor('NOT-EXIST', 'default', 0), isNull);
  });

  test('V21-FX-00e 四种动效序列的帧数与素材规范 §2 一致', () {
    // 护盾 4 帧；HP 受击 / 低血 / 濒危 / 击毁各 3 帧。
    expect(
      manifest.lookup('GFX-V21-PLAYER-SHIELD-HIT')!
          .renderStates['default']!
          .frameRects,
      hasLength(4),
    );
    for (final id in <String>[
      'GFX-V21-PLAYER-HP-HIT',
      'GFX-V21-PLAYER-LOW',
      'GFX-V21-PLAYER-CRITICAL',
      'GFX-V21-ENEMY-DESTROY',
    ]) {
      expect(
        manifest.lookup(id)!.renderStates['default']!.frameRects,
        hasLength(3),
        reason: '$id 应为三帧逐帧序列',
      );
    }
  });
}
