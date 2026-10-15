// ================================================================
// lib/game/presentation/colorblind_patterns.dart
// ================================================================
// F-12 裁决（选 B）：
//   「**不新增色弱模式开关**；所有关键状态**默认**提供颜色外第二识别维度。
//     危险/低血使用 `UI-COLORBLIND-PATTERN-DANGER` 的三角斜线；
//     奖励/补给使用 `...-REWARD` 的菱形加号；稀有度使用 `...-RARITY`
//     的同心圆十字。预警还必须保留几何形状/动态收缩；精英词缀使用
//     独立图标；**文本不能是唯一第二维度**。上述叠层**始终显示**，
//     不依赖设置。」
//
// 这个模块存在的意义：把"颜色之外还有第二维度"这件事集中到一处，
// 而不是散落在各个绘制分支里 —— 后者容易出现"某个状态忘了加"。
// ================================================================

/// 语义类别 → 色弱叠层资源 ID。
///
/// **刻意不提供"关闭"的入口**：裁决明确"不新增开关、始终显示"。
/// 没有开关，就不会有"用户忘了打开、于是只靠颜色"这种失败模式。
enum ColorblindPattern {
  /// 危险 / 低血：三角斜线。
  danger('UI-COLORBLIND-PATTERN-DANGER'),

  /// 奖励 / 补给：菱形加号。
  reward('UI-COLORBLIND-PATTERN-REWARD'),

  /// 稀有度：同心圆十字。
  rarity('UI-COLORBLIND-PATTERN-RARITY');

  const ColorblindPattern(this.assetId);

  /// 运行时素材 ID。
  final String assetId;

  /// 该叠层**始终显示**，不受任何设置影响。
  ///
  /// 写成常量而不是读取设置，是为了让"它依赖设置"这件事
  /// **在类型层面就做不到**。
  static const bool alwaysVisible = true;
}

/// 玩家语义状态 → 第二识别维度。
///
/// 返回 null 表示该状态**不需要**第二维度（例如"玩家满护盾"这种
/// 纯装饰状态）。**关键状态一律不得返回 null** —— 这由测试守住。
ColorblindPattern? patternForPlayerVital({required double hpRatio}) {
  // 低血与濒危都属于"危险"，用同一套三角斜线。
  if (hpRatio <= 0.35) {
    return ColorblindPattern.danger;
  }
  return null;
}

/// 敌人/攻击的危险区是否需要三角斜线叠层。
///
/// 裁决要求预警"**保留几何形状/动态收缩**"——即除了颜色，
/// 形状本身（圆、线、扇形）与收缩动画就是第二维度。
/// 返回 true 时表示还应叠加图案，使它在**灰度下**也能被认出。
bool hazardNeedsDangerPattern({
  required bool isWarning,
  required bool dealsDamage,
}) {
  // 会造成伤害的危险区（含生效前后）都算危险。
  return dealsDamage || isWarning;
}

/// 奖励/补给（掉落、精英核心、风险门补给）需要菱形加号。
bool pickupNeedsRewardPattern({required bool isPickup}) => isPickup;

/// 稀有度（升级卡的稀有档）需要同心圆十字。
bool draftCardNeedsRarityPattern({required bool hasRarity}) => hasRarity;
