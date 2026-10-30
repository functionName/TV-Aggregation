import 'dart:io';

import 'package:flutter/foundation.dart';

/// App 内环回服务：只提供改写后的 m3u8 文本。装包即用，无独立进程。
class M3u8PlaylistServer {
  M3u8PlaylistServer._();

  static HttpServer? _server;
  static int? _port;
  static final _playlists = <String, String>{};
  static var _seq = 0;

  static Future<void> ensureStarted() async {
    if (kIsWeb) return;
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    server.listen((req) async {
      try {
        final path = req.uri.path;
        final m = RegExp(r'^/pl/([a-zA-Z0-9]+)\.m3u8$').firstMatch(path);
        if (m == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final body = _playlists[m.group(1)];
        if (body == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.headers.set('Access-Control-Allow-Origin', '*');
        req.response.write(body);
        await req.response.close();
      } catch (_) {
        try {
          req.response.statusCode = 500;
          await req.response.close();
        } catch (_) {}
      }
    });
  }

  static Future<String> register(String m3u8Body) async {
    await ensureStarted();
    final id = 'p${_seq++}${DateTime.now().millisecondsSinceEpoch}';
    _playlists[id] = m3u8Body;
    if (_playlists.length > 24) {
      final keys = _playlists.keys.toList()..sort();
      for (final k in keys.take(_playlists.length - 16)) {
        _playlists.remove(k);
      }
    }
    return 'http://127.0.0.1:$_port/pl/$id.m3u8';
  }
}
