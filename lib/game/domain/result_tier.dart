// ================================================================
// lib/game/domain/result_tier.dart —— 结算奖牌
//
// **架构位置**：Domain（纯规则） —— 无 I/O、无 Flutter 依赖、不持有渲染状态；由 `GameRuntime` 驱动，
//   产出**意图/事件**，不直接改动 Core 的实体集合。
//
// **与谁交互**：上游见各方法文档；下游产出为**不可变**数据或端口调用。
//
// **关键约束**：确定性（同 seed + 同输入必同结果）· 表现无关（不得因"要画什么"改变规则）。
// ================================================================
// ⚠️ 本文档记录了一处**已裁决的文档冲突**，实现依据如下。
//
// 两份文档对结算奖牌的算法不一致：
//
//   * 产品基线 §8（第 239 行）：
//     「结算评价：胜利为 Gold；Boss HP ≥35% 的失败为 Silver；
//       其余为 Bronze。只显示成绩，不提供局外战力或抽奖。」
//
//   * 技术协议 §3.1（第 93 行）：
//     「UI-RESULT-MEDAL 的 resultTier 算法固定如下，避免结算素材无来源：
//       胜利为 gold；失败但曾进入 Boss P3（bossHpRatio < 0.35）为 silver；
//       失败、存活时间 ≥120 秒为 bronze；其余为 none。
//       优先级依次为 gold > silver > bronze > none。」
//
// **裁决依据**：`Spec/开发者交付清单.md` §8 明文规定
//   「若文档之间出现冲突，按以下优先级处理：
//     产品基线 → 技术协议 → 素材规范/manifest → 产品交互文档」
// 因此**产品基线优先**。
//
// 逐项对照后的取舍：
//
// | 情形 | 产品基线 | 技术协议 | 本实现采用 |
// | --- | --- | --- | --- |
// | 胜利 | Gold | gold | **gold**（一致） |
// | 失败且把 Boss 打进 P3 | 未细分 | silver | **silver** |
// | 失败且 Boss 仍在 P3 之前 | 未细分 | bronze（存活≥120s）/ none | **bronze** |
//
// 两处取舍的理由：
//
// 1. **阈值方向**采用技术协议的读法。产品基线只给了「Boss HP ≥35%」
//    这个片段，没说方向；若按字面「剩余 HP ≥35% 才给 Silver」，
//    则**打得越差奖牌越好**，与它自己的档位排序（Silver > Bronze）
//    自相矛盾。技术协议给了显式算法且方向自洽，故以它解释产品基线。
//
// 2. **`none` 不再产生**。产品基线说「其余为 Bronze」，
//    即铜牌是兜底；技术协议把「存活 <120 秒」的情形给 `none`。
//    两者直接冲突，而 §8 规定产品基线优先 —— 故本实现**不产生 `none`**。
//
//    注意：素材包 `UI-RESULT-MEDAL` 仍声明 `none` 状态（共 4 个），
//    它现在是**声明但不可达**。这不影响资源校验（校验的是"声明的状态
//    都有映射"，不要求全部可达），但如果后续要启用它，
//    只需改本文件的 `resultTierFor` 一处。
// ================================================================

/// 结算奖牌档位。
///
/// 取值与素材 `UI-RESULT-MEDAL` 声明的状态名一致
/// （`gold` / `silver` / `bronze` / `none`）。
enum ResultTier {
  gold,
  silver,
  bronze,

  /// 素材包声明了该状态，但按当前裁决的算法**不会产生**。
  /// 保留是为了让枚举与素材状态一一对应，便于将来启用。
  none;

  String get id => name;
}

/// Boss 进入 P3 的阈值（产品基线 §7.2 / 技术协议 §3.1 一致）。
const double kSilverBossHpThreshold = 0.35;

/// 计算结算奖牌。
///
/// 算法（见文件头的裁决记录）：
///   1. 胜利 → `gold`
///   2. 失败且 `bossHpRatio < 0.35`（曾把 Boss 打进 P3）→ `silver`
///   3. 其余失败 → `bronze`
///
/// [bossHpRatio] 必须是**该局结束时的真实值**；
/// Boss 尚未出现时传入 `null`（或 1.0），按"未进 P3"处理。
///
/// 该函数必须是**纯函数** —— 技术协议要求该值「必须在写入 `RunEnded`
/// 前计算，且重放中可复现」，因此不得依赖时钟、随机数或外部状态。
ResultTier resultTierFor({
  required bool victory,
  required double? bossHpRatio,
}) {
  if (victory) {
    return ResultTier.gold;
  }
  final ratio = bossHpRatio;
  if (ratio != null && ratio < kSilverBossHpThreshold) {
    return ResultTier.silver;
  }
  return ResultTier.bronze;
}
