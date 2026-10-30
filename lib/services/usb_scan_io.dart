import 'dart:io';

import 'package:flutter/services.dart';

class ScanHit {
  const ScanHit({required this.ok, this.text, required this.message});
  final bool ok;
  final String? text;
  final String message;
}

const _channel = MethodChannel('yingshi_daquan/storage');

/// 优先走原生扫描（直接读 U 盘根目录文件），失败再 Dart 兜底
Future<ScanHit> scanUsbConfig() async {
  try {
    try {
      await _channel.invokeMethod<bool>('requestReadPermission');
    } catch (_) {}

    try {
      final raw = await _channel.invokeMethod<dynamic>('scanConfigJson');
      if (raw is Map) {
        final ok = raw['ok'] == true;
        final text = raw['text']?.toString();
        final message = raw['message']?.toString() ?? '';
        if (ok && text != null && text.trim().isNotEmpty) {
          return ScanHit(ok: true, text: text, message: message);
        }
        // 原生已扫过，把路径信息带回给 UI
        if (message.isNotEmpty) {
          return ScanHit(ok: false, message: message);
        }
      }
    } catch (_) {}

    // Dart 兜底：常见挂载点根目录精确文件名
    final hit = _scanDartFallback();
    if (hit.ok) return hit;
    return hit;
  } catch (e) {
    return ScanHit(ok: false, message: '扫描失败：$e');
  }
}

Future<String> readFile(String path) => File(path).readAsString();

ScanHit _scanDartFallback() {
  const names = [
    'veliora-sources.json',
    'veliora-sources.txt',
    'sources.json',
    'veliora-config.json',
  ];
  final roots = <String>{};
  const probes = [
    '/storage',
    '/mnt/media_rw',
    '/mnt/usb',
    '/mnt/udisk',
    '/mnt/usb_storage',
    '/mnt/usbotg',
  ];
  for (final p in probes) {
    try {
      final d = Directory(p);
      if (!d.existsSync()) continue;
      if (p == '/storage' || p == '/mnt/media_rw') {
        for (final e in d.listSync(followLinks: false)) {
          if (e is Directory) {
            final n = e.path.toLowerCase();
            if (n.contains('/self')) continue;
            roots.add(e.path);
          }
        }
      } else {
        roots.add(p);
      }
    } catch (_) {}
  }

  for (final root in roots) {
    for (final name in names) {
      try {
        final f = File('$root${Platform.pathSeparator}$name');
        if (!f.existsSync()) continue;
        final text = f.readAsStringSync();
        if (_looksLikeConfig(text)) {
          return ScanHit(ok: true, text: text, message: '已读取：${f.path}');
        }
      } catch (_) {}
    }
    // 根目录任意 json
    try {
      final d = Directory(root);
      for (final e in d.listSync(followLinks: false)) {
        if (e is! File) continue;
        final n = e.path.toLowerCase();
        if (!n.endsWith('.json')) continue;
        try {
          final text = e.readAsStringSync();
          if (_looksLikeConfig(text)) {
            return ScanHit(ok: true, text: text, message: '已读取：${e.path}');
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  return ScanHit(
    ok: false,
    message:
        '已扫 ${roots.length} 个目录仍未找到 veliora-sources.json。路径：${roots.take(8).join(" | ")}',
  );
}

bool _looksLikeConfig(String text) {
  final t = text.trim();
  if (!t.startsWith('{')) return false;
  return t.contains('Veliora-Settings') ||
      t.contains('LibreTV-Settings') ||
      t.contains('Veliora-Sources') ||
      t.contains('"sources"') ||
      t.contains('customAPIs');
}
