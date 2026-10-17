# v2.1 一线实施冻结表

> 状态：**当前生效的实施口径冻结表。** 本文补足本目录产品文档、`Spec/02_技术/v2.1/` 和 `Spec/03_素材/v2.1/` 的执行细节；同一主题冲突时，以本文为准。研发只需按本文、既有 v2.0 保留配置和 v2.1 素材包实现，无需再向产品确认玩法选择。

## 1. 固定范围与版本边界

- v2.1 manifest/config `contentVersion`：`2.1.0-neon-flow`。
- 只变更升级授予流程、风险门结算流程、清场胜利、HUD 目标/提示、主弹道形态、表现层与结算奖章；离线/无登录、敌人波次、Boss 招式和 v2.0 基础数值均不重做。**[变更 v2.1-R2] 风险门不再保留玩家选项。**
- 现有 `assets/config/v2/upgrades.json` 的 16 张基础卡的名称、说明、前置、互斥、最大等级、效果和权重**原样继承**；不要复制后重新平衡。v2.1 仅新增本表 §3 的五张主弹道形态卡。
- 所有 v2.1 新 ID、中文文案与 manifest 条目在新版本配置中新增，不覆盖 v2.0 已发布资源或配置。

## 2. 自动强化的精确规则

### 2.1 触发点

| 项 | 冻结值 |
| --- | --- |
| 累计 XP 阈值 | `20 / 55 / 105 / 170 / 250 / 345` |
| 首次可触发时间 | 逻辑战斗时间 `>= 15.0s`；此前 XP 保留，不补发多张 |
| 一局最大自动强化次数 | `6`；达到后 XP 仍计分但不再授予 |
| 触发相位 | 仅 `Playing`；`Paused`、`RiskGate`、`Result`、`Loading` 不消费触发 |
| 结算顺序 | 采用 `05` §3 的固定步顺序；同一逻辑步先应用强化，再构建 `ThreatSnapshot` |

### 2.2 抽取和保证规则

`grantOrdinal` 从 0 开始，且必须作为快照/回放状态保存。每次只授予一张，直接调用现有 `applyCard` 一次，发出 `AutoUpgradeGranted`；**禁止创建 `DraftOffer`、进入 `UpgradeDraft` 或等待输入。**

| `grantOrdinal` | 选取规则 | 计入伤害干旱计数 |
| ---: | --- | --- |
| 0 | 强制 `UP-PULSE-RATE` | 是 |
| 1 | 在可用的 `UP-PULSE-SPREAD`、`UP-MISSILE-UNLOCK` 中按既有 `RandomSource` 加权抽一张；仅剩一张时取该张 | 是 |
| 2 | 若尚无主弹道形态，强制进入 §3 的五种形态池，等权抽一张 | 是 |
| 3–5 | 使用现有可用卡过滤（满级、双向互斥、前置、`weight>0`）；如连续两次未取得伤害类，则优先在既有 `damageCardIds` 中加权抽一张；否则在“已拥有系列或 survival”可用卡中加权抽一张；该集合为空时退回完整可用池加权抽取 | 按 `damageCardIds` 或形态卡的 `countsAsDamage=true` 更新 |

- 若一个强制集合在内容错误下为空，测试必须失败并打印 `grantOrdinal` 与可用 ID；Release 记录阻断诊断，禁止悄悄跳过。
- 第三次形态卡取代原 v2.0 “第三次及以后偏好已拥有/生存系列”的该**单次**保证；第 4–6 次恢复该偏好。
- **[变更 v2.1-R2]** 风险门不保留玩家选择：触发即在当前合法结果中等权确定性抽取一项，代价与收益在同一逻辑步原子生效；若结果为稀有强化，只授予一张确定性抽出的合法稀有卡，不得额外打开草案。

### 2.3 可见反馈与历史

| 结果类型 | 立即反馈 | 结算/暂停历史 |
| --- | --- | --- |
| 任意自动强化 | `UI-V21-AUTO-UPGRADE-EMBLEM`；无文字、无卡片、无边框；本帧后的状态/武器变化必须可见 | 按中文名称、等级、说明逐行显示 |
| 自动风险：Supply / Bounty / Overload | 分别为 `UI-V21-RISK-SUPPLY-EMBLEM` / `UI-V21-RISK-BOUNTY-EMBLEM` / `UI-V21-RISK-OVERLOAD-EMBLEM`；无文字、无卡片、无边框 | 按 gate、结果、代价、收益与生效时间逐行显示 |

结果徽记固定在逻辑设计基准 `1920×1080` 的右上安全区：外接目标区域 `left=1728, top=28, width=132, height=176`，实际图形按源图纵横比 contain 绘制；这里不是可见卡片或点击区域。小于该宽度的视口等比缩放且距右/上至少 24 logical px。时序固定为 `90ms` 弹出、`580ms` 停留、`330ms` 收束，总 `1000ms`。并发事件按产生顺序进入单一结果队列，前项结束后才显示后项；队列不暂停战斗、不丢事件。视觉层无文字；语义标签分别为：`获得强化：{name}，等级 {level}，{description}`、`风险结果：{name}，{effect}`。

### 2.4 风险门自动结算【新增 v2.1-R2】

`risk_gates.json` 仅保留门的秒数、条件、效果和 ID；其 UI 选择字段必须删除或标为不再消费。`selectionWindowSeconds`、`timeoutFallbackId`、`clickOutsideCountsAsTimeout`、`freezesAllLogicClocks`、`stopNewEnemySpawns`、`clearNormalEnemyBulletsBefore` 都不得参与 v2.1 正常对局。每个 gate 到时：

| gateId | 合法候选与抽取 | 同步结果 |
| --- | --- | --- |
| `RG-55` / `RG-115` | 按 `runSeed + gateId + occurrenceOrdinal` 从合法项等权取 1；`RG-OVERLOAD` 只在 `playerHp > 35` 合法 | `RG-SUPPLY`：shield +20、HP +8；`RG-BOUNTY`：下一固定精英 Core 额外掉落且 HP×1.25；`RG-OVERLOAD`：从 `UP-CRIT-ARC`、`UP-MISSILE-SALVO`、`UP-LASER-PRISM`、`UP-DRONE-COUNT`、`UP-DASH-REPAIR` 中确定性授予**一张**，并施加最终伤害×1.15、20s |

抽取必须由 `RandomSource` 的带标签固定调用实现，不得按 UI、帧率、暂停或渲染重试改变；同时保存 `gateId`、`occurrenceOrdinal`、`optionId`、应用后的状态与 `resultNoticeOrdinal` 到回放快照。没有合法项属于内容配置错误，测试失败、Release 阻断。

## 3. 五种主弹道形态

五张卡仅能拥有一张，均 `maxLevel=1`、`weight=20`、`series=mainStyle`、相互 `excludes`、`countsAsDamage=true`。它们仅改变基础 `WPN-PULSE` 的主弹道渲染/发射规则；不覆盖既有 `WPN-MISSILE`、Laser 或 Drone 的独立解锁，避免“Missile”形态和原导弹副武器混淆。

| cardId / styleId / 中文名 | 核心参数 | 弹体尺寸（logical px） | 命中特效尺寸 | 音频 |
| --- | --- | ---: | ---: | --- |
| `UP-WSTYLE-PRISM` / `prism` / 棱晶脉冲 | damage×1.00、speed×0.95、radius×1.00、额外穿透 1 | 16×38 | 72×72 | `SFX-V21-WPN-PRISM-IMPACT` |
| `UP-WSTYLE-ARC` / `arc` / 电弧脉冲 | damage×0.82、speed×1.00、radius×0.90、一次弹跳 | 22×46 | 80×80 | `SFX-V21-WPN-ARC-IMPACT` |
| `UP-WSTYLE-PLASMA` / `plasma` / 等离子脉冲 | damage×1.22、speed×0.78、radius×1.35、无穿透/追踪、`impactDamageRadius=84` | 42×42 | 96×96 | `SFX-V21-WPN-PLASMA-IMPACT` |
| `UP-WSTYLE-NEEDLE` / `needle` / 针束脉冲 | damage×0.72、speed×1.48、radius×0.62、额外穿透 2 | 10×54 | 60×60 | `SFX-V21-WPN-NEEDLE-IMPACT` |
| `UP-WSTYLE-MISSILE` / `missile` / 微导弹脉冲 | damage×1.08、speed×0.86、radius×1.05、最近合法敌人追踪 | 20×46 | 92×92 | `SFX-V21-WPN-MISSILE-IMPACT` |

- 无合法目标时 `UP-WSTYLE-MISSILE` 直线飞行；不得消耗额外随机数、创建新敌人或改变既有副武器锁定。
- `impactDamageRadius`：Prism / Arc / Needle / Missile 固定为 `0` logical px；Plasma 固定为 `84` logical px。Plasma 直接命中目标承受 `effectiveDamage`；半径内最多 4 个其他合法敌人按距离、`EntityId` 稳定排序，各承受 `floor(effectiveDamage×0.55)`；直接目标不重复受伤，玩家、拾取物和已移除实体永不入选。
- 弹体和命中特效 Asset ID 固定采用 `05` §4.3/`08` §2 的同名 `GFX-V21-WPN-*`。各形态继续使用既有基础射击 cue；本表 cue 是**命中** cue，不是另一个开火 cue。
- 每张形态卡的配置固定补充：`prerequisites=[]`、`iconAssetId="UI-V21-AUTO-UPGRADE-EMBLEM"`、`rarity="rare"`、`effects=[{kind:"grantMainWeaponStyle",styleId:"<对应 styleId>"}]`。该字段仅供暂停/结算历史与语义使用；战斗内统一显示无文字结果徽记，不借用旧 `UI-UP-*` 资源。

### 3.1 新增本地化 key

以下为 v2.1 必须新增的简体中文原文；花括号参数名不可改变。既有 16 张基础卡继续读取 v2.0 的现有 `nameKey`/`descKey`。

| key | 简体中文值 |
| --- | --- |
| `objective.sectorClear` | `扇区已清空` |
| `toast.upgradeAria` | `获得强化：{name}，等级 {level}，{description}` |
| `up.style.prism.name` / `up.style.prism.desc` | `棱晶脉冲` / `棱晶分束，额外穿透 1 个目标` |
| `up.style.arc.name` / `up.style.arc.desc` | `电弧脉冲` / `电弧弹跳 1 次，伤害略低` |
| `up.style.plasma.name` / `up.style.plasma.desc` | `等离子脉冲` / `大范围等离子核心，弹速较慢` |
| `up.style.needle.name` / `up.style.needle.desc` | `针束脉冲` / `高速针束，额外穿透 2 个目标` |
| `up.style.missile.name` / `up.style.missile.desc` | `微导弹脉冲` / `锁定最近敌人，爆裂范围更大` |
| `objective.timeLimit` | `作战时限已到` |

## 4. 清场、目标 HUD 与结果流

| 条件 | HUD `objective` 文案 key / 传参 | 是否允许清场 |
| --- | --- | --- |
| `combatSeconds < 145` | `objective.survive`, `seconds=ceil(150-combatSeconds)` | 否 |
| `145 ≤ combatSeconds < 150` 且 Boss 未入场 | `objective.bossIncoming` | 否 |
| Boss 已入场且 `bossAlive` | `objective.defeatBoss` | 否 |
| §5 ThreatSnapshot 全部清空的 0.8s 确认窗 | 新增 `objective.sectorClear` = “扇区已清空” | 尚未；新威胁立即取消 |
| 确认窗结束 / Boss HP=0 | 进入 Result；不再显示倒数 | 是（原子结果） |

顶部中间从 v2.1 起不得显示 `190-combatSeconds` 或裸数字。新增状态字段 `HudView.objectiveKey`、`objectiveArgs`、`isSectorClearConfirming`；UI 只能从这些字段显示文案，不能自行根据时间猜测。

## 5. 表现、降级与奖章的精确规则

### 5.1 实体锚点、尺寸和逐帧运行

| ID | anchor | 目标尺寸 | 帧/时序 | blend / 并发 |
| --- | --- | --- | --- | --- |
| Shield hit | 玩家中心 `(0.5,0.5)` | 168×168 | 4 帧，0/67/134/201ms，267ms 销毁 | `screen`，最多 2 |
| HP hit | 玩家中心 | 144×144 | 3 帧，0/100/220ms，320ms 销毁 | `additive`，80ms 合并，最多 2 |
| Low | 玩家中心 | 180×180 | 3 帧，0/300/600ms，1200ms 循环 | `screen`，仅 1 |
| Critical | 玩家中心 | 184×184 | 3 帧，0/200/400ms，800ms 循环 | `additive`，仅 1 |
| Enemy destroy | 敌人中心 | `clamp(entityRadius×4.2, 90, 216)` 正方形 | 3 帧，0/140/280ms，420ms 销毁 | `additive`，最多 12 |

`reduceMotion=true` 时，护盾/HP/击毁保留中间峰值帧 160ms；低血/濒危保留其第一帧，每 1.2s/0.8s 仅闪现 120ms。状态、可访问性文本、碰撞、伤害、时钟、粒子预算与音频触发完全不变。

### 5.2 奖章入场

| tier | asset/cue | 时间轴 |
| --- | --- | --- |
| Gold | `UI-V21-RESULT-MEDAL-GOLD` / `SFX-V21-MEDAL-GOLD` | 0–180ms scale 0.60→1.12、rotation -10°→0°；180–500ms scale 1.12→1.00，星芒 opacity 0→1 |
| Silver | `UI-V21-RESULT-MEDAL-SILVER` / `SFX-V21-MEDAL-SILVER` | 0–160ms xScale 0.15→1.05；160–420ms xScale 1.05→1.00、opacity 0.75→1 |
| Bronze | `UI-V21-RESULT-MEDAL-BRONZE` / `SFX-V21-MEDAL-BRONZE` | 0–180ms y +32→0、scale 0.75→1.05；180–380ms scale 1.05→1.00 |

三者普通 alpha 合成，不可用 `additive` 覆盖结果文字；统一锚点为结果卡中心，目标 192×192 logical px。`reduceMotion=true` 时只显示最终帧并播放对应 cue。

### 5.3 音频运行时合同

所有新 cue 路由至既有 SFX 总线、全局 SFX 设置关闭时静音。初始相对增益：盾/HP `-5dB`，强化 `-7dB`，清场 `-6dB`，奖章 Gold/Silver/Bronze `-5/-6/-7dB`，五种命中 `-10dB`。同一命中 cue 的合并窗 80ms、最多 2；盾/HP 同类最多 2；清场、奖章和强化提示各最多 1。数值在音效师试听签收前不可作为发布响度结论。

## 6. 必测实现用例补充

| ID | 固定输入 | 精确断言 |
| --- | --- | --- |
| V21-AU-03 | 固定 seed，XP 依次跨 20/55/105/170/250/345，逻辑时间 15s 后推进 | 获得 6 张；第 1 张是 Pulse Rate；第 2 张仅来自两张保证卡；第 3 张仅来自五种形态；全程 `phase=Playing` |
| V21-AU-04 | 每种空池条件、满级、互斥、前置不满足 | 断言打印不可用原因并失败；不得静默跳过、不得产生 Draft |
| V21-HUD-01 | 0/145/150 秒、Boss 存活、清场确认 | 分别仅显示 §4 的 key；不存在裸剩余倒数；Toast 命中穿透且 aria 文案完整 |
| V21-STYLE-02 | 每种 style 对同一敌人 fixture 发射 1 发 | 尺寸、规则参数、图/命中图/cue 和锁定逻辑与 §3 完全匹配 |
| V21-FX-03 | 每项状态 t=0、峰值、结束；`reduceMotion` true/false | frameRect/尺寸/锚点/时钟、暂停冻结、并发数与 §5 一致 |
| V21-MEDAL-02 | 三种 tier 和 reduceMotion 两种设置 | 各自 Asset、cue、时间轴/最终态精确匹配；结果判定不变 |

## 7. 实施顺序与交付门禁

1. **B0/P0**：新增 config/manifest/localization/DTO/快照字段，先通过 V21-AU-03、V21-HUD-01 与素材 hash 检查。
2. **B1/P0**：替换标准升级触发、风险门自动结算与清场状态机，删除所有玩法性 `UpgradeDraft` / `RiskGate` 选择路径。
3. **B2/P1**：实现五形态和其资源路由，完成 V21-STYLE-01/02。
4. **B3/P1**：实现状态动效、提示和奖章，完成 V21-FX-01/02/03、V21-MEDAL-01/02。
5. **B4/P0**：完整回归、Golden、Code Review、真实 Release 试听/录屏；任何素材、文案、路径或注释未闭环都不可发布。

