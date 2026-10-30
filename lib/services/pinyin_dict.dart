import 'dart:convert';

import 'package:flutter/services.dart';

/// 离线全拼字表（与老版 pinyin-dict.js 同源）
class PinyinDict {
  PinyinDict._();
  static Map<String, String>? _map;
  static Future<void>? _loading;

  static Future<void> ensureLoaded() {
    if (_map != null) return Future.value();
    return _loading ??= () async {
      final raw =
          await rootBundle.loadString('assets/pinyin/pinyin_dict.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _map = {
          for (final e in decoded.entries) '${e.key}': '${e.value}',
        };
      } else {
        _map = {};
      }
    }();
  }

  /// 缓冲区开头能认出的音节 → { eat: 吃掉几个字母, chars: 候选字 }
  static ({int eat, List<String> chars}) segment(String buf) {
    final dict = _map ?? const {};
    if (buf.isEmpty) return (eat: 0, chars: const []);

    final maxN = buf.length < 6 ? buf.length : 6;
    for (var n = maxN; n > 0; n--) {
      final p = buf.substring(0, n);
      final chars = dict[p];
      if (chars != null && chars.isNotEmpty) {
        return (eat: n, chars: chars.split(''));
      }
    }
    for (var n = maxN; n > 0; n--) {
      final p = buf.substring(0, n);
      final lists = <List<String>>[];
      for (final e in dict.entries) {
        if (e.key.startsWith(p) && e.value.isNotEmpty) {
          lists.add(e.value.split(''));
        }
      }
      if (lists.isEmpty) continue;
      final out = <String>[];
      final seen = <String>{};
      var i = 0;
      while (lists.any((l) => i < l.length)) {
        for (final l in lists) {
          if (i < l.length && seen.add(l[i])) out.add(l[i]);
        }
        i++;
      }
      return (eat: n, chars: out);
    }
    return (eat: buf.length, chars: const []);
  }
}
