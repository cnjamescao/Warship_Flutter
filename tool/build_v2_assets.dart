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

  // basename 唯一性是扁平化的前提 —— 不满足就必须失败，不能静默覆盖。
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
      final owner = seen[basename];
      if (owner != null) {
        failures.add('basename 冲突：$basename 同时属于 $owner 与 ${raw['assetId']}');
        continue;
      }
      seen[basename] = '${raw['assetId']}';

      final src = File('${root.path}/素材/$entry');
      if (!src.existsSync()) {
        failures.add('运行时文件缺失：$entry（${raw['assetId']}）');
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
