# Warship v2.0 技术设计包

## 目的与执行顺序

本目录是 `Warship_v2.0研发交付基线.md` 的技术实现说明，面向一线 Flutter/Flame、UI、音频、QA 工程师。产品规则、数值、内容表只引用产品基线；本目录只决定如何稳定、可测试、可扩展地实现。

| 阅读顺序 | 文件 | 用途 |
| ---: | --- | --- |
| 1 | [01_技术架构与模块设计.md](01_技术架构与模块设计.md) | 模块边界、状态机、生命周期、帧循环与迁移原则 |
| 2 | [02_运行时与数据协议.md](02_运行时与数据协议.md) | 配置 Schema、实体、事件、随机、存档、资源和输入协议 |
| 3 | [03_实施工作包与交付标准.md](03_实施工作包与交付标准.md) | 可分配的开发工作包、顺序、Definition of Done |
| 4 | [04_测试计划与验收用例.md](04_测试计划与验收用例.md) | 自动化/人工测试、性能与最终验收 |

## 约束

- 唯一产品来源：[Warship_v2.0研发交付基线.md](../../01_产品/Warship_v2.0研发交付基线.md)。遇到旧版文档冲突时，以该基线为准。
- 禁止在组件、Widget 或测试中硬编码敌人、升级、波次、Boss 数值；所有内容数值由版本化配置加载。
- 允许工程师自行决定具体类名、文件粒度和第三方库封装，但不得突破本文的依赖方向、事件语义和验收条件。
- 本设计不要求账号、服务器或网络。任何网络调用都属于范围外缺陷。

## 建议目录目标

~~~text
lib/
  app/                 # Flutter 壳、路由、生命周期、设置页
  game/
    core/              # 时钟、随机、状态、事件、配置加载
    content/           # JSON/DTO、校验、版本化内容表
    domain/            # 纯 Dart 战斗规则与系统
    presentation/      # Flame 世界、组件、渲染、特效、输入桥接
    infrastructure/    # 音频、持久化、资源、浏览器适配
test/
  unit/ integration/ widget/ golden/ performance/ support/
assets/
  config/ images/ audio/
~~~

现有 `lib/game/` 中的 `GameSession`、`InputController`、`CollisionResolver`、`FleetController`、`WarshipGame`、`GameAudio` 可作为迁移参考；不得把 v1.x 的左右移动/舰队规则直接扩展成 v2.0 的核心结构。
