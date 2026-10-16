# 《Warship：霓虹最后防线》v2.0 素材清单与制作规范

| 项目 | 内容 |
| --- | --- |
| 版本 | v2.0.7 全量素材审计版，唯一生效素材规范 |
| 更新日期 | 2026-10-16 |
| 适用对象 | UI/游戏美术、TA、音频设计、客户端、QA、构建工程师 |
| 上游规则 | [v2.0 研发交付基线](../01_产品/Warship_v2.0研发交付基线.md)、[运行时与数据协议](../02_技术/v2.0/02_运行时与数据协议.md) |
| 覆盖范围 | 横屏 1920×1080、离线 Web 优先版本的全部运行时图形、音频、字体和元数据 |

> 本文覆盖并替代旧版《素材总清单与制作规范》中所有 v2.0 运行时要求。旧版仅保留历史原型与概念参考价值。素材名称中的 Asset ID 是代码和配置唯一允许引用的稳定标识；文件路径可版本化，但 Asset ID 不可改名或复用。

## 1. 交付状态与目录

`Spec/03_素材/` 中仅保留 v2.0 正式素材规范；概念样张、旧原型 WAV 和旧清单均在 `Spec/99_历史归档/`，不可作为实现依据。正式 v2.0 发布包位于仓库根目录的 [`素材/`](../../素材/README.md)：其根 `manifest.json` 含 197 条记录（127 图形/UI、67 个物理音频、1 个静默逻辑回退、2 字体声明），运行时仅可读取 manifest 显式引用的 `图形/运行时PNG/` 和 `音频/运行时MP3/` 文件。发布前必须通过 `validate_release_manifest.py`、`validate_audio_mix.py`、`validate_visual_state_assets.py` 三项门禁；`图形/*ATLAS.png`、`图形/源SVG/` 和原型文件只用于美术迭代，不可在运行时直接引用。

~~~text
Spec/素材/
├── Warship_v2.0素材清单与制作规范.md
├── 图形/
│   ├── UI界面/HUD/            # UI-* HUD 源文件、SVG、导出
│   ├── UI界面/菜单与弹窗/     # UI-HOME/DRAFT/RISK/PAUSE/RESULT
│   ├── 角色与敌机/            # GFX-PLAYER/ENEMY/BOSS
│   ├── 投射物与预警/          # GFX-PROJECTILE/WARNING/PICKUP
│   ├── 战斗特效/              # GFX-FX
│   ├── 场景背景/              # GFX-BG
│   └── 概念样张/              # 不可直接用于发布
└── 音频/
    ├── 当前原型基线/          # 不可直接用于发布
    └── 待制作/                # SFX/BGM 正式候选
~~~

运行时导出由工程复制至 `assets/images/v2/`、`assets/audio/v2/`；内容配置通过 Asset ID 查 `manifest`，不允许在代码中硬写素材路径。

### 1.1 ID 展开与运行时接入约定（强制）

本文件表格中的斜杠为紧凑写法，表示共享前缀的**多个独立 Asset ID**，不是一个可被代码引用的组 ID。例如 `GFX-WPN-LASER-HEAD/BEAM/IMPACT` 必须在 manifest 中展开为 `GFX-WPN-LASER-HEAD`、`GFX-WPN-LASER-BEAM`、`GFX-WPN-LASER-IMPACT` 三条记录；`SFX-PLAYER-PULSE / PULSE-CRIT / PULSE-HIT` 依次展开为 `SFX-PLAYER-PULSE`、`SFX-PLAYER-PULSE-CRIT`、`SFX-PLAYER-PULSE-HIT`。斜杠后的词继承其左侧最近的完整前缀。不得提交只有“组名”而没有可解析独立 ID 的 manifest。

每条图形记录还必须提供 `renderStates`（状态 → runtimeFiles/帧区间）、`anchor`、`loadGroup`（`firstRun`/`boss`/`lazy`）、`fallbackAssetId` 与 `eventBindings`；每条音频记录还必须提供 `cueId`（与 `AudioCue` 一一对应）、`eventBindings`、总线、`loadGroup` 及 §4 的并发规则。`eventBindings` 是唯一允许消费的精确路由：每项包含 `event`、`when` 条件及图形的 `renderState`；`triggerEvents` 仅为该列表的去重索引，绝不可独立用于选择资源。`ContentCatalog` 只保存 Asset ID，`PresentationSystem` 根据本规范第 5.1 节和 `eventBindings` 将 DomainEvent 转为 `renderState`/`cueId`；两者均不得猜测文件名或用显示文本查资源。

`when` 为空仅允许用于没有可区分参数的生命周期事件（例如 `DashStarted`）；敌机攻击 binding 必须同时填写 `enemyId` 与 `attackId`，Boss 攻击 binding 必须填写 `attackId`。`transientMs` 表示临时状态持续时间；出现 `restoreFromSnapshot=true` 时，时长结束必须恢复最后一份数值/防御状态，不能凭素材文件名推断。多状态图形的每个 `states` 项必须至少有一条绑定；发布校验器会拒绝不完整或宽泛攻击绑定。

正式构建中所有必需资源均须真实存在；`fallbackAssetId` 只用于单项加载失败时维持可玩性，不能掩盖发布前的缺失资源。统一回退为 `GFX-FALLBACK-SILHOUETTE`（中性、无伤害含义的轮廓）、`UI-FALLBACK-ICON`（中性轮廓）及静默 `SFX-FALLBACK-SILENT`（逻辑 no-op，不生成音频文件）。三者必须有 manifest 记录；`content_validate` 在发布模式仍须把任何必需资产回退记录判为失败。

### 1.2 v2.0.6 敌机与音频修复接入（2026-10-15，历史修复批次）

**该批次版本为 `2.0.6-material-repair`，已被当前 `2.0.7-material-audit` 包含。**
一线研发不得继续缓存、复制或加载
v2.0.5 的敌机或音效副本。运行时唯一依据仍是根目录 `素材/manifest.json`；应用侧同步副本
为 `assets/config/v2/manifest.json`、`assets/images/v2/` 与 `assets/audio/v2/`。

| Asset ID | 权威源图 | 必须加载的状态文件 | 研发接入结论 |
| --- | --- | --- | --- |
| `GFX-EN-SCOUT` | `素材/图形/角色与敌机/GFX-EN-SCOUT.png` | idle / hit / critical / destroy | 窄体侦察机，青色传感核心 |
| `GFX-EN-WING` | `素材/图形/角色与敌机/GFX-EN-WING.png` | idle / hit / critical / destroy | 宽翼蝠鲼轮廓，琥珀核心 |
| `GFX-EN-SNIPER` | `素材/图形/角色与敌机/GFX-EN-SNIPER.png` | idle / charge / hit / critical / destroy | 竖向长炮管机体；`charge` 仅用于蓄力 |
| `GFX-EN-BOMBER` | `素材/图形/角色与敌机/GFX-EN-BOMBER.png` | idle / drop / hit / critical / destroy | 厚重四引擎轰炸机；`drop` 仅用于投放 |
| `GFX-EN-SHIELD` | `素材/图形/角色与敌机/GFX-EN-SHIELD.png` | body / frontShield / hit / critical / destroy | 实体舰体加正面屏障；不可用通用盾牌 UI 代替 |

实施动作只有以下四项，均由研发完成，**不得重新绘制、改名、补造或猜测路径**：

1. 构建时把当前 `素材/manifest.json` 和 manifest 所列运行时文件同步至应用资源目录，并覆盖旧副本；不得只复制五张源图或只复制图形不复制音频。
2. 敌机渲染仅按 `Asset ID → renderStates → runtimeFiles` 解析。Sniper 的蓄力和 Bomber 的投放必须分别请求 `charge`、`drop`，Shield 的正面减伤必须请求 `frontShield`；其余时机不得复用这些状态。
3. 禁止以旧 `图形/源SVG/战斗特效/GFX-EN-*.svg`、`GFX-FALLBACK-SILHOUETTE`、程序化圆点/三角形作为五类敌机的正常显示。资源加载失败在 Release 中应记录为验收失败，而不是静默替换。
4. 音频仅按 `cueId` 播放当前 manifest 的 MP3。所有 67 个物理 Cue 已具备独立母带与运行时文件；禁止按“同一类音效”合并为一个文件或自行以通用 beep 替换。

**本批次验收结论：**五类敌机的所有运行时状态 SHA-256 互不重复；67 个物理 MP3 的
SHA-256 互不重复；manifest、图形状态、音频混音、Web 首屏资源预算均已通过。此结论不等同于
“全包其他图形已经完成去重”：投射物、升级图标与 HUD 的跨语义重复仍由
`docs/研发反馈意见.md` 的 F-27 跟踪，未关闭前不得把整个图形包标为最终发布完成。

### 1.3 v2.0.7 全量审计与玩家受击层（2026-10-16，强制）

`GFX-PLAYER-SHIELD-HIT` 已替换为独立的透明六边形护盾受击效果，源图为
`素材/图形/角色与敌机/GFX-PLAYER-SHIELD-HIT.png`，运行时状态为 active/end。
它和 `GFX-PLAYER-HIT-FLASH` 都是**叠加特效层**，不是可不透明覆盖机体的图片：
客户端必须保留机体本体可见，使用 Screen/Additive 或等价仅提亮混合方式，并按素材 alpha
合成。护盾命中只显示 Shield Hit 80–120 ms；真正扣 HP 才显示 Hit Flash。

本节“v2.0.7”是审计/素材补丁编号；为保持既有客户端加载契约，manifest 的运行时
`contentVersion` 仍固定为 `2.0.6-material-repair`。完整审计清单见
[全量素材语义审计](../../docs/全量素材语义审计_2026-10-16.md)。
当前普通态跨语义重复仍是 P0/P1 阻塞项；研发不得用通用图、回退剪影、程序化圆点/三角形
替代，也不得自行修改素材来规避问题。

## 2. 统一视觉、导出与元数据规范

### 2.1 视觉语言

| 信息角色 | 色彩/形状规则 | 禁止事项 |
| --- | --- | --- |
| 玩家/可控 | 青蓝、白色能量核心、圆润或对称轮廓 | 不与敌弹使用同一亮度/轮廓 |
| 普通敌人 | 深紫/洋红、尖锐或不对称剪影 | 不做成青蓝友军外观 |
| 危险/预警 | 洋红或琥珀 + 线/圆/扇形几何 | 仅依赖红绿或仅靠闪烁 |
| 奖励/恢复 | 琥珀/绿色辅助色 + 菱形/十字形 | 与伤害预警共用图标 |
| Boss/阶段 | 高对比洋红核心、装甲裂纹、独立弱点形状 | 用满屏特效遮挡安全缺口 |

所有机体默认机头向上；旋转由运行时完成。碰撞体永远使用产品基线数据，透明边缘、发光和尾焰不得扩大真实判定。

### 2.2 图形交付

| 类别 | 源文件 | 运行时导出 | 元数据要求 |
| --- | --- | --- | --- |
| UI/图标 | Figma/AI/SVG 可编辑源 | SVG；不支持的复杂效果导出 PNG 2× | viewBox、9-slice、最小尺寸、状态、Asset ID |
| 角色/Boss | PSD/ASE 或等效分层源 | 透明 PNG/WebP 2× | 锚点、朝向、层级、循环帧、帧率 |
| 投射物/特效 | 分层源、粒子纹理或序列帧源 | PNG/WebP 图集或独立纹理 | blend mode、帧数、FPS、寿命、缩放范围 |
| 背景 | 分层源 | WebP 为主、PNG 兜底 | 平铺方式、视差系数、低配开关 |

角色和投射物使用预乘 alpha 或统一的非预乘 alpha 流程，项目只能选一种并在导入工具中校验；不得混用导致黑边。Sprite Sheet 单边不超过 2048 px；单张超过 1024 px 的资源必须给出图集/分片理由。所有文字、数值、连击和倒计时由 Flutter 字体渲染，不烘焙到图片。

### 2.3 音频交付

| 交付层 | 规格 |
| --- | --- |
| 母带 | 48 kHz、24-bit WAV；保留无压缩源和工程工程文件 |
| 运行时 | Web/移动共用 MP3（CBR 160–192 kbps）；如引擎验证支持，可额外提供 OGG 作为高压缩变体，但 MP3 是必备回退 |
| 响度 | BGM 集成响度约 -16 LUFS；单个 SFX 约 -20 至 -14 LUFS；峰值不超过 -1 dBTP |
| 循环 | 所有 loop 标注精确 sample loopStart/loopEnd；首尾交叉淡化不得产生爆音 |
| 元数据 | Asset ID、总线、优先级、最大并发、最小重播间隔、是否循环、loop 点、源/许可证 |

响度为混音起始目标，不替代设备实测；最终以 Warning 可在 BGM 和高频射击上方清楚辨识为准。

## 3. 图形素材总表

### 3.1 玩家、敌人与 Boss

| Asset ID | 必须交付的状态/层 | 建议画布 | 触发/验收 |
| --- | --- | --- |
| GFX-PLAYER-BASE | 机体基础、驾驶舱、引擎静态层 | 256×256 @2x | 锚点中心；对应玩家 r=30 |
| GFX-PLAYER-ENGINE-CRITICAL | 琥珀引擎/低血叠层 | 256×256 @2x | HP ≤30%，HP >35% 淡出 |
| GFX-PLAYER-SHIELD-HIT | 可旋转护盾环 | 256×256 @2x | 护盾命中 80–120 ms |
| GFX-PLAYER-HIT-FLASH | 白闪与方向火花 | 256×256 @2x | 实际 HP 伤害 |
| GFX-PLAYER-DASH-TRAIL | 3 帧残影、可拉伸尾迹、结束收束 | 384×384 @2x | 0.22 s 冲刺；不暗示伤害 |
| GFX-EN-SCOUT | idle、hit、critical、destroy | 192×192 @2x | r=28；横摆时不换朝向 |
| GFX-EN-WING | idle、hit、critical、destroy | 224×224 @2x | r=32；三机均复用 |
| GFX-EN-SNIPER | idle、charge、hit、critical、destroy | 224×224 @2x | 0.75 s 锁定预警与 charge 同步 |
| GFX-EN-BOMBER | idle、drop、hit、critical、destroy | 288×288 @2x | 危险区素材独立 |
| GFX-EN-SHIELD | body、front-shield、hit、critical、destroy | 288×288 @2x | front-shield 独立，120°正面减伤清晰 |
| GFX-ELITE-AURA-ACCEL/SHIELD/BARRAGE | 3 个可叠加外环/词缀标识 | 256×256 @2x | 65/105/130 秒固定精英使用 |
| UI-ELITE-NAMEPLATE | 精英头顶名称条底板 | 512×512 @2x；运行时缩放至 220×44 logical px | 文本由 `enemy.*` / `affix.*` key 绘制，禁止烘焙文字 |
| UI-ELITE-AFFIX-ACCEL/SHIELD/BARRAGE | 加速双箭头 / 护体盾牌 / 弹幕三点图标 | 512×512 @2x；运行时 32×32 logical px | 必须按 `affixId` 与外环一对一匹配 |
| GFX-BOSS-AEGIS-BODY | 基础装甲、P1/P2/P3 装甲层 | 1024×1024 @2x | Body r=150；阶段切换不改锚点 |
| GFX-BOSS-AEGIS-WEAKPOINT | hidden、shown、hit | 256×256 @2x | P3 核心暴露 3 s；r=52 |
| GFX-BOSS-AEGIS-CRITICAL | 裂纹、核心警报层 | 1024×1024 @2x | HP ≤10%，不遮挡预警 |
| GFX-BOSS-ENTRY/PHASE/DEFEAT | 入场尾迹、阶段环、核心爆发/冲击环/散射 | 1024×1024 @2x 或序列 | 由 Boss 事件驱动，伤害判定独立 |

### 3.2 玩家武器、敌弹、预警与拾取物

| Asset ID | 内容 | 尺寸/变体 | 绑定规则 |
| --- | --- | --- | --- |
| GFX-WPN-PULSE / GFX-WPN-PULSE-MUZZLE / GFX-FX-PULSE-HIT | 脉冲、炮口、普通命中 | 64/128 px；normal | 0.24 s 射击，命中特效 80 ms 合并 |
| GFX-FX-PULSE-CRIT / GFX-WPN-ARC | 暴击电弧、链路 start/mid/end | 128/256 px；critical | 只在 `UP-CRIT-ARC` 暴击时出现 |
| GFX-WPN-MISSILE / GFX-WPN-MISSILE-TRAIL / GFX-FX-MISSILE-BLAST | 导弹、独立尾迹、内/外爆炸层 | 128/256/512 px | 爆炸视觉半径最大为判定半径 1.3 倍 |
| GFX-WPN-LASER-HEAD/BEAM/IMPACT | 可平铺/拉伸激光部件 | 128/64/128 px | 宽 28；激活/停止不跳帧 |
| GFX-WPN-DRONE / GFX-WPN-DRONE-BOLT | 无人机和无人机弹 | 128/64 px | 轨道半径 120；不可显示为可拾取物 |
| GFX-ENEMY-BULLET-WING/SNIPER/SHIELD | 三类敌弹 | 64 px，轮廓互异 | 半径分别 14/12/14；狙击弹带高亮头部 |
| GFX-HAZARD-BOMBER-WARN/ACTIVE | 轰炸机投放预警/生效危险区 | 256/256 px | 0.4 s 预警后生效；半径 90 |
| GFX-WARN-LINE/CONE/CIRCLE | 狙击线、扇形、环形、地面圆预警 | 可拉伸/旋转 | 预警在实体之下、背景之上 |
| GFX-BOSS-FAN-BULLET/RING-BULLET/LASER | Boss P1/P2/P3 攻击素材 | 64/64/可拉伸 | 与招式几何和安全缺口一致 |
| GFX-PICKUP-ELITE-CORE / GFX-PICKUP-SUPPLY-HEAL/SHIELD/DASH | 精英核心、Boss 前补给反馈 | 128 px；spawn/collect | 精英核心与战前补给不能共用同一剪影 |
| GFX-ENEMY-BREACH-WARN | 敌人逃逸箭头/边线提示 | SVG/128 px | y=920；琥珀 + 向下箭头 |

### 3.3 HUD、菜单和升级图标

| Asset ID 组 | 必须包含 | 状态 |
| --- | --- | --- |
| UI-HUD-HP-FRAME/FILL、UI-HUD-SHIELD-FRAME/FILL、UI-HUD-XP-FRAME/FILL | 条框、填充、高光、critical/low/hit | 宽度由程序裁切；不可用位图数字 |
| UI-HUD-LV-BADGE、UI-HUD-COMBO、UI-HUD-TIMER、UI-HUD-BOSS-FRAME/FILL、UI-HUD-BOSS-WEAKPOINT | 级别、连击、计时、Boss 阶段/濒毁、弱点 | 适配 1–3 位数字与中文名称 |
| UI-HUD-DASH-BUTTON/RING、UI-HUD-PAUSE、UI-HUD-DAMAGE-DIRECTION、UI-HUD-WARNING-VIGNETTE、UI-HUD-OBJECTIVE | 战斗交互和方向/濒危/逃逸提示 | ready/cooldown/disabled/pressed/focus；8方向旋转 |
| UI-BOSS-NAMEPLATE、UI-BOSS-PHASE、UI-BOSS-ATTACK-WARN | Boss 名称、阶段标记、招式文字/图标提示 | 入场/转段/蓄力时出现；不遮挡玩家和安全缺口；对应产品 `UI-BOSS-*` 合同 |
| UI-HOME-LOGO、UI-LOAD-PROGRESS、UI-BUTTON-PRIMARY/SECONDARY、UI-ICON-SETTINGS/MUTE/BACK/RETRY | 首页、加载与通用操作 | normal/pressed/disabled/focus；文案独立渲染 |
| UI-BRIEFING-PANEL/TIP、UI-SETTINGS-PANEL、UI-SLIDER-TRACK/FILL/THUMB | 开局短提示、设置容器、音乐/SFX 音量控件 | Briefing 仅展示简短移动/冲刺提示；Slider 支持 normal/pressed/focus/disabled，数值由文字渲染 |
| UI-DRAFT-PANEL/CARD、UI-RARITY-COMMON/RARE/EPIC | 三选一升级 | normal/pressed/focus/disabled；稀有度有形状差异 |
| UI-RISK-PANEL、UI-RISK-SAFE/BOUNTY/OVERLOAD、UI-TOOLTIP | 风险门 | safe/risk/locked/selected；锁定原因可放文本 |
| UI-PAUSE-PANEL、UI-TOGGLE、UI-RESULT-PANEL、UI-RESULT-MEDAL | 暂停/设置/结算 | victory/defeat、on/off、bronze/silver/gold/none |

以下 16 个升级图标必须**逐卡独立交付**，不能只交“系列通用图标”：`UI-UP-PULSE-RATE`、`UI-UP-PULSE-DAMAGE`、`UI-UP-PULSE-SPREAD`、`UI-UP-CRIT-ARC`、`UI-UP-MISSILE-UNLOCK`、`UI-UP-MISSILE-SALVO`、`UI-UP-MISSILE-RADIUS`、`UI-UP-LASER-UNLOCK`、`UI-UP-LASER-PRISM`、`UI-UP-DRONE-UNLOCK`、`UI-UP-DRONE-COUNT`、`UI-UP-SHIELD-MAX`、`UI-UP-DASH-CHARGE`、`UI-UP-DASH-REPAIR`、`UI-UP-ENERGY-GAIN`、`UI-UP-COMBO-GUARD`。正式交付只以这 16 个 `UP-*` ID 为准。

### 3.4 场景、字体与无障碍

| Asset ID | 交付物 | 规则 |
| --- | --- | --- |
| GFX-BG-DEEP-SPACE/NEBULA/STARS/GRID | 四层循环背景 | 远景、星云、星点、网格可独立关闭；无接缝 |
| FONT-UI-REGULAR/BOLD | 支持简体中文的授权字体或系统字体声明 | 数字高可读；最小 UI 文本 16 sp，战斗数字 18 sp |
| UI-FOCUS-RING / UI-COLORBLIND-PATTERN-* | 键鼠焦点环、危险/奖励/稀有图案层 | 降低动效和色弱模式仍能区分状态 |
| GFX-FALLBACK-SILHOUETTE / UI-FALLBACK-ICON | 开发与加载异常时的中性图形回退 | 仅异常路径；不得表达敌我、奖励或伤害；发布验证中出现即失败 |

## 4. 音频素材总表

### 4.1 UI、玩家与武器

| Asset ID | 触发事件 | 总线/优先级 | 时长、并发与间隔 |
| --- | --- | --- | --- |
| SFX-UI-TAP / BACK / ERROR | 按钮确认/返回/锁定 | UI / 40 | <0.2 s；并发 2；50 ms |
| SFX-UI-COUNTDOWN / DRAFT-OPEN / DRAFT-CHOOSE / RISK-OPEN / RISK-CHOOSE / PAUSE | 倒数、升级、风险门、暂停 | UI / 50 | <1.0 s；并发 1；各事件一次 |
| SFX-PLAYER-PULSE / PULSE-CRIT / PULSE-HIT | 脉冲发射/暴击/命中 | SFX / 20 | 0.08–0.3 s；并发 4；80 ms 合并 |
| SFX-PLAYER-MISSILE-LAUNCH / MISSILE-IMPACT | 导弹 | SFX / 30 | <0.8 s；并发 3；100 ms |
| SFX-PLAYER-LASER-START / LASER-LOOP / LASER-END | 激光状态 | SFX / 30 | loop 单实例；停止无爆音 |
| SFX-PLAYER-DRONE-SHOT / ARC | 无人机/电弧 | SFX / 25 | <0.4 s；并发 4；80 ms |
| SFX-PLAYER-DASH / SHIELD-HIT / HP-HIT / LOW-SHIELD / LOW-HP | 冲刺/护盾/HP/低护盾/低血 | Warning / 70 | Dash <0.5 s；LOW-SHIELD 与 LOW-HP 最短间隔均为 8 s |
| SFX-PLAYER-SHIELD-REGEN / HEAL / DASH-READY | 回盾/恢复/战前冲刺补给 | SFX / 35 | <0.8 s；事件一次 |

### 4.2 敌人、Boss 与结果

| Asset ID | 触发事件 | 总线/优先级 | 时长、并发与间隔 |
| --- | --- | --- | --- |
| SFX-EN-SCOUT/WING/SNIPER/SHIELD-SHOT | 对应敌方射击 | SFX / 35 | <0.5 s；每类并发 3；Sniper 不可被普通射击覆盖 |
| SFX-EN-SNIPER-WARN / BOMBER-DROP / BOMBER-HAZARD | 狙击/轰炸预警 | Warning / 75 | 预警早于伤害；并发 1 |
| SFX-EN-HIT / CRITICAL / DESTROY-S/M/L | 敌人命中/临界/死亡 | SFX / 25 | 体积对应 S/M/L；总并发 6 |
| SFX-EN-BREACH | 敌人越界突破 | Warning / 80 | <0.8 s；与 UI 逃逸提示对应 |
| SFX-ELITE-SPAWN / AURA / DEFEAT / CORE | 精英出现/词缀/死亡/核心 | Warning/SFX / 60 | Spawn/Defeat 单实例；Core <0.5 s |
| SFX-BOSS-ENTRY / PHASE / CRITICAL / DEFEAT | Boss 入场/转段/濒毁/死亡 | Warning/Music / 90 | 各阶段一次；Defeat 可 1–3 s |
| SFX-BOSS-FAN-WARN/SHOT / CHARGE-WARN/IMPACT / RING-WARN/SHOT / SUMMON / LASER-WARN/LOOP/END / WEAKPOINT-OPEN | Boss 招式 | Warning / 100 | 预警不可被任何普通 SFX 抢占；loop 单实例 |
| SFX-RUN-VICTORY / DEFEAT / RESULT-OPEN | 结果 | UI/Music / 60 | <3 s；不阻塞再来一局 |

### 4.3 音乐与环境

| Asset ID | 形态 | 触发/切换 |
| --- | --- | --- |
| BGM-HOME | 45–90 s loop | 首页；进入 Loading 淡出 0.5 s |
| BGM-RUN-BASE | 60–120 s loop | Briefing 后开始；升级/风险门只降低 6 dB，不停止 |
| BGM-RUN-TENSION | 可叠加 loop stem | 75 秒后或精英出现时淡入；reduceMotion 不影响 |
| BGM-BOSS | 60–120 s loop 或 stems | 150 秒 Boss 入场交叉淡化 1.0 s |
| BGM-BOSS-CRITICAL | 可叠加 loop stem | Boss ≤10% 淡入；死亡立即淡出 |

## 5. 音画状态映射与混音规则

| 游戏事件 | 图形 | 音频 | 限制 |
| --- | --- | --- | --- |
| 护盾命中 | GFX-PLAYER-SHIELD-HIT | SFX-PLAYER-SHIELD-HIT | 同帧合并一次 |
| 低护盾 | UI-HUD-SHIELD-* low 状态 | SFX-PLAYER-LOW-SHIELD | 护盾 ≤25% 触发；回升至 30% 停止 |
| HP 受伤 | GFX-PLAYER-HIT-FLASH + 方向 UI | SFX-PLAYER-HP-HIT | 不能覆盖攻击预警 |
| 低血 | 引擎 critical + vignette | SFX-PLAYER-LOW-HP | HP >35% 后淡出 |
| 冲刺 | dash trail | SFX-PLAYER-DASH | 0.22 s 与无敌帧同源 |
| 敌人临界/击毁 | critical/destroy | SFX-EN-CRITICAL/DESTROY-* | 击毁后才生成奖励 |
| 敌人突破 | breach warn + HUD objective | SFX-EN-BREACH | 穿透护盾 HP 伤害 |
| Boss 招式 | 对应 warning/投射物/核心 | 对应 Boss Warning cue | Warning 总线优先级最高 |
| Boss 补给 | pickup heal/shield/dash | 对应玩家恢复 cue | 只发生一次 |

优先级固定为：Boss/敌方伤害预警 > 玩家 HP/突破警告 > Boss 阶段 > UI 选择 > 武器 > 普通命中 > 环境。被抢占的低优先级声音直接丢弃，不延迟排队。高频声音不能产生音高抖动、削波或长期累积。

### 5.1 DomainEvent 到素材的强制映射

| DomainEvent / UI 命令 | 必须消费的素材或 Cue | 无素材时的处理 |
| --- | --- | --- |
| `RunStarted`、进入 `Briefing` | UI-BRIEFING-PANEL/TIP、SFX-UI-COUNTDOWN；结束后 BGM-RUN-BASE | `RunStarted` 本身不播放重复音 |
| `EnemySpawned` | 对应 GFX-EN-*；精英另加 GFX-ELITE-AURA-*、SFX-ELITE-SPAWN | 普通出生可静默，不得补放通用爆炸音 |
| `WeaponFired` / `WeaponHit` | 武器 GFX-WPN-* / GFX-FX-* 与同武器 SFX-PLAYER-* | 根据 `weaponId` 查映射；80 ms 合并规则仍生效 |
| `EnemyDestroyed` / `EnemyBreached` | destroy 状态 + SFX-EN-DESTROY-*；突破用 GFX-ENEMY-BREACH-WARN、SFX-EN-BREACH | 突破绝不能复用击毁、经验或掉落表现 |
| `UpgradeDraftOpened` / `UpgradeSelected` | UI-DRAFT-*、逐卡 UI-UP-*、SFX-UI-DRAFT-OPEN/CHOOSE | 选择后必须有一次视觉确认；冻结本身无循环音 |
| `RiskGateOpened` / `RiskSelected` | UI-RISK-*、SFX-UI-RISK-OPEN/CHOOSE；锁定用 SFX-UI-ERROR | 超时保底沿用选择音，不另加惩罚音 |
| `PlayerDamaged` | shield/hp/low 状态对应 §5 表项 | `hpDamage=0` 时不得播放 SFX-PLAYER-HP-HIT |
| `PlayerVitalStateChanged` / `DashStateChanged` / `DashEnded` | HP/护盾 normal-low-critical、引擎临界层、Dash ready-cooldown-disabled、trail end | 临时 hit 到期后必须回读最新 Vital 状态；Dash trail 不得卡在 active |
| `EnemyAttackTelegraphed` / `EnemyAttackFired` | Sniper charge/line、Bomber warn/drop、三类敌弹与对应 SFX | 以 `enemyId + attackId` 精确匹配；禁止任意敌人攻击触发多个音效 |
| `EnemyDamaged` / `EnemyVitalStateChanged` / `EnemyDefenseStateChanged` | 敌机 hit/critical、Shield body/frontShield | hit 固定 120 ms 后还原；frontShield 随 `facingRadians` 旋转 |
| `PickupHeal` / `PickupShield` / `DashReady` | GFX-PICKUP-SUPPLY-*、SFX-PLAYER-HEAL/SHIELD-REGEN/DASH-READY | Boss 战前补给无实体碰撞，不调用 collect 动画 |
| `BossPhaseChanged` / `BossDefeated` | GFX-BOSS-PHASE/DEFEAT、UI-BOSS-*、SFX-BOSS-PHASE/DEFEAT | 转段只播放一次；击败后停止 Boss loop |
| `BossAttackTelegraphed` / `BossAttackFired` / `BossAttackEnded` | 扇形、冲锋、环形、召唤、激光的专属预警/投射物/Cue | 必须以 `attackId` 精确匹配；激光 loop 只由开始/结束对控制 |
| `RunEnded` | UI-RESULT-*、SFX-RUN-VICTORY 或 SFX-RUN-DEFEAT、SFX-RUN-RESULT-OPEN | 结果层出现前停止危险/武器 loop |
| `WaveSpawnResolved`、`PhaseChanged` | 无运行时强制素材；仅调试/测试消费 | 禁止为了“有反馈”播放声音 |

## 6. 资产 Manifest、授权和验收

每项资产必须有一条 manifest 记录：`assetId`、`category`、`sourceFile`、`runtimeFiles[]`、`sha256`、`license`、`authorOrVendor`、`createdAt`、`contentVersion`、`states[]`、`triggerEvents[]`、`fallbackAssetId`、`memoryEstimateBytes`。音频额外记录 loudness、truePeak、bus、priority、maxVoices、minRetriggerMs、loop 点；序列帧额外记录 FPS、frameCount、blendMode、anchor。

### 6.1 验收门槛

1. `content_validate` 必须验证所有配置 Asset ID 在 manifest 中存在、状态齐全、文件 hash 正确、许可证非空。
2. UI 在 1920×1080、1440×1080、2560×1080 下无裁切；焦点、禁用、警告和色弱图案均可见。
3. 预警从背景和普通特效中可分辨；视觉有效范围不得大于判定范围 1.3 倍，不能小于判定范围。
4. 战斗峰值下图形不超过 v2.0 对象/内存预算；音频不超过每 cue 并发和总线优先级规则。
5. Web 冷加载满足 18 MB 首屏资源预算；所有正式资产离线可加载，无网络 URL 依赖。
6. 所有原始工程文件、导出文件、预览、许可证和 manifest 记录齐全，才可从“待制作”移入正式运行时目录。

## 7. 交付批次

| 批次 | 内容 | 阻断条件 |
| --- | --- | --- |
| A：M0/M1 占位可玩 | 玩家、Scout/Wing/Sniper、基础脉冲、冲刺、HP/护盾/XP/Dash HUD、8 个关键 SFX | 任一预警/受伤/升级缺 Asset ID 不可通过 |
| B：M2 完整战斗 | 全部武器、敌人、精英、风险门、Boss、全 UI、完整 SFX/BGM | 本文 §3–5 不得有缺项 |
| C：发布候选 | 正式背景、低配变体、Web 压缩、全许可证、混音/可读性报告 | §6.1 全部通过 |

## 8. 本次审查结论

旧清单的 HUD、低血、护盾、基础武器、敌机、Boss 和基础音频方向可复用，但不具备 v2.0 的精确实现性。素材清单已覆盖：玩家/敌人/Boss 的状态层；四种玩家高阶武器；三类敌弹、危险区、所有 Boss 招式；精英/突破/战前补给；16 个升级卡图标；页面完整 UI；音乐分层；逐事件音画映射；音频并发、混音、授权和 manifest 验收。

**v2.0.1 交叉验证补充（2026-10-12）**：以一线研发接入和产品状态合同为标准复核后，新增了 Asset ID 斜杠展开规则、manifest 状态/Cue/预载字段、发布回退处理、Boss UI、Briefing、设置音量控件、低护盾音效，以及所有 DomainEvent/UI 命令的音画消费映射；技术测试新增 `T-ASSET-01`、`T-AUDIO-03`。产品基线与产品文档已改为引用本文件，不再存在“旧清单是 v2.0 权威”的入口。至此，不存在需要产品再定义的素材种类、状态、触发、格式、接入或验收缺口；实际制作仍须按 §6 的 manifest 和验收门槛逐项交付。

**v2.0.2 发布交付补充（2026-10-13）**：正式包 `素材/manifest.json` 升级为 schema `1.1.0`、内容版本 `2.0.2-release`。每一图形/UI Asset ID 已提供 `renderStates` 的实际状态文件、`loadGroup`、锚点与回退；横向 HUD 条形资源附带九宫格边距、最小尺寸与填充区。音频记录已补齐 Cue、事件、通用回退、内存估算及并发/循环参数；`SFX-FALLBACK-SILENT` 作为逻辑 no-op 记录交付，不对应物理音频。发布前必须同时通过 `素材/元数据/validate_release_manifest.py` 与 `素材/元数据/validate_audio_mix.py`，后者验证 BGM 音量窗口和全部 SFX 峰值上限。

**v2.0.3 研发反馈闭环（2026-10-13）**：补齐了 Sniper `charge`、Bomber `drop`、Shield `frontShield`、Dash Trail 三帧、HUD `hit/low/critical`、Dash `ready/cooldown`、八方向受击指示、风险门、结算奖牌和开关等语义状态。所有图形/音频记录新增精确 `eventBindings`，删除了“按前缀批量猜触发事件”的错误元数据；新增 `DashStarted`、敌方/Boss 招式预警与发射、Boss 濒毁等表现事件。音频按 `firstRun`/`boss`/`lazy` 分组，首局资源集合可独立计算。背景正式采用 WebP 首选、PNG 回退的双格式合同。玩家和 Boss 已补交可编辑 SVG 组合源及原始 PNG 母版引用。发布门禁额外校验语义状态覆盖、绑定状态存在性和音频加载分组。

**v2.0.4 发布接入闭环（2026-10-13）**：将先前“素材状态齐全但事件无法唯一驱动”的风险改为可执行合同。新增生命/护盾、冲刺、敌机受击/临界/前盾、Boss 招式结束、风险选项和 UI 控件状态事件；明确五类敌方攻击与五种 Boss 招式的稳定 `attackId`。所有 Sniper、Bomber、Shield、Dash、HUD、八方向受击、风险门、结算勋章状态均已得到可枚举的路由；`resultTier` 也已定义。发布校验新增多状态资产路由覆盖和攻击 binding 精确性门禁，拒绝空条件的敌方/Boss 攻击路由。

**v2.0.5 阶段一裁决闭环（2026-10-14）**：内容版本升级为 `2.0.5-release`。`SFX-PLAYER-LOW-SHIELD` 与 `SFX-PLAYER-LOW-HP` 的 `minRetriggerMs` 均固定为 `8000`；新增 `UI-ELITE-NAMEPLATE` 与三种 `UI-ELITE-AFFIX-*` 正式图形，且三种外环/图标均以 `EnemySpawned.isElite=true + affixId` 精确路由，禁止全部叠加。`UI-COLORBLIND-PATTERN-DANGER/REWARD/RARITY` 重新导出为三角斜线、菱形加号、同心圆十字，作为默认而非可选的第二识别维度。客户端不得修改、重绘或用文字替换以上资源；只按 manifest 接入。
