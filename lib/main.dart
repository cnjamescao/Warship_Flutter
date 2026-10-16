// ================================================================
// lib/main.dart —— Warship v2.0 应用入口
// 补充：本层的失败处理与分层边界
//   * 内容加载失败必须停在 Loading 并可重试，不得进入对局
//   * 本层不得捕获并吞掉配置错误 —— 配置问题必须在加载期暴露，而不是变成运行期的玩法异常
// ================================================================
// **架构位置**：App 层（最外层）。唯一职责是**装配与启动** ——
//   不持有规则状态、不做业务判断。
//   依据：Spec/02_技术/v2.0/01_技术架构与模块设计.md §2
//   「app：注入依赖、首页/设置/结算路由、SafeArea。
//     **禁止直接遍历战斗实体**。」
//
// **启动链路**：
//   main → WarshipV2App → 加载并校验内容 → V2RunScreen（Flame + HUD）
//
// **与谁交互**：
//   * 下游：`V2Bootstrap`（构建 Runtime）、`V2AppFlow`（相位与路由）
//   * 本文件**不**直接接触 `GameRuntime` 的内部状态，只做转交
//
// **关键约束**：
//   * 内容校验失败时必须**停留在 Loading 并显示可重试错误**，
//     **禁止进入对局**（架构 §7）—— "带着坏内容开局"比"开不了局"更糟
//   * 分层：本层不得引用 `game/domain/` 的具体规则类型
//
// **为什么这样分层**：规则（Domain）与端侧（App）之间只通过
//   `GameRuntime` 与不可变快照通信，使"表现不影响规则"成为**可测试的
//   性质**（见 `test/game/acceptance_visual_must_not_affect_rules_test.dart`），
//   而不是靠约定。
//
// **历史**：v1.x 实现保留在 `lib/legacy/v1_app.dart` 作为历史基线，
//   不参与 v2.0 启动路径。
// ================================================================

import 'package:flutter/material.dart';

import 'app/v2_bootstrap.dart';
import 'app/v2_app_flow.dart';
import 'game/core/game_runtime.dart';
import 'game/core/render_snapshot.dart';
import 'game/infrastructure/asset_loader.dart';
import 'game/presentation/input_gateway.dart';

/// 本局随机种子。同一 seed + 同一输入序列产出完全相同的对局。
const int kDefaultRunSeed = 0x4E454F4E0001;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WarshipV2App());
}

/// 应用外壳。
class WarshipV2App extends StatelessWidget {
  const WarshipV2App({super.key, this.seed = kDefaultRunSeed});

  final int seed;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Warship：霓虹最后防线',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3FE0FF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF05030F),
      ),
      home: V2BootGate(seed: seed),
    );
  }
}

/// 启动门：加载内容 → 进入对局。
class V2BootGate extends StatefulWidget {
  const V2BootGate({super.key, required this.seed});

  final int seed;

  @override
  State<V2BootGate> createState() => _V2BootGateState();
}

class _V2BootGateState extends State<V2BootGate> {
  Future<BootResult>? _future;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  void _boot() {
    setState(() {
      _future = const V2Bootstrap().boot(seed: widget.seed);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<BootResult>(
      future: _future,
      builder: (context, asyncSnapshot) {
        if (asyncSnapshot.connectionState != ConnectionState.done) {
          return const _LoadingView();
        }
        final result = asyncSnapshot.data;
        if (result == null || !result.isReady) {
          return _ErrorView(
            message: result?.error ?? '未知错误',
            onRetry: _boot,
          );
        }
        // 内容已校验通过：进入完整相位流程
        // Home → Loading → Briefing → Playing ↔ Paused → Result。
        return V2AppFlow(
          catalog: result.catalog!,
          seed: widget.seed,
        );
      },
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(height: 20),
            Text(
              '正在加载资源',
              style: TextStyle(color: Colors.white70, letterSpacing: 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内容校验失败视图（架构 §7：显示"资源版本错误，请重试"，可返回首页）。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.error_outline,
                color: Color(0xFFFF5C8A),
                size: 48,
              ),
              const SizedBox(height: 16),
              const Text(
                '资源版本错误',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}

/// 供测试直接注入依赖的最小构造入口，避免测试依赖异步资源加载。
class V2RunHarness {
  const V2RunHarness({
    required this.runtime,
    required this.bindingTable,
    required this.input,
  });

  final GameRuntime runtime;
  final AssetBindingTable bindingTable;
  final KeyboardInputGateway input;

  RenderSnapshot snapshot() => runtime.snapshot();
}
