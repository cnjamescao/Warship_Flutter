# Warship

一款在 **macOS 桌面端**运行的单机复古太空射击小游戏。
玩家用键盘左右移动飞船并连续射击，清除持续下压的敌方舰队来获得高分。

> 本项目由作者早前的 Python 版本重写而来，现基于 **Flutter + Flame** 实现。

---

## 平台与范围

| 项 | 说明 |
| --- | --- |
| 交付平台 | **仅 macOS 桌面端**（仓库中只有 `macos/` 宿主工程） |
| 技术栈 | Flutter 3.47.1 / Dart 3.13.1 / Flame 1.38.1 / flame_audio 2.12.2 |
| 不在范围内 | Android / iOS / Web / Windows / Linux、触摸与手柄控制、联网、账号、排行榜 |

> Flutter 与 Flame 具备跨平台潜力，但**不等于**当前产品支持移动端。

---

## 环境前提

- **Flutter 3.47.1（stable）**，Dart 3.13.1
  ```bash
  flutter --version
  ```
- **Xcode 与 macOS 工具链**：`flutter build macos` / `flutter run -d macos` 依赖本机 Xcode。
  首次使用需要完成 Xcode 的首次启动与许可确认（这一步不属于 Dart 代码的一部分）：
  ```bash
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch
  ```

---

## 运行与验证

```bash
flutter pub get          # 安装依赖
flutter run -d macos     # 以调试模式运行 macOS 应用
flutter analyze          # 静态分析（应输出 No issues found）
flutter test             # 运行全部自动化测试
```

单元测试与组件测试**不需要** Xcode，可在任意环境运行；
只有 `flutter run -d macos` / `flutter build macos` 需要完整的 Xcode 环境。

---

## 操作方式

| 动作 | 按键 |
| --- | --- |
| 左移 | `←` 或 `A` |
| 右移 | `→` 或 `D` |
| 射击（按住连发） | `Space` |
| 暂停 / 恢复 | `Esc` 或 `P` |
| 开始 / 重开 | 鼠标点击 **Play** / **Play Again** / **Restart** |
| 继续游戏 | 暂停菜单中的 **Resume** |
| 静音开关 | 右下角音量按钮（菜单、暂停、结束界面下同样可用） |

契约细节：

- 左右键**任一绑定键仍按住**即持续移动；两个别名键不会互相干扰。
- 左右同时按住时水平速度为 0。
- **暂停是边沿触发**：只在按下瞬间切换一次，长按不会来回抖动。
- 暂停期间世界**完全冻结**：不推进规则，不改变分数、生命与任何实体坐标。
- 暂停 / 恢复 / 失焦都会**清空输入**，避免恢复后因残留按键而自己移动或射击。
- 窗口失焦 / 应用切到后台时会**自动暂停**（不自动恢复，需玩家显式继续），
  避免"离开一下回来就已经掉命"。

---

## 目录结构

```text
lib/
  main.dart                      Flutter UI（HUD、遮罩、焦点桥接、生命周期释放）
  game/
    warship_game.dart            Flame 场景与单帧协调（固定 800×600 逻辑画布）
    game_config.dart             不可变配置：所有规则与手感数值
    game_session.dart            对局状态：分数 / 最高分 / 生命 / 状态（唯一事实来源）
    input_controller.dart        键集合 → 动作，失焦清理
    fleet_controller.dart        舰队生成、边界回夹、波次难度
    collision_resolver.dart      AABB、唯一命中、伤害裁决
    components.dart              飞船 / 敌人 / 子弹的显示组件
    game_audio.dart              音效服务（含静音与失败降级）
assets/
  images/                        ship.png / alien.png
  audio/                         shoot / hit / life_lost / game_over（原创合成音效）
test/
  unit/                          纯规则单元测试
  game/                          规则集成测试（确定性驱动）
  widget/                        HUD / 遮罩 / 视口测试
  support/                       测试脚手架
tool/
  generate_audio.dart            音效生成器（可复现资产）
Spec/
  Warship产品设计.md              唯一实施基线（产品与技术规格）
  代码审查反馈.md                  代码审查证据
  Warship产品设计（审阅修订版）.md   审阅修订版说明
```

---

## 关键设计说明

### 固定逻辑画布

游戏规则**永远在 800×600 逻辑像素内运行**，真实窗口尺寸只决定显示用的 viewport：

- 窗口被缩放时，实体坐标、碰撞边界、舰队行为**完全不受影响**；
- 宽高比不匹配时自动 letterbox（等比留边），不拉伸游戏世界；
- 窗口被拖到极小（甚至 1×1）也不会出现负边界、越界或异常。

### 规则与表现分离

`WarshipGame` 只负责编排单帧流程，具体规则在各模块中：

| 模块 | 职责 |
| --- | --- |
| `GameSession` | 状态、分数、最高分、生命 |
| `InputController` | 键集合 → 动作、失焦清理 |
| `FleetController` | 舰队生成、边界与难度 |
| `CollisionResolver` | 唯一命中与伤害裁决 |
| `GameConfig` | 不可变数值配置 |

### UI 同步契约

游戏层是唯一事实来源，UI 只读。一次规则事务只产生一次通知，
且任何 listener 被唤醒时读到的一定是**已提交的最终值**（不依赖帧末回调）。

---

## 音效

四个音效由 `tool/generate_audio.dart` **现场合成**（方波 + 噪声 + 指数衰减），
因此仓库不包含任何第三方音频素材，没有授权问题，四个文件合计约 52KB：

```bash
dart run tool/generate_audio.dart
```

音频被设计为"锦上添花"：加载或播放失败会自动降级为静音，**绝不影响对局**。

---

## 质量门禁

```bash
flutter analyze   # 必须 0 issue
flutter test      # 必须全绿
```

CI 配置见 `.github/workflows/ci.yml`：分析、测试、`pubspec.lock` 同步检查，
以及（在具备 Xcode 的 runner 上）macOS debug 构建。

---

## 规格文档

行为契约以 **[`Spec/Warship产品设计.md`](Spec/Warship产品设计.md)** 为唯一实施基线，
其中定义了已实现 / 未实现 / 提议项的边界，以及 T01–T11 验收用例。
