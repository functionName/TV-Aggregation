// 本地 CORS 代理 —— 对齐旧 Veliora server.mjs /proxy/
// Web 调试时浏览器只访问同源/本机代理，由本进程去拉豆瓣与采集源。
//
// 用法: dart run tool/web_proxy.dart
// 默认:
//   http://127.0.0.1:8091/proxy/<encodeURIComponent(url)>
//   http://127.0.0.1:8091/m3u8/<encodeURIComponent(m3u8Url)>  ← 去广告后的播放列表

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:yingshi_daquan/services/m3u8_ad_filter.dart';

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

final _client = http.Client();

Future<Response> _handle(Request request) async {
  if (request.method == 'OPTIONS') {
    return Response.ok('', headers: _cors());
  }

  final path = request.url.path.replaceFirst(RegExp(r'^/'), '');
  // /pl.m3u8?u=…（推荐，后缀必须是 .m3u8）或兼容旧 /m3u8?u= /m3u8/<encode>
  final isM3u8Route = path == 'pl.m3u8' ||
      path == 'm3u8' ||
      path.startsWith('m3u8/');
  if (isM3u8Route) {
    final origin =
        '${request.requestedUri.scheme}://${request.requestedUri.host}:${request.requestedUri.port}';
    final fromQuery = request.url.queryParameters['u'];
    if (fromQuery != null && fromQuery.isNotEmpty) {
      return _handleM3u8Target(fromQuery, proxyOrigin: origin);
    }
    if (path.startsWith('m3u8/')) {
      return _handleM3u8(path.substring('m3u8/'.length), proxyOrigin: origin);
    }
    return Response(400,
        body: '缺少 u 参数',
        headers: {..._cors(), 'content-type': 'text/plain'});
  }
  if (!path.startsWith('proxy/')) {
    return Response.ok(
      '影视聚合 Web 代理\n'
      '  /proxy/<encodeURIComponent(url)>\n'
      '  /pl.m3u8?u=<encodeURIComponent(m3u8Url)>  (去广告播放列表)\n',
      headers: {..._cors(), 'content-type': 'text/plain; charset=utf-8'},
    );
  }

  final encoded = path.substring('proxy/'.length);
  if (encoded.isEmpty) {
    return Response(400,
        body: '缺少目标 URL', headers: {..._cors(), 'content-type': 'text/plain'});
  }

  late final String target;
  try {
    target = Uri.decodeComponent(encoded);
  } catch (_) {
    return Response(400,
        body: '无效的 URL 编码', headers: {..._cors(), 'content-type': 'text/plain'});
  }

  return _proxyGet(target);
}

Future<Response> _handleM3u8(String encoded, {required String proxyOrigin}) async {
  if (encoded.isEmpty) {
    return Response(400,
        body: '缺少 m3u8 URL',
        headers: {..._cors(), 'content-type': 'text/plain'});
  }
  late final String target;
  try {
    target = Uri.decodeComponent(encoded);
  } catch (_) {
    return Response(400,
        body: '无效的 URL 编码',
        headers: {..._cors(), 'content-type': 'text/plain'});
  }
  return _handleM3u8Target(target, proxyOrigin: proxyOrigin);
}

Future<Response> _handleM3u8Target(
  String target, {
  required String proxyOrigin,
}) async {
  final uri = Uri.tryParse(target);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return Response(400,
        body: '仅允许 http/https',
        headers: {..._cors(), 'content-type': 'text/plain'});
  }

  try {
    var playUrl = target;
    var text = await _fetchText(playUrl);
    final variant = M3u8AdFilter.pickBestVariant(text, playUrl);
    if (variant != null) {
      playUrl = variant;
      text = await _fetchText(playUrl);
    }
    if (!text.contains('#EXTINF')) {
      // 非媒体列表，原样返回（相对路径保持，交给播放器按源站解析）
      return Response.ok(
        text,
        headers: {
          ..._cors(),
          'content-type': 'application/vnd.apple.mpegurl',
          'cache-control': 'no-cache',
        },
      );
    }
    final before = text;
    var filtered = M3u8AdFilter.filter(text, baseUrl: playUrl);
    filtered = M3u8AdFilter.absolutize(filtered, playUrl);
    // 分片也走本机代理：列表在 8091、ts 直连 CDN 会被浏览器当跨域媒体拒掉
    filtered = _proxifyPlaylistUrls(filtered, proxyOrigin);
    final beforeInf = RegExp(r'#EXTINF').allMatches(before).length;
    final afterInf = RegExp(r'#EXTINF').allMatches(filtered).length;
    stderr.writeln(
      'm3u8 filter: $beforeInf -> $afterInf segments (${beforeInf - afterInf} dropped) $playUrl',
    );
    return Response.ok(
      filtered,
      headers: {
        ..._cors(),
        'content-type': 'application/vnd.apple.mpegurl',
        'cache-control': 'no-cache',
      },
    );
  } catch (e) {
    stderr.writeln('m3u8 filter error: $target -> $e');
    return Response(502,
        body: 'm3u8 处理失败: $e',
        headers: {..._cors(), 'content-type': 'text/plain; charset=utf-8'});
  }
}

/// 把播放列表里的 http(s) 分片 / URI= 改成本机 /proxy/，与列表同源
String _proxifyPlaylistUrls(String m3u8, String proxyOrigin) {
  final out = <String>[];
  for (final line in m3u8.split('\n')) {
    final raw = line.replaceAll('\r', '');
    final t = raw.trim();
    if (t.isEmpty) {
      out.add(raw);
      continue;
    }
    if (t.startsWith('#')) {
      out.add(raw.replaceAllMapped(
        RegExp(r'URI="(https?://[^"]+)"', caseSensitive: false),
        (m) {
          final u = m.group(1)!;
          if (u.startsWith(proxyOrigin)) return m.group(0)!;
          return 'URI="$proxyOrigin/proxy/${Uri.encodeComponent(u)}"';
        },
      ));
      continue;
    }
    if (t.startsWith('http://') || t.startsWith('https://')) {
      if (t.startsWith(proxyOrigin)) {
        out.add(t);
      } else {
        out.add('$proxyOrigin/proxy/${Uri.encodeComponent(t)}');
      }
    } else {
      out.add(raw);
    }
  }
  return out.join('\n');
}

Future<String> _fetchText(String url) async {
  final uri = Uri.parse(url);
  final res = await _client.get(uri, headers: {
    'User-Agent': _ua,
    'Accept': '*/*',
  }).timeout(const Duration(seconds: 20));
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception('HTTP ${res.statusCode}');
  }
  return utf8.decode(res.bodyBytes);
}

Future<Response> _proxyGet(String target) async {
  final uri = Uri.tryParse(target);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return Response(400,
        body: '仅允许 http/https', headers: {..._cors(), 'content-type': 'text/plain'});
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '127.0.0.1' || host == '0.0.0.0') {
    return Response(403,
        body: '禁止代理本地地址', headers: {..._cors(), 'content-type': 'text/plain'});
  }

  try {
    final isImage = RegExp(r'\.(jpg|jpeg|png|webp|gif)(\?|$)', caseSensitive: false)
        .hasMatch(target);
    final headers = <String, String>{
      'User-Agent': _ua,
      'Accept': isImage
          ? 'image/jpeg,image/png,image/webp,image/*;q=0.8,*/*;q=0.5'
          : 'application/json,text/plain,*/*',
    };
    if (target.contains('doubanio.com') || target.contains('douban.com')) {
      headers['Referer'] = 'https://movie.douban.com/';
    }

    final res = await _client.get(uri, headers: headers).timeout(
          const Duration(seconds: 20),
        );

    final out = <String, String>{
      ..._cors(),
      'content-type': res.headers['content-type'] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    };
    return Response(res.statusCode, body: res.bodyBytes, headers: out);
  } catch (e) {
    stderr.writeln('proxy error: $target -> $e');
    return Response(502,
        body: '代理失败: $e',
        headers: {..._cors(), 'content-type': 'text/plain; charset=utf-8'});
  }
}

Map<String, String> _cors() => {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': '*',
    };

Future<void> main(List<String> args) async {
  final port = int.tryParse(Platform.environment['PROXY_PORT'] ?? '') ?? 8091;
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(_handle);
  // 0.0.0.0：localhost / 127.0.0.1 都能连上
  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('Web proxy listening on http://localhost:${server.port}/');
  stdout.writeln('  /proxy/<url>       CORS 代理');
  stdout.writeln('  /pl.m3u8?u=<url>   HLS 去广告播放列表');
}
