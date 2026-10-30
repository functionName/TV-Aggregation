import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'usb_scan_stub.dart' if (dart.library.io) 'usb_scan_io.dart' as usb_scan;

class UsbImportResult {
  const UsbImportResult({
    required this.ok,
    this.text,
    required this.message,
  });
  final bool ok;
  final String? text;
  final String message;
}

/// 从 U 盘 / 剪贴板 / 路径 / 文件选择器读取配置 JSON
class UsbConfigImporter {
  /// Android TV：优先扫 U 盘（限时），失败不卡在系统文件选择器。
  /// Web / 桌面：可用文件选择。
  static Future<UsbImportResult> import() async {
    if (!kIsWeb) {
      final scanned = await usb_scan.scanUsbConfig();
      if (scanned.ok) {
        return UsbImportResult(
          ok: true,
          text: scanned.text,
          message: scanned.message,
        );
      }
      // 电视上系统文件选择器经常无界面/无焦点，直接返回扫描结果，由 UI 提供剪贴板/路径兜底
      if (defaultTargetPlatform == TargetPlatform.android) {
        return UsbImportResult(
          ok: false,
          message: scanned.message.isNotEmpty
              ? scanned.message
              : '未在 U 盘找到配置文件',
        );
      }
    }
    return _pickFile(
      fallbackHint: kIsWeb
          ? '请选择配置 JSON 文件'
          : '未在 U 盘找到配置。请把 veliora-sources.json 放在 U 盘根目录，或粘贴 JSON。',
    );
  }

  /// 从系统剪贴板读取配置
  static Future<UsbImportResult> fromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        return const UsbImportResult(ok: false, message: '剪贴板为空');
      }
      if (!_looksLikeConfig(text)) {
        return const UsbImportResult(
          ok: false,
          message: '剪贴板内容不是有效配置 JSON',
        );
      }
      return UsbImportResult(ok: true, text: text, message: '已从剪贴板读取');
    } catch (e) {
      return UsbImportResult(ok: false, message: '读取剪贴板失败：$e');
    }
  }

  /// 按绝对路径读文件（电视可手动输入 /storage/XXXX/xxx.json）
  static Future<UsbImportResult> fromPath(String path) async {
    final p = path.trim();
    if (p.isEmpty) {
      return const UsbImportResult(ok: false, message: '路径为空');
    }
    if (kIsWeb) {
      return const UsbImportResult(ok: false, message: 'Web 不支持按路径读取');
    }
    try {
      final text = await usb_scan.readFile(p);
      if (text.trim().isEmpty) {
        return const UsbImportResult(ok: false, message: '文件为空');
      }
      if (!_looksLikeConfig(text)) {
        return const UsbImportResult(ok: false, message: '不是有效的配置文件');
      }
      return UsbImportResult(ok: true, text: text, message: '已读取：$p');
    } catch (e) {
      return UsbImportResult(ok: false, message: '读取失败：$e');
    }
  }

  static Future<UsbImportResult> pickFile() => _pickFile();

  static Future<UsbImportResult> _pickFile({String? fallbackHint}) async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
      if (files.isEmpty) {
        return UsbImportResult(ok: false, message: fallbackHint ?? '已取消');
      }
      final f = files.first;
      String? text;
      try {
        final bytes = await f.readAsBytes();
        text = utf8.decode(bytes);
      } catch (_) {
        if (f.path != null && !kIsWeb) {
          text = await usb_scan.readFile(f.path!);
        }
      }
      if ((text == null || text.isEmpty) && f.path != null && !kIsWeb) {
        try {
          text = await usb_scan.readFile(f.path!);
        } catch (_) {}
      }
      if (text == null || text.trim().isEmpty) {
        return const UsbImportResult(ok: false, message: '文件为空或无法读取');
      }
      if (text.length > 10 * 1024 * 1024) {
        return const UsbImportResult(ok: false, message: '文件超过 10MB');
      }
      if (!_looksLikeConfig(text)) {
        return const UsbImportResult(ok: false, message: '不是有效的配置文件');
      }
      return UsbImportResult(ok: true, text: text, message: '已读取：${f.name}');
    } catch (e) {
      return UsbImportResult(ok: false, message: '选择文件失败：$e');
    }
  }

  static bool _looksLikeConfig(String text) {
    final t = text.trim();
    if (!t.startsWith('{')) return false;
    return t.contains('Veliora-Settings') ||
        t.contains('LibreTV-Settings') ||
        t.contains('Veliora-Sources') ||
        t.contains('"sources"') ||
        t.contains('customAPIs');
  }
}
