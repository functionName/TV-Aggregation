import '../models/models.dart';
import 'http_client.dart';
import 'settings_store.dart';

class VodService {
  VodService(this.store);
  final SettingsStore store;

  static const searchPath = '?ac=videolist&wd=';
  static const pagePath = '?ac=videolist&wd={query}&pg={page}';
  static const detailPath = '?ac=videolist&ids=';
  static const maxPages = 3;
  static const searchTimeout = Duration(seconds: 8);

  static const yellowBanned = [
    '伦理片', '福利', '里番动漫', '门事件', '萝莉少女', '制服诱惑', '国产传媒',
    'cosplay', '黑丝诱惑', '无码', '日本无码', '有码', '日本有码', 'SWAG',
    '网红主播', '色情片', '同性片', '福利视频', '福利片',
  ];

  List<VodItem> applyYellowFilter(List<VodItem> list) {
    if (!store.yellowFilterEnabled) return list;
    return list
        .where((i) => !yellowBanned.any((k) => i.typeName.contains(k)))
        .toList();
  }

  Future<List<VodItem>> searchSource(String sourceCode, String query) async {
    final meta = store.resolveSource(sourceCode);
    if (meta == null) return [];
    final base = meta.url;
    final name = meta.name;
    final url = '$base$searchPath${Uri.encodeComponent(query)}';
    try {
      final data = await AppHttp.getJson(url, timeout: searchTimeout);
      if (data is! Map || data['list'] is! List) return [];
      final first = (data['list'] as List)
          .whereType<Map>()
          .map((e) => VodItem.fromApi(
                Map<String, dynamic>.from(e),
                sourceCode: sourceCode,
                sourceName: name,
                apiUrl: sourceCode.startsWith('custom_') ? base : null,
              ))
          .toList();

      final pageCount = int.tryParse('${data['pagecount'] ?? 1}') ?? 1;
      final extra = (pageCount - 1).clamp(0, maxPages - 1);
      if (extra == 0) return first;

      final pages = await Future.wait(List.generate(extra, (i) async {
        final page = i + 2;
        final pageUrl = base +
            pagePath
                .replaceAll('{query}', Uri.encodeComponent(query))
                .replaceAll('{page}', '$page');
        try {
          final pd = await AppHttp.getJson(pageUrl, timeout: searchTimeout);
          if (pd is! Map || pd['list'] is! List) return <VodItem>[];
          return (pd['list'] as List)
              .whereType<Map>()
              .map((e) => VodItem.fromApi(
                    Map<String, dynamic>.from(e),
                    sourceCode: sourceCode,
                    sourceName: name,
                    apiUrl: sourceCode.startsWith('custom_') ? base : null,
                  ))
              .toList();
        } catch (_) {
          return <VodItem>[];
        }
      }));
      return [...first, ...pages.expand((e) => e)];
    } catch (_) {
      return [];
    }
  }

  Future<List<VodItem>> searchAll(String query) async {
    final sources = store.enabledSources;
    if (sources.isEmpty) throw Exception('没有可用采集源，请到「设置」中添加');
    final lists = await Future.wait(sources.map((s) => searchSource(s, query)));
    final all = applyYellowFilter(lists.expand((e) => e).toList());
    all.sort((a, b) {
      final c = a.vodName.compareTo(b.vodName);
      if (c != 0) return c;
      return a.sourceName.compareTo(b.sourceName);
    });
    return _rankByKeyword(all, query);
  }

  /// 各源最新更新（豆瓣关闭时发现页兜底）
  Future<List<VodItem>> listLatestSource(String sourceCode,
      {int page = 1}) async {
    final meta = store.resolveSource(sourceCode);
    if (meta == null) return [];
    final base = meta.url;
    final url = '$base?ac=videolist&pg=$page';
    try {
      final data = await AppHttp.getJson(url, timeout: searchTimeout);
      if (data is! Map || data['list'] is! List) return [];
      return (data['list'] as List)
          .whereType<Map>()
          .map((e) => VodItem.fromApi(
                Map<String, dynamic>.from(e),
                sourceCode: sourceCode,
                sourceName: meta.name,
                apiUrl: sourceCode.startsWith('custom_') ? base : null,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 探测源是否可用（对齐真实搜索接口）。
  ///
  /// 依据：请求 `?ac=videolist&pg=1`（和搜片/列表同源），
  /// 能在超时内返回带 `list` 数组的 JSON 即算可用（空 list 也算通）。
  /// 成功返回耗时毫秒；失败返回 null。
  /// 会自动重试 1 次，减少代理/网络抖动误判。
  Future<int?> probeSource(String sourceCode) async {
    final meta = store.resolveSource(sourceCode);
    if (meta == null || meta.url.isEmpty) return null;
    // 与 listLatest / 搜索同一协议，避免 ac=list 与 videolist 行为不一致
    final url = '${meta.url}?ac=videolist&pg=1';

    Future<int?> once() async {
      final sw = Stopwatch()..start();
      final data = await AppHttp.getJson(
        url,
        timeout: const Duration(seconds: 12),
      );
      sw.stop();
      if (data is! Map) return null;
      final list = data['list'];
      if (list is List) return sw.elapsedMilliseconds;
      // 少数站用 code=1 表示成功但 list 缺省
      final code = data['code'];
      if (code == 1 || code == '1') return sw.elapsedMilliseconds;
      return null;
    }

    try {
      return await once();
    } catch (_) {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return await once();
      } catch (_) {
        return null;
      }
    }
  }

  Future<List<VodItem>> listLatestAll({int perSource = 12}) async {
    final sources = store.enabledSources;
    if (sources.isEmpty) return [];
    final lists = await Future.wait(
      sources.map((s) => listLatestSource(s)),
    );
    final merged = <VodItem>[];
    final seen = <String>{};
    for (final list in lists) {
      var n = 0;
      for (final item in list) {
        if (n >= perSource) break;
        final key = '${item.sourceCode}|${item.vodId}';
        if (item.vodId.isEmpty || seen.contains(key)) continue;
        seen.add(key);
        merged.add(item);
        n++;
      }
    }
    return applyYellowFilter(merged);
  }

  /// 当前推荐单源的最新列表（不含豆瓣；无有效源时返回空）
  Future<List<VodItem>> listFeedLatest({int limit = 40}) async {
    final code = store.effectiveFeedSourceCode;
    if (code == null) return [];
    final page1 = await listLatestSource(code, page: 1);
    final page2 = await listLatestSource(code, page: 2);
    final merged = <VodItem>[];
    final seen = <String>{};
    for (final item in [...page1, ...page2]) {
      final key = '${item.sourceCode}|${item.vodId}';
      if (item.vodId.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      merged.add(item);
      if (merged.length >= limit) break;
    }
    return applyYellowFilter(merged);
  }

  /// 拉取源站分类（MacCMS `ac=list` 的 class；失败再试 videolist 附带 class）
  Future<List<VodCategory>> fetchCategories(String sourceCode) async {
    final meta = store.resolveSource(sourceCode);
    if (meta == null) return [];
    final base = meta.url;

    List<VodCategory> parseClass(dynamic raw) {
      if (raw is! List) return [];
      final out = <VodCategory>[];
      final seen = <String>{};
      for (final e in raw) {
        if (e is! Map) continue;
        final c = VodCategory.fromApi(Map<String, dynamic>.from(e));
        if (c.id.isEmpty || c.name.isEmpty || seen.contains(c.id)) continue;
        if (store.yellowFilterEnabled &&
            yellowBanned.any((k) => c.name.contains(k))) {
          continue;
        }
        seen.add(c.id);
        out.add(c);
      }
      // 顶层优先，便于遥控选
      out.sort((a, b) {
        final ta = a.isTopLevel ? 0 : 1;
        final tb = b.isTopLevel ? 0 : 1;
        if (ta != tb) return ta.compareTo(tb);
        return a.id.compareTo(b.id);
      });
      return out;
    }

    try {
      final data = await AppHttp.getJson(
        '$base?ac=list',
        timeout: searchTimeout,
      );
      if (data is Map) {
        final cats = parseClass(data['class'] ?? data['type']);
        if (cats.isNotEmpty) return cats;
      }
    } catch (_) {}

    try {
      final data = await AppHttp.getJson(
        '$base?ac=videolist&pg=1',
        timeout: searchTimeout,
      );
      if (data is Map) {
        return parseClass(data['class'] ?? data['type']);
      }
    } catch (_) {}
    return [];
  }

  /// 按分类拉列表；[typeId] 为空则等同最新
  Future<List<VodItem>> listByType(
    String sourceCode, {
    String? typeId,
    int page = 1,
  }) async {
    final meta = store.resolveSource(sourceCode);
    if (meta == null) return [];
    final base = meta.url;
    final tid = (typeId ?? '').trim();
    final url = tid.isEmpty
        ? '$base?ac=videolist&pg=$page'
        : '$base?ac=videolist&t=${Uri.encodeQueryComponent(tid)}&pg=$page';
    try {
      final data = await AppHttp.getJson(url, timeout: searchTimeout);
      if (data is! Map || data['list'] is! List) return [];
      final list = (data['list'] as List)
          .whereType<Map>()
          .map((e) => VodItem.fromApi(
                Map<String, dynamic>.from(e),
                sourceCode: sourceCode,
                sourceName: meta.name,
                apiUrl: sourceCode.startsWith('custom_') ? base : null,
              ))
          .toList();
      return applyYellowFilter(list);
    } catch (_) {
      return [];
    }
  }

  List<VodItem> _rankByKeyword(List<VodItem> all, String keyword) {
    final kw = keyword.toLowerCase();
    int rank(VodItem i) {
      final n = i.vodName.toLowerCase();
      if (n == kw) return 0;
      if (n.startsWith(kw)) return 1;
      if (n.contains(kw)) return 2;
      return 3;
    }
    all.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return a.vodName.compareTo(b.vodName);
    });
    return all;
  }

  /// 同名片合并：每个片名只留一条代表（优先有封面、备注更完整的源）
  /// 返回的列表用于搜索网格；进详情仍会按标题搜齐其它源。
  static List<VodItem> mergeByTitle(List<VodItem> all) {
    final groups = <String, List<VodItem>>{};
    for (final item in all) {
      final key = item.vodName.trim().toLowerCase();
      if (key.isEmpty) continue;
      (groups[key] ??= []).add(item);
    }
    int score(VodItem v) {
      var s = 0;
      if (v.vodPic.isNotEmpty) s += 4;
      if (v.remarks.isNotEmpty) s += 2;
      if (v.vodId.isNotEmpty) s += 1;
      return s;
    }
    final out = <VodItem>[];
    for (final list in groups.values) {
      list.sort((a, b) => score(b).compareTo(score(a)));
      out.add(list.first);
    }
    return out;
  }

  /// 某片名在原始结果里有多少个源（合并展示用）
  static int sourceCountForTitle(List<VodItem> all, String title) {
    final key = title.trim().toLowerCase();
    return all.where((e) => e.vodName.trim().toLowerCase() == key).length;
  }

  /// 搜索列表若已带 playUrl，直接拼详情，免进页再转一圈
  VodDetail? detailFromSearchHit(VodItem item) {
    if (!item.hasPlayPayload) return null;
    final parsed = _parsePlayLines(
      playFrom: item.playFrom ?? '',
      playUrl: item.playUrl ?? '',
      content: item.desc ?? '',
    );
    if (parsed.isEmpty) return null;
    return VodDetail(
      lines: parsed,
      episodes: parsed.first.episodes,
      preferredLineIndex: 0,
      title: item.vodName,
      cover: item.vodPic,
      desc: _stripHtml(item.desc ?? ''),
      type: item.typeName,
      year: item.year ?? '',
      area: item.area ?? '',
      remarks: item.remarks,
    );
  }

  Future<VodDetail> fetchDetail(VodItem item) async {
    final fromSearch = detailFromSearchHit(item);
    if (fromSearch != null) return fromSearch;

    final meta = store.resolveSource(item.sourceCode);
    final base = meta?.url ?? item.apiUrl;
    if (base == null || base.isEmpty) throw Exception('源地址无效');
    final url = '$base$detailPath${Uri.encodeComponent(item.vodId)}';
    final data = await AppHttp.getJson(url);
    if (data is! Map || data['list'] is! List || (data['list'] as List).isEmpty) {
      throw Exception('详情无效');
    }
    final video = Map<String, dynamic>.from(
        (data['list'] as List).first as Map);
    final parsed = _parsePlayLines(
      playFrom: '${video['vod_play_from'] ?? ''}',
      playUrl: '${video['vod_play_url'] ?? ''}',
      content: '${video['vod_content'] ?? ''}',
    );
    // parsed 已按清晰度排序，首条即最优（优先 4K）
    return VodDetail(
      lines: parsed,
      episodes: parsed.isNotEmpty ? parsed.first.episodes : const [],
      preferredLineIndex: 0,
      title: '${video['vod_name'] ?? item.vodName}',
      cover: '${video['vod_pic'] ?? item.vodPic}',
      desc: _stripHtml('${video['vod_content'] ?? ''}'),
      type: '${video['type_name'] ?? item.typeName}',
      year: '${video['vod_year'] ?? ''}',
      area: '${video['vod_area'] ?? ''}',
      remarks: '${video['vod_remarks'] ?? item.remarks}',
    );
  }

  /// 解析 MacCMS 多线路：vod_play_from / vod_play_url 用 $$$ 对齐分段
  List<PlayLine> _parsePlayLines({
    required String playFrom,
    required String playUrl,
    required String content,
  }) {
    final lines = <PlayLine>[];
    if (playUrl.trim().isNotEmpty) {
      final fromParts = playFrom
          .split('\$\$\$')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final urlParts = playUrl.split('\$\$\$');
      for (var i = 0; i < urlParts.length; i++) {
        final eps = _parseEpisodeSegment(urlParts[i]);
        if (eps.isEmpty) continue;
        final rawName = i < fromParts.length ? fromParts[i] : '';
        final name = _prettyLineName(rawName, i, eps);
        lines.add(PlayLine(name: name, episodes: eps));
      }
    }
    if (lines.isEmpty) {
      final re = RegExp(r'''https?://[^"'\s]+?\.m3u8''');
      final eps = re
          .allMatches(content)
          .map((m) => Episode('播放', m.group(0)!))
          .toList();
      if (eps.isNotEmpty) {
        lines.add(PlayLine(name: '默认', episodes: eps));
      }
    }
    // 高分在前：清晰度 > 可播性(HLS优先，/share/直链垫底) > 集数
    lines.sort((a, b) {
      final q = b.qualityScore.compareTo(a.qualityScore);
      if (q != 0) return q;
      final p = b.playabilityScore.compareTo(a.playabilityScore);
      if (p != 0) return p;
      return b.episodes.length.compareTo(a.episodes.length);
    });
    return lines;
  }

  List<Episode> _parseEpisodeSegment(String src) {
    final eps = <Episode>[];
    for (final ep in src.split('#')) {
      if (ep.trim().isEmpty) continue;
      final parts = ep.split('\$');
      final name = parts.isNotEmpty ? parts[0].trim() : '';
      var u = parts.length > 1 ? parts[1].trim() : '';
      if (u.startsWith('//')) u = 'https:$u';
      if (!(u.startsWith('http://') || u.startsWith('https://'))) continue;
      eps.add(Episode(name.isEmpty ? '播放' : name, u));
    }
    return eps;
  }

  /// MacCMS 的 vod_play_from 常常是解析器代号（lzm3u8 / liangzi），
  /// 不是「4K」「1080」——这里翻成可读线路名，再尽量从 URL 猜清晰度。
  String _prettyLineName(String raw, int index, List<Episode> eps) {
    final flag = raw.trim();
    final mapped = _mapPlayFromFlag(flag);
    final quality = _guessQualityLabel(eps);
    final unreliable = eps.any((e) => e.url.toLowerCase().contains('/share/'));
    var base = mapped.isNotEmpty
        ? mapped
        : (flag.isNotEmpty ? flag : '线路${index + 1}');

    // 已自带清晰度字样就不再重复拼接
    final alreadyQuality = RegExp(
      r'4k|2160|1080|720|蓝光|超清|高清|标清|uhd|fhd|hd',
      caseSensitive: false,
    ).hasMatch(base);

    if (quality != null && !alreadyQuality) {
      base = '$base · $quality';
    } else if (mapped.isEmpty && flag.isNotEmpty && quality == null) {
      base = '线路${index + 1} · $flag';
    }
    // /share/ 是网页分享链，Web/部分播放器会报 Format error
    if (unreliable && !base.contains('易失败')) {
      base = '$base · 易失败';
    }
    return base;
  }

  /// 常见采集站 play_from 代号 → 中文线路名
  String _mapPlayFromFlag(String raw) {
    if (raw.isEmpty) return '';
    final key = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const map = <String, String>{
      'lzm3u8': '量子',
      'lz': '量子',
      'liangzi': '量子直链',
      'liangzim3u8': '量子',
      'bfm3u8': '暴风',
      'bfzy': '暴风',
      'baofeng': '暴风',
      'ffm3u8': '非凡',
      'feifan': '非凡',
      'ffzy': '非凡',
      'hhm3u8': '红牛',
      'hongniu': '红牛',
      'hnm3u8': '红牛',
      'wjm3u8': '无尽',
      'wujin': '无尽',
      'tkm3u8': '天空',
      'tiankong': '天空',
      'dbm3u8': '豆瓣',
      'gsm3u8': '光速',
      'guangsu': '光速',
      'snm3u8': '索尼',
      'kbm3u8': '快播',
      'kuaibo': '快播',
      'jsm3u8': '极速',
      'jinyingm3u8': '金鹰',
      'ukm3u8': 'U酷',
      'ikm3u8': 'iKun',
      'sdm3u8': '闪电',
      'haiwaikan': '海外看',
      'aliyun': '阿里',
      'aliyunm3u8': '阿里',
      'qq': '腾讯',
      'qiyi': '爱奇艺',
      'youku': '优酷',
      'mgtv': '芒果',
      'bilibili': '哔哩',
      'sohu': '搜狐',
      'm1905': '1905',
      'pptv': 'PPTV',
      'letv': '乐视',
      'wasu': '华数',
      'm3u8': 'HLS',
      'mp4': 'MP4',
      'dytt': '电影天堂直链',
      'dyttm3u8': '电影天堂',
      'heimuer': '黑木耳',
      'heimuerm3u8': '黑木耳',
      'zuidam3u8': '最大',
      'zuida': '最大',
    };
    if (map.containsKey(key)) return map[key]!;
    // 尾缀 m3u8：lzxxxm3u8 → 试前缀
    if (key.endsWith('m3u8') && key.length > 4) {
      final prefix = key.substring(0, key.length - 4);
      if (map.containsKey(prefix)) return map[prefix]!;
      if (map.containsKey('${prefix}m3u8')) return map['${prefix}m3u8']!;
    }
    // 已是中文/带清晰度的可读名，原样用
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(raw)) return raw.trim();
    if (RegExp(r'4k|1080|720|蓝光|超清', caseSensitive: false).hasMatch(raw)) {
      return raw.trim();
    }
    return '';
  }

  /// 从播放地址猜清晰度（源站常不在 from 里标）
  String? _guessQualityLabel(List<Episode> eps) {
    if (eps.isEmpty) return null;
    final blob = eps.take(8).map((e) => e.url.toLowerCase()).join(' ');
    // 避免命中 hash 里的 2160（如 …3152160ed0…）
    if (RegExp(r'(^|[^a-z0-9])(4k|2160p?|uhd)([^a-z0-9]|$)')
        .hasMatch(blob)) {
      return '4K';
    }
    if (RegExp(r'(^|[^a-z0-9])(1080p?|fhd)([^a-z0-9]|$)')
            .hasMatch(blob) ||
        RegExp(r'bluray|blu-?ray').hasMatch(blob)) {
      return '1080P';
    }
    if (RegExp(r'(^|[^a-z0-9])720p?([^a-z0-9]|$)').hasMatch(blob)) {
      return '720P';
    }
    if (RegExp(r'(^|[^a-z0-9])(480p?|360p?)([^a-z0-9]|$)').hasMatch(blob)) {
      return '标清';
    }
    if (blob.contains('.m3u8')) return 'HLS';
    if (blob.contains('.mp4')) return 'MP4';
    return null;
  }

  String _stripHtml(String s) =>
      s.replaceAll(RegExp(r'<[^>]+>'), '').trim();
}
