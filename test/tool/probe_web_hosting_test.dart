// ================================================================
// test/tool/probe_web_hosting_test.dart —— WEB-T-06
// ================================================================
// **架构位置**：工具层测试。验证静态托管探测**本身是对的**。
//
// **为什么要测"探测器"**：这个探测器的职责是**拦住**错误部署 ✗。
//   如果它自己"对什么都点头"，那比没有探测更糟 ——
//   它会给出**虚假的发布信心** ✓。因此这里重点测**反例**：
//   缺失资源必须真 404、MIME 必须精确、子路径必须隔离 ✓。
//
// 每条断言都能失败（R6.2）。
// ================================================================

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/probe_web_hosting.dart';

/// 造一个最小的假 Web 产物目录。
Future<Directory> fakeWebBuild() async {
  final dir = await Directory.systemTemp.createTemp('web_probe_');
  File('${dir.path}/index.html').writeAsStringSync('<html>ok</html>');
  File('${dir.path}/main.dart.mjs').writeAsStringSync('export {};');
  // wasm 只需存在且够大，内容不重要。
  File('${dir.path}/main.dart.wasm').writeAsBytesSync(
    List<int>.filled(2048, 0),
  );
  return dir;
}

void main() {
  test('WEB-T-06a MIME 表：.wasm 必须是 application/wasm', () {
    expect(mimeFor('main.dart.wasm'), 'application/wasm');
    expect(mimeFor('a.js'), contains('javascript'));
    expect(mimeFor('a.mjs'), contains('javascript'));
    expect(mimeFor('a.html'), contains('text/html'));
    // **未知扩展名不得被当成 HTML**（否则二进制会被浏览器当网页解析 ✗）。
    expect(mimeFor('weird.bin'), 'application/octet-stream');
  });

  test('WEB-T-06b 根路径托管：index 可加载、wasm MIME 正确、缺失真 404', () async {
    final dir = await fakeWebBuild();
    addTearDown(() => dir.deleteSync(recursive: true));

    final checks = await probeHosting(root: dir.path);
    final failures = checks.where((c) => !c.ok).toList();
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(checks, hasLength(3));
  });

  test('WEB-T-06c 子路径托管（/game/）同样三项都通过', () async {
    final dir = await fakeWebBuild();
    addTearDown(() => dir.deleteSync(recursive: true));

    final checks = await probeHosting(root: dir.path, prefix: '/game/');
    final failures = checks.where((c) => !c.ok).toList();
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('WEB-T-06d **缺失资源必须 404**，不能被 index.html 回退伪装', () async {
    final dir = await fakeWebBuild();
    addTearDown(() => dir.deleteSync(recursive: true));

    final server = await startStaticServer(root: dir.path);
    addTearDown(() => server.close(force: true));
    final r = await fetch(
      Uri.parse('http://127.0.0.1:${server.port}/nope.wasm'),
    );
    expect(r.status, 404, reason: '缺失资源不得返回 200（HTML 回退是常见坑 ✗）');
    // 也不能返回"看起来像成功"的大 HTML 体。
    expect(r.bytes, lessThan(200), reason: '不应返回完整 index.html');
  });

  test('WEB-T-06e 子路径外请求被拒（不会串到根目录）', () async {
    final dir = await fakeWebBuild();
    addTearDown(() => dir.deleteSync(recursive: true));

    final server = await startStaticServer(root: dir.path, prefix: '/game/');
    addTearDown(() => server.close(force: true));
    // 不在 /game/ 下的请求必须 404。
    final r = await fetch(
      Uri.parse('http://127.0.0.1:${server.port}/index.html'),
    );
    expect(r.status, 404, reason: '子路径托管时，根路径不应被服务');
  });
}
