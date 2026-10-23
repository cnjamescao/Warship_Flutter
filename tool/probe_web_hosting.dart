// ================================================================
// tool/probe_web_hosting.dart —— 静态托管探测（WEB-T-06）
//
// **架构位置**：工具层（发布验收）。
//
// **为什么存在**：（请写清它解决什么问题、不解决什么问题）
//
// **与谁交互**：（上游 / 下游 / 数据流）
//
// **关键约束**：（不变量、时序、平台限制、易错点）
// ================================================================

// **关键约束**（WEB-T-06）：
//   * 根路径 `/` 与子路径（如 `/game/`）**都必须能加载** ✓；
//   * `.wasm` 必须返回 **`application/wasm`**（MIME 错了浏览器会拒绝
//     流式编译，退化成慢速路径甚至失败 ✗）；
//   * **缺失资源必须返回真实 404** —— 不能被"HTML 回退"伪装成 200，
//     否则脚本加载失败会表现为"页面白屏但服务器说一切正常" ✗
//     （这是 SPA 托管最常见的坑）。
//
// **为什么用自带的 `HttpServer` 而不是外部服务器**：探测必须**可重复、
// 可离线**；依赖 nginx/python 会让"这次通不通"取决于环境 ✗。
// 本脚本模拟的是**最小托管契约**，不是生产服务器配置 ✓。
// ================================================================

import 'dart:io';

/// MIME 表（**只列 Web 产物里会出现的类型**，避免"猜"）。
const Map<String, String> kMimeByExtension = <String, String>{
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.txt': 'text/plain; charset=utf-8',
};

/// 按扩展名取 MIME；未知扩展名返回 `application/octet-stream`
/// （**不猜** `text/html` —— 那会把二进制当网页返回，正是要防的坑 ✗）。
String mimeFor(String path) {
  final lower = path.toLowerCase();
  for (final entry in kMimeByExtension.entries) {
    if (lower.endsWith(entry.key)) {
      return entry.value;
    }
  }
  return 'application/octet-stream';
}

/// 探测结果的一条记录。
class ProbeCheck {
  const ProbeCheck(this.name, this.ok, this.detail);

  final String name;
  final bool ok;
  final String detail;

  @override
  String toString() => '${ok ? "✓" : "✗"} $name — $detail';
}

/// **启动一个最小静态服务器**（用于探测）。
///
/// [prefix] 非空时只服务该子路径（模拟"部署在 /game/ 下"）。
Future<HttpServer> startStaticServer({
  required String root,
  String prefix = '',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    var path = Uri.decodeComponent(req.uri.path);
    // 子路径托管：/game/xxx → xxx
    if (prefix.isNotEmpty) {
      if (!path.startsWith(prefix)) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      path = path.substring(prefix.length);
    }
    if (path.isEmpty || path == '/') {
      path = 'index.html';
    }
    final file = File('$root/$path');
    if (!file.existsSync()) {
      // **关键**：真实 404，**不回退**到 index.html ✗
      req.response.statusCode = HttpStatus.notFound;
      req.response.headers.contentType = ContentType.text;
      req.response.write('404 Not Found: $path');
      await req.response.close();
      return;
    }
    req.response.headers.set('content-type', mimeFor(path));
    req.response.add(await file.readAsBytes());
    await req.response.close();
  });
  return server;
}

/// 用 HTTP GET 取一条响应（供探测与测试复用）。
Future<({int status, String? contentType, int bytes})> fetch(
  Uri uri,
) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri);
    final res = await req.close();
    final body = await res.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    return (
      status: res.statusCode,
      contentType: res.headers.contentType?.toString(),
      bytes: body.length,
    );
  } finally {
    client.close(force: true);
  }
}

/// **执行 WEB-T-06 的全部探测**。
Future<List<ProbeCheck>> probeHosting({
  required String root,
  String prefix = '',
}) async {
  final checks = <ProbeCheck>[];
  final server = await startStaticServer(root: root, prefix: prefix);
  final port = server.port;
  final basePath = prefix.isEmpty ? '/' : prefix;
  try {
    // ① index.html 可加载。
    final index = await fetch(
      Uri.parse('http://127.0.0.1:$port$basePath'),
    );
    checks.add(ProbeCheck(
      'index.html 可加载（prefix="$prefix"）',
      index.status == 200 && index.bytes > 0,
      'status=${index.status}, ${index.bytes} bytes',
    ));

    // ② .wasm 的 MIME 必须正确。
    final wasm = await fetch(
      Uri.parse('http://127.0.0.1:$port${basePath}main.dart.wasm'),
    );
    checks.add(ProbeCheck(
      '.wasm MIME = application/wasm',
      wasm.contentType != null && wasm.contentType!.contains('application/wasm'),
      'status=${wasm.status}, content-type=${wasm.contentType}',
    ));

    // ③ 缺失资源必须真 404（不能是 200 的 HTML 回退）。
    final missing = await fetch(
      Uri.parse('http://127.0.0.1:$port${basePath}does-not-exist.wasm'),
    );
    checks.add(ProbeCheck(
      '缺失 .wasm 返回真实 404（不被 HTML 回退伪装）',
      missing.status == 404,
      'status=${missing.status}',
    ));
  } finally {
    await server.close(force: true);
  }
  return checks;
}

Future<void> main(List<String> args) async {
  final root = args.isNotEmpty ? args[0] : 'build/web';
  final prefix = args.length > 1 ? args[1] : '';
  if (!Directory(root).existsSync()) {
    stderr.writeln('✗ 目录不存在：$root —— 请先构建 Web 产物');
    exit(2);
  }
  stdout.writeln('== WEB-T-06 静态托管探测 ==');
  stdout.writeln('   root   : $root');
  stdout.writeln('   prefix : "${prefix.isEmpty ? "/" : prefix}"');
  final checks = await probeHosting(root: root, prefix: prefix);
  for (final c in checks) {
    stdout.writeln('  $c');
  }
  if (checks.every((c) => c.ok)) {
    stdout.writeln('✅ 全部通过');
    return;
  }
  stderr.writeln('❌ 存在失败项 —— RC 不得标记发布');
  exit(1);
}

