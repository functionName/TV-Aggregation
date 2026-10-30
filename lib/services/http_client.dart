import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 统一 HTTP。
/// - Android TV：直连目标站（无浏览器 CORS）
/// - Web：走本地代理 `tool/web_proxy.dart`（对齐旧 Veliora 的 /proxy/）
class AppHttp {
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 与 tool/web_proxy.dart 默认端口一致
  /// 与页面同用 localhost，避免 127.0.0.1 / localhost 被当成跨站
  static const webProxyOrigin = String.fromEnvironment(
    'WEB_PROXY',
    defaultValue: 'http://localhost:8091',
  );

  static final http.Client _client = http.Client();

  /// 豆瓣封面统一成 jpg，减少 Web 端 WebP 解码失败
  static String normalizeCover(String url) {
    if (url.isEmpty) return url;
    var u = url
        .replaceAll('/s_ratio_poster/', '/l_ratio_poster/')
        .replaceAll('/m_ratio_poster/', '/l_ratio_poster/');
    u = u.replaceAll('.webp', '.jpg');
    // 去掉查询串里的格式强制，避免拿到奇怪编码
    final uri = Uri.tryParse(u);
    if (uri != null && uri.path.toLowerCase().endsWith('.webp')) {
      u = uri.replace(path: '${uri.path.substring(0, uri.path.length - 5)}.jpg').toString();
    }
    return u;
  }

  /// Web 下把任意外链改成本地代理地址（接口 + 豆瓣封面都要用）
  static String proxied(String url) {
    if (!kIsWeb || url.isEmpty) return url;
    if (url.startsWith(webProxyOrigin)) return url;
    return '$webProxyOrigin/proxy/${Uri.encodeComponent(url)}';
  }

  static Future<http.Response> get(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final h = <String, String>{
      'Accept': 'application/json, text/plain, */*',
      if (!kIsWeb) 'User-Agent': userAgent,
      ...?headers,
    };

    final requestUrl = kIsWeb ? proxied(url) : url;
    final res =
        await _client.get(Uri.parse(requestUrl), headers: h).timeout(timeout);
    return res;
  }

  static Future<String> getText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final res = await get(url, headers: headers, timeout: timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return utf8.decode(res.bodyBytes);
  }

  static Future<dynamic> getJson(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final text = await getText(url, headers: headers, timeout: timeout);
    final decoded = jsonDecode(text);
    if (decoded is Map && decoded['contents'] is String) {
      return jsonDecode(decoded['contents'] as String);
    }
    return decoded;
  }

  static Map<String, String> doubanImageHeaders() => {
        if (!kIsWeb) 'Referer': 'https://movie.douban.com/',
        if (!kIsWeb) 'User-Agent': userAgent,
      };

  /// 给 CachedNetworkImage 用的最终 URL
  static String imageUrl(String url) => proxied(url);
}
