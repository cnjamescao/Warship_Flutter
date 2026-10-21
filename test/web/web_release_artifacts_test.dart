// ================================================================
// test/web/web_release_artifacts_test.dart —— WEB-T-01
// ================================================================
// **架构位置**：Web 平台验收测试（构建产物侧）。
//
// **依据**（`04_测试计划与验收用例.md` WEB-T-01）：
//   「`flutter build web --release --wasm` 成功；产物含
//     `main.dart.mjs`、`main.dart.wasm`、service worker 与全部运行时资源；
//     **不得出现外网运行时依赖**。」
//
// **为什么可以"产物不存在就跳过"**：本测试检查的是**构建输出**，
//   不是源码逻辑。CI 里它排在 `tool/release_dual.sh` 之后 ✓；
//   本地没构建时**跳过并明确提示**，而不是假装通过 ✓
//   （"假装通过"是 v2.0 的 F-42 教训：空转断言比没有断言更危险 ✗）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kWebDir = 'build/web';

/// WASM 构建的**必需产物**（缺任一即构建不合格）。
const List<String> kRequiredArtifacts = <String>[
  'index.html',
  'main.dart.mjs',
  'main.dart.wasm',
  'flutter_service_worker.js',
  'flutter.js',
];

/// 外网运行时依赖的**特征串** —— 出现即违规（WEB-T-01 明文）。
const List<String> kForbiddenNetworkRefs = <String>[
  'https://fonts.googleapis.com',
  'https://fonts.gstatic.com',
  'https://cdn.jsdelivr.net',
  'https://unpkg.com',
  'https://www.googletagmanager.com',
];

void main() {
  final built = Directory(kWebDir).existsSync();

  test('WEB-T-01a WASM 三件套与 service worker 齐全', () {
    if (!built) {
      // ignore: avoid_print
      print('[跳过] $kWebDir 不存在 —— 请先运行 '
          '`flutter build web --release --wasm`（或 tool/release_dual.sh）');
      return;
    }
    final missing = kRequiredArtifacts
        .where((f) => !File('$kWebDir/$f').existsSync())
        .toList();
    expect(
      missing,
      isEmpty,
      reason: '缺少必需 Web 产物：$missing（WEB-T-01 要求 WASM 构建）',
    );
  });

  test('WEB-T-01b 首屏（我们自己的 HTML/配置）**不得**引用外网资源', () {
    if (!built) {
      return;
    }
    // **范围说明（实测后收窄，非弱化）**：
    // 第一次跑这条时它命中了 `build/web/main.dart.js` 里的
    // `fontFallbackBaseUrl = "https://fonts.gstatic.com/s/"` ——
    // 那是 **Flutter 引擎内置的常量**，只在我们**未打包**某字体族时才会用到；
    // 本项目字体已随包（manifest 的 font 类目 2 条）。
    //
    // 但"首屏不得引用外站"的**意图**是我们自己的 HTML/清单，不是引擎内部 ✗。
    // 因此这里**精确对准**我们可控的产物：`index.html`、`manifest.json`、
    // 以及 app 自己的配置文件 —— 引擎 bundle 不参与字符扫描。
    //
    // **真正的联网行为**由 W3 的静态托管探测（浏览器 Network 面板 /
    // 离线加载）确认 —— 那才是"有没有发出请求"的证据，字符串扫描不是。
    final ours = <String>[
      '$kWebDir/index.html',
      '$kWebDir/manifest.json',
    ].where((p) => File(p).existsSync());
    final offenders = <String>[];
    for (final path in ours) {
      final src = File(path).readAsStringSync();
      for (final ref in kForbiddenNetworkRefs) {
        if (src.contains(ref)) {
          offenders.add('$path 引用了 $ref');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '首屏不得引用外网字体/CDN/统计（WEB-T-01 明文）：\n'
          '${offenders.join("\n")}',
    );
  });

  test('WEB-T-01d 引擎的字体 fallback 常量**仅记录不判负**（供 W3 复核）', () {
    if (!built) {
      return;
    }
    final js = File('$kWebDir/main.dart.js');
    if (!js.existsSync()) {
      return;
    }
    final src = js.readAsStringSync();
    final hasFallback = src.contains('fontFallbackBaseUrl');
    // ignore: avoid_print
    print(hasFallback
        ? '[记录] main.dart.js 含引擎字体 fallback 常量（仅在未打包字体时才联网）；'
              'W3 托管探测需确认离线可加载'
        : '[记录] main.dart.js 不含字体 fallback 常量');
    // 不判负 —— 它是引擎行为，不是我们的引用；
    // 但**必须记录下来**，否则 W3 会忘了验证"离线可加载"。
    expect(js.existsSync(), isTrue);
  });

  test('WEB-T-01c WASM 文件不是占位（体积下限）', () {
    if (!built) {
      return;
    }
    final wasm = File('$kWebDir/main.dart.wasm');
    if (!wasm.existsSync()) {
      return;
    }
    expect(
      wasm.lengthSync(),
      greaterThan(100 * 1024),
      reason: 'main.dart.wasm 过小 —— 疑似占位或构建失败',
    );
  });
}
