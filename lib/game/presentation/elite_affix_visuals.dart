// ================================================================
// lib/game/presentation/elite_affix_visuals.dart
//
// **架构位置**：Presentation（表现） —— **只读快照、只画画面**，不持有规则状态。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：表现不得影响规则 · 只用 manifest 绑定素材（禁用 Canvas 几何替代）。
// ================================================================
// F-21 裁决：「按 `EnemySpawned.isElite + affixId` **精确路由**，
// 外环亦改为**按词缀精确路由**。研发在精英头顶渲染名称条
// （文本仍从 key 读取）、词缀图标及对应外环。」
//
// 为什么必须按词缀路由：此前三个词缀的精英**画的是同一个金色圆**。
// 颜色在色弱场景下不可靠，而"这只精英是什么词缀"是**玩法信息**
// （加速会影响接近速度、护体会周期性加盾、弹幕会变密）——
// 玩法信息不能只靠颜色传达。
// ================================================================

/// 词缀 → 外环 / 图标 / 名称 key。
class EliteAffixVisual {
  const EliteAffixVisual({
    required this.affixId,
    required this.auraAssetId,
    required this.iconAssetId,
    required this.nameKey,
  });

  final String affixId;

  /// 词缀特有外环（`GFX-ELITE-AURA-*`）。
  final String auraAssetId;

  /// 词缀图标（`UI-ELITE-AFFIX-*`）。
  final String iconAssetId;

  /// 名称的字符串 key（**文本只来自 strings_zh_CN.json**，F-01 口径）。
  final String nameKey;
}

/// 精英名称条资源（按 `isElite` 路由）。
const String kEliteNameplateAssetId = 'UI-ELITE-NAMEPLATE';

/// 名称条运行时尺寸（素材规范：512×512 @2x → **220×44 logical px**）。
///
/// 规范明确「客户端不得修改、重绘或用文字替换以上资源；只按 manifest 接入」，
/// 因此尺寸取自规范而非自行估算。
const double kEliteNameplateWidth = 220;
const double kEliteNameplateHeight = 44;

/// 三个固定词缀（§6：词缀按固定顺序轮换，不抽样）。
///
/// 这张表与 `assets/config/v2/enemies.json` 的 `affixes` 一一对应；
/// **有测试交叉校验两者**，改一处忘了改另一处会失败。
const Map<String, EliteAffixVisual> kEliteAffixVisuals =
    <String, EliteAffixVisual>{
      'AFFIX-ACCEL': EliteAffixVisual(
        affixId: 'AFFIX-ACCEL',
        auraAssetId: 'GFX-ELITE-AURA-ACCEL',
        iconAssetId: 'UI-ELITE-AFFIX-ACCEL',
        nameKey: 'affix.accel',
      ),
      'AFFIX-SHIELD': EliteAffixVisual(
        affixId: 'AFFIX-SHIELD',
        auraAssetId: 'GFX-ELITE-AURA-SHIELD',
        iconAssetId: 'UI-ELITE-AFFIX-SHIELD',
        nameKey: 'affix.shield',
      ),
      'AFFIX-BARRAGE': EliteAffixVisual(
        affixId: 'AFFIX-BARRAGE',
        auraAssetId: 'GFX-ELITE-AURA-BARRAGE',
        iconAssetId: 'UI-ELITE-AFFIX-BARRAGE',
        nameKey: 'affix.barrage',
      ),
    };

/// 按词缀取外观。未知词缀返回 null（**默认不画**，不猜）。
EliteAffixVisual? eliteAffixVisualFor(String? affixId) =>
    affixId == null ? null : kEliteAffixVisuals[affixId];
