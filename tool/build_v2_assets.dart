// ================================================================
// tool/build_v2_assets.dart —— v2.0 资源构建复制
// ================================================================
// 依据：Spec/开发者交付清单.md §3.1
//   「构建时将 素材/manifest.json 及 manifest 引用的资源复制到应用的
//     assets/config/v2/ 和运行时资源目录。」
//   03_素材/…规范 §1
//   「运行时导出由工程复制至 assets/images/v2/、assets/audio/v2/；
//     内容配置通过 Asset ID 查 manifest，不允许在代码中硬写素材路径。」
//
// 本脚本做三件事，且**只**做这三件事：
//   1. 读取仓库根目录 素材/manifest.json（唯一正式索引）；
//   2. 按类别把每个 runtimeFiles 复制到
//        graphic/ui → assets/images/v2/<basename>
//        sfx/bgm    → assets/audio/v2/<basename>
//      运行时文件的 basename 全局唯一（构建时已校验），因此扁平化是安全的，
//      也让 Flutter 只需声明两个平铺目录即可覆盖全部资源；
//   3. 写出 assets/config/v2/manifest.json —— 它是**构建复制品**，
//      其中 runtimeFiles 已改写为 Flutter 资源键。
//
// 运行时永远只读取复制品里的 runtimeFiles 字段，不自行拼接路径、
// 也不按文件名推断，因此满足"不硬编码路径、不猜资源"的约束。
//
// 用法：
//   dart run tool/build_v2_assets.dart
// ================================================================

import 'dart:convert';
import 'dart:io';

const String kSourceManifest = '素材/manifest.json';

/// **v2.1 交付源根目录**（蓝图 §2.1：「根目录 `素材/v2.1` 是**交付源**，
/// 不是运行时目录；构建脚本必须复制/打包审核通过的文件到 manifest 路径」）。
///
/// 解析顺序：**先在 `素材/v2.1/` 找，再回落到 `素材/`** ——
/// v2.1 保留了全部 v2.0 素材（199 条）并新增 33 条，
/// 因此两者都要能解析，且**新文件以 `素材/v2.1/` 为准**（防止误用旧副本）。
const String kV21SourceRoot = '素材/v2.1';
const String kLegacySourceRoot = '素材';
const String kTargetManifest = 'assets/config/v2/manifest.json';
const String kImageDir = 'assets/images/v2';
const String kAudioDir = 'assets/audio/v2';

void main(List<String> args) {
  final root = Directory.current;
  final source = File('${root.path}/$kSourceManifest');
  if (!source.existsSync()) {
    stderr.writeln('✗ 找不到正式资源索引：$kSourceManifest');
    exitCode = 1;
    return;
  }

  final decoded = jsonDecode(source.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    stderr.writeln('✗ manifest 顶层必须是对象');
    exitCode = 1;
    return;
  }

  final contentVersion = decoded['contentVersion'];
  stdout.writeln('内容版本：$contentVersion');

  // **basename 唯一性（v2.1 放宽）**。
  //
  // 背景：v2.0 是"**每帧一个 PNG**"，一个 basename 只属于一个 Asset，
  // 因此"basename 全局唯一"是扁平化复制的前提。
  //
  // v2.1 改为"**整张 sheet + 每个子图的 frameRect**"模型
  // （素材规范 §2/§4.2），**多组 Asset ID 共用同一张 sheet** 是其固有形态：
  // 5 个武器形态共用 `GFX-V21-WEAPON-STYLES-SHEET.png`，
  // 5 个命中共用 `…-IMPACTS-SHEET.png`，3 个通知、3 个奖章同理。
  //
  // 若仍强制"basename 全局唯一"，只能按 ID 复制 N 份 ——
  // 实测会额外膨胀 **约 70 MB（12×）**，且同一张图可能在内存中被加载多次。
  //
  // 因此判据放宽为：**同一个 basename 只允许来自同一个源文件**
  // （即真正共享同一张图）；**不同源文件撞名仍然必须失败**，
  // 那条"不能静默覆盖"的保护完整保留。
  //
  // 值 = 该 basename 首次出现时的**源文件相对路径**。
  final seen = <String, String>{};
  final assets = (decoded['assets'] as List?) ?? const <Object?>[];

  var copiedImages = 0;
  var copiedAudio = 0;
  var copiedBytes = 0;
  final failures = <String>[];

  Directory(kImageDir).createSync(recursive: true);
  Directory(kAudioDir).createSync(recursive: true);
  Directory(File(kTargetManifest).parent.path).createSync(recursive: true);

  for (final raw in assets) {
    if (raw is! Map) {
      continue;
    }
    final category = raw['category'];
    final isVisual = category == 'graphic' || category == 'ui';
    final isAudio = category == 'sfx' || category == 'bgm';
    if (!isVisual && !isAudio) {
      // font 声明没有物理运行时文件，跳过。
      continue;
    }

    final targetDir = isVisual ? kImageDir : kAudioDir;
    final runtimeFiles = (raw['runtimeFiles'] as List?) ?? const <Object?>[];
    final rewritten = <String>[];

    for (final entry in runtimeFiles) {
      if (entry is! String) {
        continue;
      }
      final basename = entry.split('/').last;
      final ownerSource = seen[basename];
      if (ownerSource != null) {
        if (ownerSource == entry) {
          // **同一张 sheet 被多个 Asset ID 共享** —— v2.1 的正常形态。
          // 只复制一次（首次已复制），这里把它登记进本条的运行时文件即可。
          rewritten.add('$targetDir/$basename');
          continue;
        }
        // 不同源文件撞名 —— 这才是真正的冲突，仍然必须失败。
        failures.add(
          'basename 冲突：$basename 同时来自 $ownerSource 与 $entry'
          '（${raw['assetId']}）',
        );
        continue;
      }
      seen[basename] = entry;

      // 多根解析：v2.1 交付源优先，其次 v2.0 历史源。
      final v21 = File('${root.path}/$kV21SourceRoot/$entry');
      final legacy = File('${root.path}/$kLegacySourceRoot/$entry');
      final src = v21.existsSync() ? v21 : legacy;
      if (!src.existsSync()) {
        failures.add(
          '运行时文件缺失：$entry（${raw['assetId']}）—— '
          '已查找 $kV21SourceRoot/ 与 $kLegacySourceRoot/',
        );
        continue;
      }
      final targetPath = '$targetDir/$basename';
      src.copySync(targetPath);
      copiedBytes += src.lengthSync();
      if (isVisual) {
        copiedImages++;
      } else {
        copiedAudio++;
      }
      rewritten.add(targetPath);
    }

    // 只改写指向带状态文件的字段，其它字段原样保留。
    raw['runtimeFiles'] = rewritten;
    final renderStates = raw['renderStates'];
    if (renderStates is Map) {
      for (final stateValue in renderStates.values) {
        if (stateValue is! Map) {
          continue;
        }
        final stateFiles = (stateValue['runtimeFiles'] as List?) ?? const [];
        stateValue['runtimeFiles'] = stateFiles
            .whereType<String>()
            .map((p) => '$kImageDir/${p.split('/').last}')
            .toList();
      }
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('✗ 构建复制失败：');
    for (final failure in failures.take(20)) {
      stderr.writeln('   - $failure');
    }
    if (failures.length > 20) {
      stderr.writeln('   …共 ${failures.length} 条');
    }
    exitCode = 1;
    return;
  }

  File(kTargetManifest).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(decoded),
  );

  stdout.writeln('✓ 图形/UI：$copiedImages 个 → $kImageDir/');
  stdout.writeln('✓ 音频　　：$copiedAudio 个 → $kAudioDir/');
  stdout.writeln('✓ 清单　　：$kTargetManifest');
  stdout.writeln('  合计 ${(copiedBytes / 1048576).toStringAsFixed(2)} MiB');
}
