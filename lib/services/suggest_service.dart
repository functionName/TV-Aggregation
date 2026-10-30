import 'dart:convert';

import 'http_client.dart';

/// 片名联想：字母/全拼/首字母 → 中文片名（对齐老版 Veliora）
/// 采集源只认中文名，所以英文/拼音必须先联想。
class SuggestService {
  static final _cache = <String, Future<List<String>>>{};

  static final _noiseTail = RegExp(
    r'(在线观看|免费观看|免费在线|完整版|未删减|高清版|高清|全集|全剧|电视剧|电影版|电影|动漫|动画片|演员表|演员|分集剧情|剧情介绍|剧情|大结局|结局|解说|下载|百度百科|百科|小说原著|小说|原著|漫画|歌曲|图片|壁纸|资源|网盘|迅雷|免费|观看|上映时间|上映|什么时候|好看吗|评价|豆瓣|一共多少集|多少集|多少季|第[0-9一二三四五六七八九十]+集|[0-9]+集全|全[0-9]+集|爱奇艺|腾讯视频|优酷|芒果TV|哔哩哔哩|樱花动漫)$',
  );
  static final _noiseAny = RegExp(
    r'(什么意思|怎么读|怎么写|翻译成|音标|原曲|简谱|歌词|哪一年|哪个平台|在哪看|在哪播|多少集|多少季|好看吗|值得看|排行|排名|百度|知乎|贴吧|网盘|迅雷|资源|演员表|分集|剧情介绍|大结局|解说|花絮|片尾曲|主题曲|上映时间|取景地|拍摄地|原著小说)',
  );
  static final _seasonTail = RegExp(r'\s*第[0-9一二三四五六七八九十百]+[季部]$');
  static final _seasonish = RegExp(
    r'^(第[0-9一二三四五六七八九十百]+[季部]|[0-9]{1,2}|之.{1,10}|续集|外传|前传|后传|年番|动态漫画.*|粤语|国语|特别篇|剧场版|终章|完结篇)$',
    caseSensitive: false,
  );
  static final _cjk = RegExp(r'[\u4e00-\u9fff]');
  static const _videoTags = {
    '电视剧', '电影', '动漫', '动画', '综艺', '纪录片', '少儿', '短剧', '漫剧', '微剧', '系列',
  };
  static const _personTags = {'人物', '明星', '演员', '导演'};

  static bool hasCjk(String? s) => s != null && _cjk.hasMatch(s);

  static String cleanTitle(String? s) {
    var t = (s ?? '')
        .replaceAll(RegExp(r'[《》【】"“”‘’]'), '')
        .trim();
    for (var i = 0; i < 4; i++) {
      final n = t.replaceFirst(_noiseTail, '').trim();
      if (n.isEmpty || n == t) break;
      t = n;
    }
    return t;
  }

  static Future<List<String>> resolveTitles(String input) {
    final q = input.trim();
    if (q.isEmpty) return Future.value(const []);
    final key = q.toLowerCase();
    return _cache.putIfAbsent(key, () {
      final job = _resolve(key, q);
      job.catchError((_) {
        _cache.remove(key);
        return <String>[];
      });
      return job;
    });
  }

  static Future<List<String>> _resolve(String key, String q) async {
    final ascii = !hasCjk(q);
    final engines = ascii
        ? [
            _fromDouban(key),
            _fromIqiyi(key),
            _fromBaidu(key),
          ]
        : [
            _fromDouban(q),
            _fromIqiyi(q),
          ];

    final lists = await Future.wait(
      engines.map((e) => e.catchError((_) => <_Hit>[])),
    );

    final scored = <String, int>{};
    for (var engineIdx = 0; engineIdx < lists.length; engineIdx++) {
      final list = lists[engineIdx];
      for (var i = 0; i < list.length; i++) {
        final t = list[i].title;
        if (t.length < 2 || t.length > 24) continue;
        if (_noiseAny.hasMatch(t)) continue;
        if (ascii && !hasCjk(t)) continue;
        final score = list[i].weight * 100 + engineIdx * 10 + i;
        final prev = scored[t];
        if (prev == null || score < prev) scored[t] = score;
      }
    }

    final ordered = scored.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return _dropNoise(_withCommonPrefix(ordered.map((e) => e.key).toList()))
        .take(12)
        .toList();
  }

  /// 字母输入 → 实际搜索词。primary 必搜，fallback 仅在无结果时补搜。
  static Future<({List<String> primary, List<String> fallback})>
      buildSearchQueries(String raw) async {
    if (hasCjk(raw)) {
      return (primary: [raw], fallback: <String>[]);
    }
    List<String> titles = const [];
    try {
      titles = await resolveTitles(raw);
    } catch (_) {}
    final bases = <String>[];
    final fulls = <String>[];
    for (final t in titles.where(hasCjk)) {
      final b = t.replaceFirst(_seasonTail, '').trim();
      final base = b.isEmpty ? t : b;
      if (base.length >= 2 && hasCjk(base) && !bases.contains(base)) {
        bases.add(base);
      }
      if (t != base && !fulls.contains(t)) fulls.add(t);
    }
    final ranked = [...bases, ...fulls];
    if (ranked.isEmpty) {
      return (primary: [raw], fallback: <String>[]);
    }
    return (
      primary: ranked.take(1).toList(),
      fallback: [...ranked.skip(1).take(2), raw],
    );
  }

  static Future<List<_Hit>> _fromIqiyi(String q) async {
    final txt = await AppHttp.getText(
      'https://suggest.video.iqiyi.com/?if=mobile&key=${Uri.encodeComponent(q)}',
      timeout: const Duration(seconds: 6),
    );
    final data = jsonDecode(txt);
    if (data is! Map) return [];
    final out = <_Hit>[];
    final list = data['data'];
    if (list is! List) return [];
    for (final it in list) {
      if (it is! Map) continue;
      final pe = it['presentation_element'];
      final peMap = pe is Map ? pe : const {};
      final tags = <String>[];
      final rawTags = peMap['tags'];
      if (rawTags is List) {
        for (final t in rawTags) {
          if (t is Map && t['name'] != null) tags.add('${t['name']}');
        }
      }
      if (tags.any(_personTags.contains)) continue;
      final cname = '${it['cname'] ?? ''}';
      final isVideo =
          tags.any(_videoTags.contains) || _videoTags.contains(cname);
      final name = '${it['name'] ?? ''}';
      out.add(_Hit(cleanTitle(name), isVideo ? 0 : 2));
      final zh = '${peMap['show_reason'] ?? ''}';
      if (!hasCjk(name) &&
          hasCjk(zh) &&
          zh.length <= 20 &&
          !RegExp(r'[\/、《]').hasMatch(zh)) {
        out.add(_Hit(cleanTitle(zh), isVideo ? 0 : 2));
      }
    }
    return out;
  }

  static Future<List<_Hit>> _fromBaidu(String q) async {
    final txt = await AppHttp.getText(
      'https://suggestion.baidu.com/su?ie=utf-8&json=1&p=3&wd=${Uri.encodeComponent(q)}',
      timeout: const Duration(seconds: 6),
    );
    final m = RegExp(r'\{[\s\S]*\}').firstMatch(txt);
    if (m == null) return [];
    final data = jsonDecode(m.group(0)!);
    if (data is! Map) return [];
    final raw = <dynamic>[];
    if (data['g'] is List) {
      raw.addAll(data['g'] as List);
    } else if (data['s'] is List) {
      raw.addAll(data['s'] as List);
    }
    return raw.map((e) {
      final s = e is Map ? '${e['q'] ?? e}' : '$e';
      return _Hit(cleanTitle(s), 1);
    }).toList();
  }

  static Future<List<_Hit>> _fromDouban(String q) async {
    final data = await AppHttp.getJson(
      'https://movie.douban.com/j/subject_suggest?q=${Uri.encodeComponent(q)}',
      timeout: const Duration(seconds: 4),
    );
    if (data is! List) return [];
    return data
        .whereType<Map>()
        .where((it) => !('${it['url'] ?? ''}').contains('/celebrity/'))
        .map((it) => _Hit(cleanTitle('${it['title']}'), 0))
        .toList();
  }

  static List<String> _withCommonPrefix(List<String> titles) {
    final top = titles.take(6).where(hasCjk).toList();
    if (top.length < 3) return titles;
    var best = '';
    var bestCount = 0;
    for (final t in top) {
      for (var len = 2; len < t.length; len++) {
        final p = t.substring(0, len);
        if (!hasCjk(p)) continue;
        final count = top.where((x) => x.startsWith(p)).length;
        if (count < 3) continue;
        if (count > bestCount ||
            (count == bestCount && p.length > best.length)) {
          best = p;
          bestCount = count;
        }
      }
    }
    best = best.replaceFirst(RegExp(r'[第之的与和上下新·\s]+$'), '');
    if (best.length < 2 || titles.contains(best)) return titles;
    return [best, ...titles];
  }

  static List<String> _dropNoise(List<String> titles) {
    final kept = <String>[];
    for (final t in titles) {
      String? parent;
      for (final k in kept) {
        if (t != k && t.startsWith(k)) {
          parent = k;
          break;
        }
      }
      if (parent != null) {
        final rest = t
            .substring(parent.length)
            .replaceFirst(RegExp(r'^[\s·:：\-—_]+'), '');
        if (!_seasonish.hasMatch(rest)) continue;
      }
      kept.add(t);
    }
    return kept;
  }
}

class _Hit {
  const _Hit(this.title, this.weight);
  final String title;
  final int weight;
}
