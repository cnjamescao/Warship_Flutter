// ================================================================
// lib/game/presentation/asset_cache.dart —— 图形资源缓存
//
// **架构位置**：Content 层 —— **内容与代码的分界线**。
//   产品数值、文案、素材绑定**全部来自配置**，代码不得硬编码这些值；
//   本层负责把它们**读进来、校验、并提供类型安全的访问**。
//
// **与谁交互**：
//   * 上游：`V2Bootstrap.loadCatalog()`（进入 Briefing 前）
//   * 下游：各 Domain 系统（经 `GameRuntime` 装配）、表现层（经 manifest）
//
// **关键约束**：
//   * **失败必须响亮**：缺 key、参数不匹配、ID 未登记等都必须在
//     **加载期**抛错，禁止以默认值兜底 —— 带着坏内容开局比开不了局更糟
//   * **文本只存在于 `strings_zh_CN.json`**；代码里出现玩家可见中文
//     由 `T-COPY-01` 静态守卫拦截
//
// **⚠️ 易错点（真实事故，本项目最贵的一个）**：
//   * **Flame 会自动加 `assets/images/` 前缀**：
//     `Flame.images.load(path)` 内部会拼上该前缀，而 manifest 里的
//     `runtimeFiles` **已经是完整的 Flutter 资源路径** ——
//     直接把 manifest 路径喂给 Flame 会拼成
//     `assets/images/assets/images/v2/…`，**全部 84 个图形加载失败**，
//     玩家看到的是程序化占位图形（F-26-02，P0）。
//     因此本文件在调用 Flame 前**必须剥掉** `kFlameImagesPrefix`，
//     而缓存仍以**完整路径**为键（查询侧不必知道这个差异）。
//     ⚠️ **同一个错误在本项目发生过两次**（第一次只在测试里），
//     改动加载路径时务必回归这一条。
//   * **`imageFor` 返回 null 是"取不到图"的正常信号**，调用方应据此
//     决定"不绘制"还是"回退" —— 但**不要**用 Canvas 几何替代正式素材
//     （产品裁决明确禁止）。
//   * 诊断落盘必须**沙盒安全**：macOS 应用是沙盒的，`/tmp` 与
//     `~/Desktop` 会被拦；应用 `$HOME/Documents/`（容器内）并
//     **绝不静默吞掉写入失败**（我曾因此"以为写了、其实没写"）。
// ================================================================
// 依据：Spec/02_技术/v2.0/02_运行时与数据协议.md §7
//   「Loading 阶段预载 manifest 中 `loadGroup=firstRun` 的图形与音频；
//     `boss` 在 Boss 倒计时前预载，`lazy` 可惰性加载但不得造成攻击缺贴图。」
//   素材规范 §1.1
//   「仅按 `eventBindings.event + when` 选择状态/Cue，
//     再按 `renderStates[state].runtimeFiles` 加载资源。」
//
// 关键契约：**图像键一律来自 manifest 的 runtimeFiles**，
// 不拼路径、不按文件名猜、不使用任何硬编码素材路径。
// ================================================================

import 'dart:ui' as ui;

import 'package:flame/flame.dart';

import '../content/asset_id.dart';
import '../content/asset_manifest.dart';

/// 一次图形加载失败（记录后走占位/回退，不抛出到战斗循环）。
class AssetLoadFailure {
  const AssetLoadFailure(this.assetId, this.path, this.error);

  final String assetId;
  final String path;
  final String error;

  @override
  String toString() => '载入失败 $assetId（$path）：$error';
}

/// 图形资源缓存。
class VisualAssetCache {
  VisualAssetCache({required this.manifest});

  final AssetManifest manifest;

  final Map<String, ui.Image> _images = <String, ui.Image>{};
  final Map<String, AssetLoadFailure> _failures = <String, AssetLoadFailure>{};

  /// 已成功解码的图像数。
  int get loadedCount => _images.length;

  /// 载入失败记录（协议 §7：一次性记录 asset ID，不无限重试）。
  List<AssetLoadFailure> get failures =>
      List<AssetLoadFailure>.unmodifiable(_failures.values);

  bool get hasFailures => _failures.isNotEmpty;

  /// 预载某个加载分组的全部图形。
  ///
  /// 单个资源失败不会中断整体加载 —— 表现层会回退到矢量占位图形，
  /// 规则完全不受影响（架构 §7）。
  Future<void> loadGroup(AssetLoadGroup group) async {
    for (final record in manifest.inLoadGroup(group)) {
      if (!record.isVisual) {
        continue;
      }
      for (final file in record.runtimeFiles) {
        await _loadFile(record.assetId.value, file);
      }
    }
  }

  /// Flame 的图片加载会**自动加上**这个前缀。
  ///
  /// ⚠️ F-26-02 的根因就在这里：manifest 的 `runtimeFiles` 存的是
  /// **完整**的 Flutter 资源路径（`assets/images/v2/xxx.png`），
  /// 而 `Flame.images.load()` 会再拼一次 `assets/images/`，
  /// 于是实际请求变成 `assets/images/assets/images/v2/xxx.png` ——
  /// **全部 84 个资源加载失败、0 成功**，战场上一切都退回程序化占位
  /// 图形（玩家看到的"两个圆点 + 紫色三角形"）。
  ///
  /// 因此调用 Flame 前必须**剥掉**这个前缀。
  static const String kFlameImagesPrefix = 'assets/images/';

  Future<void> _loadFile(String assetId, String path) async {
    if (_images.containsKey(path) || _failures.containsKey(path)) {
      return; // 已加载或已失败：不重试
    }
    try {
      // 记录用**完整路径**（与 manifest 一致），加载用去前缀路径。
      final loadPath = path.startsWith(kFlameImagesPrefix)
          ? path.substring(kFlameImagesPrefix.length)
          : path;
      final image = await Flame.images.load(loadPath);
      _images[path] = image;
    } catch (error) {
      _failures[path] = AssetLoadFailure(assetId, path, '$error');
    }
  }

  /// 按「Asset ID + 渲染状态」取图。
  ///
  /// 状态为空时取记录的第一个运行时文件。找不到返回 null，
  /// 由调用方回退到矢量占位图形。
  ui.Image? imageFor(String? assetIdValue, String? state) {
    if (assetIdValue == null) {
      return null;
    }
    final assetId = AssetId.tryParse(assetIdValue);
    if (assetId == null) {
      return null;
    }
    final record = manifest[assetId];
    if (record == null) {
      return null;
    }

    final files = state != null
        ? (record.renderStates[state]?.runtimeFiles ?? record.runtimeFiles)
        : record.runtimeFiles;
    for (final file in files) {
      final image = _images[file];
      if (image != null) {
        return image;
      }
    }

    // 回退链：先试记录自带的首个可用文件，再试统一回退资源。
    for (final file in record.runtimeFiles) {
      final image = _images[file];
      if (image != null) {
        return image;
      }
    }
    final fallbackId = AssetId.tryParse(record.fallbackAssetId);
    if (fallbackId != null) {
      final fallback = manifest[fallbackId];
      if (fallback != null) {
        for (final file in fallback.runtimeFiles) {
          final image = _images[file];
          if (image != null) {
            return image;
          }
        }
      }
    }
    return null;
  }

  /// 该资源的锚点（默认居中）。
  List<double> anchorFor(String? assetIdValue, String? state) {
    if (assetIdValue == null) {
      return const <double>[0.5, 0.5];
    }
    final assetId = AssetId.tryParse(assetIdValue);
    if (assetId == null) {
      return const <double>[0.5, 0.5];
    }
    final record = manifest[assetId];
    if (record == null) {
      return const <double>[0.5, 0.5];
    }
    final spec = state == null ? null : record.renderStates[state];
    return spec?.anchor ?? const <double>[0.5, 0.5];
  }

  void clear() {
    _images.clear();
    _failures.clear();
  }
}
