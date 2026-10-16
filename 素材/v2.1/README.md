# Warship v2.1 正式待接入素材包

> 这是 v2.1 唯一可供构建工程接入的新增素材源。它与 Spec/03_素材/v2.1/02_素材清单与制作规范.md 的 Asset ID、帧表和 SHA-256 一一对应；不得直接运行 Spec 的归档副本。

## 目录

- 图形/动效序列：玩家受击、低血/濒危、敌机击毁、非阻断提示。
- 图形/武器形态：Prism、Arc、Plasma、Needle、Missile 的弹体和命中特效 sheet。
- 图形/奖章：Gold、Silver、Bronze 独立奖章 sheet。
- 音频/运行时WAV：12 条 v2.1 运行时 cue，48kHz、单声道、16-bit PCM WAV。

## 接入边界

1. 研发按 Asset ID、frameRect、事件绑定和 SHA-256 制作 v2.1 manifest；禁止按文件名猜帧。
2. 所有 PNG 必须从本目录读取，不能以旧 v2.0 占位图替代。
3. 所有 WAV 必须以对应 cue 播放；发布前音效人员完成试听、响度与并发签收。
4. 此目录不是应用运行时 assets 目录。构建链路将审核文件复制到应用资源目录后，须复核 manifest 和 hash。
