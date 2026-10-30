import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// 局域网手机配置页
class PhoneConfigServer {
  PhoneConfigServer._();
  static const port = 8765;

  static HttpServer? _server;
  static String Function()? _getConfig;
  static Future<void> Function(String body)? _applyConfig;
  static String? _lastApplyError;
  static bool _lastApplyOk = true;

  static bool get isRunning => _server != null;
  static bool get supported => true;

  static const _jsonHeaders = {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  };

  static const _corsHeaders = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'Content-Type, Accept',
    'access-control-max-age': '86400',
  };

  static Future<List<String>> start({
    required String Function() getConfig,
    required Future<void> Function(String body) applyConfig,
  }) async {
    await stop();
    _getConfig = getConfig;
    _applyConfig = applyConfig;
    _lastApplyError = null;
    _lastApplyOk = true;
    final html =
        await rootBundle.loadString('assets/mobile/mobile-config.html');

    final handler = const Pipeline()
        .addMiddleware(_cors())
        .addHandler((req) async {
      final path = req.url.path;

      if (req.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }

      if (req.method == 'GET' &&
          (path.isEmpty || path == 'index.html' || path == '/')) {
        return Response.ok(
          html,
          headers: {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-store',
          },
        );
      }

      if (path == 'api/ping') {
        return Response.ok(
          jsonEncode({
            'ok': true,
            'running': true,
            'lastApplyOk': _lastApplyOk,
            'lastApplyError': _lastApplyError,
          }),
          headers: _jsonHeaders,
        );
      }

      if (path == 'api/config') {
        if (req.method == 'GET') {
          try {
            final raw = _getConfig?.call() ?? '{}';
            final map = jsonDecode(raw);
            final out = <String, dynamic>{
              'ok': true,
              'lastApplyOk': _lastApplyOk,
              if (_lastApplyError != null) 'lastApplyError': _lastApplyError,
            };
            if (map is Map) out.addAll(Map<String, dynamic>.from(map));
            return Response.ok(jsonEncode(out), headers: _jsonHeaders);
          } catch (e) {
            return Response.ok(
              jsonEncode({'ok': false, 'error': '$e'}),
              headers: _jsonHeaders,
            );
          }
        }
        if (req.method == 'POST') {
          return _handleSave(await req.readAsString());
        }
      }

      // 表单兜底：部分手机浏览器 fetch POST 会报 Load failed
      if (path == 'api/config/form' && req.method == 'POST') {
        final raw = await req.readAsString();
        final params = Uri.splitQueryString(raw, encoding: utf8);
        final body = params['json'] ?? params['body'] ?? raw;
        final save = await _handleSave(body);
        final ok = save.statusCode >= 200 && save.statusCode < 300;
        final msg = ok ? '已保存到电视，请回到电视点「完成」' : '保存失败，请重试';
        return Response.ok(
          '<!DOCTYPE html><html><head><meta charset="utf-8"/>'
          '<meta name="viewport" content="width=device-width,initial-scale=1"/>'
          '<title>保存结果</title></head><body style="font-family:sans-serif;'
          'background:#0b1220;color:#e8eef8;padding:24px">'
          '<h2>${ok ? '✅' : '❌'} $msg</h2>'
          '<p><a href="/" style="color:#3b82f6">返回继续编辑</a></p>'
          '</body></html>',
          headers: {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-store',
          },
        );
      }

      return Response.notFound('Not Found');
    });

    _server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    // 避免部分机型压缩/缓冲导致手机端异常断开
    _server!.autoCompress = false;
    return await lanUrls();
  }

  /// 先快速校验，再异步落盘，避免 HTTP 回调里走平台通道把连接卡死（手机端 Load failed）
  static Future<Response> _handleSave(String body) async {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw Exception('配置需为 JSON 对象');
      }
    } catch (e) {
      return Response(
        400,
        body: jsonEncode({'ok': false, 'message': 'JSON 无效：$e'}),
        headers: _jsonHeaders,
      );
    }

    final apply = _applyConfig;
    if (apply == null) {
      return Response(
        503,
        body: jsonEncode({'ok': false, 'message': '服务未就绪'}),
        headers: _jsonHeaders,
      );
    }

    // 让出事件循环后再写 SharedPreferences，并等待完成（最多 8 秒）
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await apply(body).timeout(const Duration(seconds: 8));
      _lastApplyOk = true;
      _lastApplyError = null;
      return Response.ok(
        jsonEncode({'ok': true, 'message': '已保存'}),
        headers: _jsonHeaders,
      );
    } on TimeoutException {
      _lastApplyOk = false;
      _lastApplyError = '保存超时';
      return Response(
        504,
        body: jsonEncode({'ok': false, 'message': '电视保存超时，请重试'}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      _lastApplyOk = false;
      _lastApplyError = '$e';
      debugPrint('PhoneConfigServer apply failed: $e');
      return Response(
        400,
        body: jsonEncode({'ok': false, 'message': '$e'}),
        headers: _jsonHeaders,
      );
    }
  }

  static Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _getConfig = null;
    _applyConfig = null;
  }

  static Future<List<String>> lanUrls() async {
    final ips = <String>[];
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final ni in list) {
        for (final a in ni.addresses) {
          if (a.isLoopback) continue;
          ips.add('http://${a.address}:$port');
        }
      }
    } catch (_) {}
    return ips;
  }

  static Middleware _cors() {
    return (inner) {
      return (req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: {
            ..._corsHeaders,
            ..._jsonHeaders,
          });
        }
        final res = await inner(req);
        // 只追加 CORS，避免破坏 Content-Length
        return res.change(headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'Content-Type, Accept',
        });
      };
    };
  }
}
