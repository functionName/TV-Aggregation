import '../models/models.dart';
import 'http_client.dart';

class DoubanService {
  Future<List<DoubanSubject>> searchSubjects({
    required String type,
    required String tag,
    int limit = 12,
    int start = 0,
    String sort = 'recommend',
  }) async {
    final url =
        'https://movie.douban.com/j/search_subjects?type=$type&tag=${Uri.encodeComponent(tag)}&sort=$sort&page_limit=$limit&page_start=$start';
    final data = await AppHttp.getJson(url, headers: {
      'Referer': 'https://movie.douban.com/',
    });
    final list = (data is Map && data['subjects'] is List)
        ? data['subjects'] as List
        : const [];
    return list
        .whereType<Map>()
        .map((e) => DoubanSubject.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 发现页：new_search_subjects（形态/类型/地区可组合）
  Future<List<DoubanSubject>> discover({
    String? form,
    String? type,
    String? country,
    String sort = 'U',
    int start = 0,
    int limit = 20,
  }) async {
    final params = <String, String>{
      'sort': sort,
      'range': '0,10',
      'tags': [
        if (form != null && form.isNotEmpty) form,
        if (type != null && type.isNotEmpty) type,
        if (country != null && country.isNotEmpty) country,
      ].join(','),
      'start': '$start',
      'count': '$limit',
    };
    // 兼容旧 search_subjects：无 tags 时退回热门
    if (params['tags']!.isEmpty) {
      return searchSubjects(type: 'movie', tag: '热门', limit: limit, start: start);
    }
    final q = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final url = 'https://movie.douban.com/j/new_search_subjects?$q';
    try {
      final data = await AppHttp.getJson(url, headers: {
        'Referer': 'https://movie.douban.com/',
      });
      final list = (data is Map && data['data'] is List)
          ? data['data'] as List
          : const [];
      return list
          .whereType<Map>()
          .map((e) => DoubanSubject.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return searchSubjects(
        type: form == '电视剧' || form == '综艺' ? 'tv' : 'movie',
        tag: type ?? form ?? '热门',
        limit: limit,
        start: start,
      );
    }
  }
}
