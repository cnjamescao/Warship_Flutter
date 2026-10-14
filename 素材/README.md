# Warship v2.0.5 正式发布素材包

本目录按《Warship v2.0 素材清单与制作规范》的 Asset ID 规则组织，供美术、音频、TA 与客户端直接接入。根目录 `manifest.json` 是客户端唯一允许读取的资源索引。

## 目录

- `图形/运行时PNG/`：123 个稳定 Asset ID 的主资源及其显式状态变体；客户端仅从 manifest 指向的文件加载图形。`图形/角色与敌机/`、`图形/*ATLAS.png` 为美术原始视觉源，不直接由运行时引用。
- `图形/源SVG/`：可编辑的矢量主资源。状态变体由 `元数据/generate_runtime_state_variants.py` 从已验证主 PNG 烘焙生成；AI 角色主体原始 PNG 保留在 `图形/角色与敌机/`，运行时统一使用已规范尺寸的状态变体。
- `音频/母带WAV/`：48 kHz、24-bit、立体声的原创合成母带；每个文件名对应一个 Cue Asset ID。
- `音频/运行时MP3/`：与每条母带同 ID 的 160 kbps MP3 运行时文件。
- `manifest.json`：197 条完整记录（127 图形/UI、67 物理音频、1 条静默逻辑回退、2 条字体声明），含运行时文件、hash、语义状态/帧、加载组、精确 `eventBindings`、Cue、回退、九宫格和许可证字段。敌方攻击固定按 `enemyId + attackId`、Boss 攻击按 `attackId` 路由；精英按 `isElite + affixId` 精确路由；多状态 UI/特效已覆盖所有声明状态。
- `元数据/`：可复现导出脚本、音频 manifest、旧图集参考映射和发布门禁。

## 发布状态

图形主体来自 AI 生成；HUD、预警、状态层和 UI 均以可编辑原创矢量设计导出为独立 PNG。每一个声明状态都有明确 `renderStates → runtimeFiles` 映射，不依赖运行时猜色或推导文件名。Sniper、Bomber、Shield、Dash Trail、HUD、风险门、结算和开关等均已覆盖产品规定的语义状态。四层背景的 `runtimeFiles` 首选 WebP，`fallbackRuntimeFiles` 明确给出 PNG 回退。玩家主机体为 512×512，Boss 主体为 1024×1024；HP、护盾、XP、Boss 和加载进度条均为 960×96 横向九宫格资源。

音频均为原创合成母带并已输出 160 kbps MP3。五条 BGM 已通过 EBU R128 检查（约 -16 LUFS），所有 SFX 母带峰值不高于 -1 dB。低护盾与低血 cue 的最短重触发间隔为 8 秒。`SFX-FALLBACK-SILENT` 是受 manifest 管理的逻辑静默回退，因此不会产生无意义的空音频文件。

## 集成规则

1. 不允许以文件名推导玩法；客户端通过 Asset ID 查询 `manifest.json`，仅按 `eventBindings.event + when` 选择状态/Cue，再按 `renderStates[state].runtimeFiles` 加载资源。静态资源的 `frameInterval=[0,0]`、`frameCount=1` 是显式合同；Dash Trail 的 `active` 是 3 帧、14 FPS 合同。
2. 不允许在运行时代码读取 `ATLAS`、`源SVG` 或 `元数据/graphics_atlas_map.json`；它们仅用于后续美术迭代。
3. 构建前校验所有 `runtimeFiles`、SHA-256、源文件、许可证、状态映射、加载组、Cue 和回退 ID；任何缺失均阻断构建。
4. 正式打包只复制 manifest 引用的运行时文件；`prune_unreferenced_runtime_assets.py` 会在资源导出后删除生成过程中遗留的未引用图像。

在仓库根目录执行以下两项门禁，均必须输出 `PASS`：

```sh
python3 素材/元数据/validate_release_manifest.py
python3 素材/元数据/validate_audio_mix.py
python3 素材/元数据/validate_visual_state_assets.py
python3 素材/元数据/validate_web_load_budget.py
```
