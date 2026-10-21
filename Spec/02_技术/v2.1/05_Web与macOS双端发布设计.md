# v2.1 Web 与 macOS 双端发布技术设计

> **状态：当前生效的 [新增 v2.1-Web] 工程合同。** 一线工程师按本文实施 Web 加固与双端交付；不得改写 Domain 玩法、复制内容配置或为任一端创建独立素材包。产品入口见 [`Warship_v2.1双端发布需求.md`](../../01_产品/v2.1/Warship_v2.1双端发布需求.md)。

## 1. 架构审计结论

| 维度 | 当前证据 | 结论与动作 |
| --- | --- | --- |
| Domain / 随机 / 配置 | `GameRuntime`、`Pcg32`、`ContentCatalog` 与固定 seed 测试均为纯 Dart；Web Release/WASM 于 2026-10-21 构建成功 | **可复用**；禁止平台分支进入 Domain |
| Flutter/Flame 表现 | 固定逻辑世界、`RenderSnapshot`、`KeyboardInputGateway`、视口 Golden 已存在 | **可复用**；补浏览器 resize/min-viewport/焦点测试 |
| Web 壳与 PWA | `web/index.html` 有加载、错误重试、reduce-motion；`web/manifest.json` 有横屏与图标；构建产出 service worker/WASM | **可复用**；补缓存版本、base href、真实服务端 headers 验收 |
| 存档 / 触感 | `shared_preferences` 跨平台；触感端口在 macOS/Web 无操作 | **可复用**；补浏览器本地存储持久化/清除站点数据测试 |
| 生命周期 / 音频 | `AppLifecycleState.hidden` 自动暂停；AudioPort 已抽象且备注手势限制 | **部分就绪**；补真实手势解锁、后台冻结、音频拒绝降级测试 |
| 平台 I/O | `warship_v2_game.dart`、`baseline_recording.dart` 直接导入 `dart:io`，当前 Web 构建虽成功但依赖运行时 `kIsWeb` 防护 | **P1 必改**：改为条件导入的平台端口，业务共享文件不得直引 `dart:io` |
| CI / 发布 | CI 已构建 Web release；macOS job 仍为 debug，未产生双端同身份 release manifest | **P0 必改**：双端 Release 构建、工件 hash 和版本一致性成为同一门禁 |

## 2. 不可变分层与平台适配

### 2.1 允许的依赖方向

```text
Domain/Core (零平台 API、同 seed 必同结果)
        ↓ immutable RenderSnapshot / DomainEvent
Presentation + App (Flutter/Flame、输入、生命周期)
        ↓ interfaces only
Infrastructure ports (Audio / Store / Diagnostics / BaselineArtifactWriter)
        ↓ conditional import
macOS implementation            Web implementation
```

禁止 `lib/game/domain/**`、`lib/game/core/**` 导入 `dart:io`、`dart:html`、`package:web`、`Platform` 或浏览器全局对象。平台判断只能在 App/Infrastructure，并通过接口向上提供行为。

### 2.2 必改的两个 I/O 泄漏点

1. 新建 `AssetDiagnosticsSink`：macOS 实现可写沙盒 Documents；Web 实现只 `debugPrint` 并保存最近 50 条内存诊断供开发工具读取。`warship_v2_game.dart` 只依赖该接口，删除直接 `dart:io`、`File`、`Directory`、`Platform` 引用。
2. 新建 `BaselineArtifactWriter`：macOS 实现沿用显式 dart-define 路径；Web 实现返回 `unsupported` 诊断且不尝试写文件。`baseline_recording.dart` 只保留录制资格判断和序列化，不得导入 `dart:io`。Web 基准如需导出，只能通过后续明确批准的下载 UX，首发不实现。
3. 两个端口都必须用条件导出，例如 `*_stub.dart` / `*_io.dart` / `*_web.dart`；不要在共享文件里以 `if (kIsWeb)` 包裹 `dart:io` 调用来代替条件导入。

## 3. Web 运行时合同

### 3.1 输入、尺寸、焦点

- `V2RunScreen` 保持现有 `FocusNode`；首次有效 pointer/key 必须请求焦点并执行音频解锁。任何 overlay 关闭后焦点回到战场，避免键盘只滚动网页或丢失移动。
- 浏览器 `resize`、`devicePixelRatio` 改变及 4:3/16:9/21:9 仅触发 Presentation 重布局；不得重建 Runtime、换 seed、清输入或重放音效。
- 定义 `WebViewportPolicy`：CSS viewport `width>=1024 && height>=640` 才允许从 Briefing 进入 Playing；不满足时停在非战斗提示态且不推进 `GameClock`。恢复满足后由玩家重新点击开始。
- `AppLifecycleState.hidden/inactive/paused/detached` 统一提交 `PhaseController.pause(source:lifecycle)`；恢复只解除系统遮罩，不自动 `resume`。该规则与 macOS 一致。

### 3.2 音频与持久化

- 抽象 `WebAudioUnlockPort.unlockFromUserGesture()`，只允许从开始/战场 pointer/键盘事件调用；一个页面会话最多尝试一次，失败记录为非阻断诊断。
- 解锁成功后，`AudioDirector` 根据本地 `musicEnabled`/`sfxEnabled` 启动或保持静音；不得因手势解锁重复叠加 BGM。音频被浏览器拒绝时，Domain、计时、输入和存档照常运行。
- `SharedPreferencesStore` 继续作为 Web 本地存储实现。读取被浏览器策略拒绝时必须退化至 `InMemoryKeyValueStore`，并在设置页显示“本机记录未保存”的非阻断状态；不能访问网络或要求登录。

### 3.3 加载、缓存与离线

- 保留 `web/index.html` 的不确定进度、20 秒超时和重试按钮。`flutter-loader-error`、资源 hash 错误、WASM/CanvasKit 下载错误都必须进入同一可重试失败态。
- 构建后检查 `build/web/flutter_service_worker.js`、`version.json`、WASM、`AssetManifest.bin` 和所有 manifest runtimeFiles 真实存在并可由静态 HTTP 服务返回。缺一个即构建门禁失败。
- 缓存更新策略由托管层实现，要求见产品文档 §4；应用不得在 `Playing` 中执行 `location.reload`、service-worker `skipWaiting` 或强制刷新。

## 4. 双端构建与产物合同

### 4.1 唯一构建输入

构建工程新增一个只读 `ReleaseIdentity` 工具，从 `pubspec.yaml`、`lib/app/v2_bootstrap.dart` 的 `kActiveContentVersion` 和 `git rev-parse HEAD` 派生身份。禁止在 Web 或 macOS 命令、CI YAML、网页 title 中重复写 release version。

```text
validate inputs → build v2 assets → flutter analyze/test
   ├─ flutter build macos --release --build-name X.Y.Z --build-number N
   └─ flutter build web --release --wasm --base-href <configured-path>
          ↓
hash artifacts + validate runtime files
          ↓
release-manifest.json + 双端候选包
```

`release-manifest.json` 的字段、发布原子性和 base href 以产品文档 §3 为准。文件放在构建工作目录/候选包根目录，不提交仓库。

### 4.2 CI 门禁

1. `analyze-and-test` 继续先运行素材校验、分析与非 Golden 测试。
2. Web job 改为 `flutter build web --release --wasm`，并用真实静态 HTTP 服务验证关键文件的 200、WASM MIME、Web 根路径与子目录 `--base-href /warship/` 两种构建。
3. macOS job 改为 `flutter build macos --release`；无法签名/notarize 的公开 CI 只可标“未签名候选”，不得冒充发布产物。
4. 新增 `verify-dual-release` job：读取两个构建输出，检查 ReleaseIdentity 一致、manifest hash 一致、Web 运行时文件完整、禁止 build 目录/候选包污染 Git。
5. Golden 仍在固定 macOS 基线环境运行；Web 以浏览器截图/人工矩阵作为发布证据，不能以 macOS Golden 代替。

## 5. 新增测试和验收用例

以下路径是**必须新建或扩展**的测试/工具入口；名称、fixture 和断言均固定。不得只在 CI 命令中临时拼接检查，也不得把 Web 行为测试塞进无关的 v2.0 用例。

| ID | 必须实现的文件 | 层级 | 固定输入 | 精确断言 |
| --- | --- | --- | --- | --- |
| WEB-T-01 | `test/unit/platform/web_platform_ports_test.dart` | 单元 | 调用共享平台端口的 Web stub | `AssetDiagnosticsSink` 无 I/O、`BaselineArtifactWriter` 返回 unsupported；共享文件静态检查无 `dart:io` |
| WEB-T-02 | `test/widget/web_viewport_policy_test.dart` | Widget | 1023×640、1024×639、1024×640、4:3/16:9/21:9 | 小于阈值不进入 Playing/不推进时钟；阈值及以上固定世界与 HUD 安全区完整 |
| WEB-T-03 | `test/widget/web_lifecycle_pause_test.dart` | Widget/生命周期 | Playing 后 hidden → resumed | hidden 仅一次暂停；推进 120 帧时间/随机/伤害不变；恢复不自动开战 |
| WEB-T-04 | `test/widget/web_audio_unlock_test.dart` | Widget 集成 | pointer/key 首手势成功 / 被拒绝 | 只尝试一次 unlock；成功按设置开始音频，拒绝不影响 InputFrame/Runtime；BGM 不重复 |
| WEB-T-05 | `test/unit/platform/web_store_fallback_test.dart` | 单元/集成 | 浏览器 store 成功 / 拒绝 / 清站点数据 | 设置记录可恢复；拒绝退化内存且可游玩；清除后恢复平台默认值 |
| WEB-T-06 | `tool/verify_web_static_release.dart` 及 `test/tool/verify_web_static_release_test.dart` | 构建 | root 与 `/warship/` base href | 关键静态文件存在且 HTTP 200；WASM 为正确 MIME；子目录资源 URL 不逃逸根路径 |
| DUAL-T-01 | `tool/verify_dual_release.dart` 及 `test/tool/verify_dual_release_test.dart` | 构建 | 同一 commit 的两个候选包 | releaseVersion、contentVersion、commit、素材 manifest SHA 一致；任一不同失败 |
| DUAL-T-02 | `docs/环境验收准备件.md` §二、§三之二 | 浏览器人工 | Chrome/Safari/Edge 当前与上一版本 | 按 WEB-P-01~05 填证据；真实手势、离线、缓存更新必须各录屏一次 |
| DUAL-T-03 | `docs/环境验收准备件.md` §三之二 | 发布人工 | macOS Release + Web Release | 同一候选身份、签名/部署地址、SHA、操作员、日期、回滚包位置完整登记 |

## 6. 实施顺序与完成定义

| 批次 | 内容 | 退出条件 |
| --- | --- | --- |
| W0 / P0 | ReleaseIdentity、CI 双 Release 构建、Web 产物完整性 | WEB-T-06、DUAL-T-01 全绿；macOS 为 release 构建 |
| W1 / P1 | 条件导入 I/O 端口、viewport、生命周期和焦点 | WEB-T-01~03 全绿；无 Domain 平台依赖 |
| W2 / P1 | Web 音频手势、存储降级、加载/缓存诊断 | WEB-T-04~05 全绿；失败不阻断游玩 |
| W3 / P0 | 浏览器矩阵、双端候选、发布记录 | DUAL-T-02~03 证据齐全；两端一起公开 |

禁止以 Web build 成功、Chrome 单浏览器、debug 截图、macOS Golden 或静态文件名校验替代 W3。新增平台 API、CDN、远程服务、登录、移动网页支持或发布渠道变化必须重新进入研发反馈意见，不能自行扩展。
