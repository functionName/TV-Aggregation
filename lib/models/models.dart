class DoubanSubject {
  final String id;
  final String title;
  final String cover;
  final String rate;
  final String? url;

  const DoubanSubject({
    required this.id,
    required this.title,
    required this.cover,
    this.rate = '',
    this.url,
  });

  factory DoubanSubject.fromJson(Map<String, dynamic> j) {
    final raw = j['rate'] ?? j['rating'] ?? j['score'];
    String rate = '';
    if (raw != null) {
      if (raw is num) {
        rate = raw == raw.roundToDouble()
            ? '${raw.toInt()}'
            : raw.toStringAsFixed(1);
      } else {
        rate = '$raw'.trim();
      }
    }
    return DoubanSubject(
      id: '${j['id'] ?? ''}',
      title: '${j['title'] ?? ''}',
      cover: '${j['cover'] ?? j['img'] ?? ''}',
      rate: rate,
      url: j['url']?.toString(),
    );
  }

  String get hdCover => cover
      .replaceAll('/s_ratio_poster/', '/l_ratio_poster/')
      .replaceAll('/m_ratio_poster/', '/l_ratio_poster/');
}

class HomeRowConfig {
  final String title;
  final String type; // movie | tv
  final String tag;
  const HomeRowConfig(this.title, this.type, this.tag);
}

const homeRows = [
  HomeRowConfig('豆瓣高分', 'movie', '豆瓣高分'),
  HomeRowConfig('综艺', 'tv', '综艺'),
];

class CustomApi {
  final String name;
  final String url;
  final String? detail;
  final bool isAdult;

  const CustomApi({
    required this.name,
    required this.url,
    this.detail,
    this.isAdult = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        if (detail != null) 'detail': detail,
        'isAdult': isAdult,
      };

  factory CustomApi.fromJson(Map<String, dynamic> j) => CustomApi(
        name: '${j['name'] ?? '自定义源'}',
        url: '${j['url'] ?? ''}',
        detail: j['detail']?.toString(),
        isAdult: j['isAdult'] == true || j['adult'] == true,
      );
}

/// MacCMS 分类（ac=list 的 class）
class VodCategory {
  final String id;
  final String name;
  final String parentId;
  const VodCategory({
    required this.id,
    required this.name,
    this.parentId = '0',
  });

  bool get isTopLevel =>
      parentId.isEmpty || parentId == '0' || parentId == 'null';

  factory VodCategory.fromApi(Map<String, dynamic> j) => VodCategory(
        id: '${j['type_id'] ?? j['tid'] ?? ''}',
        name: '${j['type_name'] ?? j['tname'] ?? ''}'.trim(),
        parentId: '${j['type_pid'] ?? j['parent_id'] ?? '0'}',
      );
}

class VodItem {
  final String vodId;
  final String vodName;
  final String vodPic;
  final String typeName;
  final String remarks;
  final String sourceCode;
  final String sourceName;
  final String? apiUrl;
  final String? year;
  final String? area;
  final String? desc;
  /// videolist 搜索常自带，进详情可免二次请求
  final String? playFrom;
  final String? playUrl;

  const VodItem({
    required this.vodId,
    required this.vodName,
    this.vodPic = '',
    this.typeName = '',
    this.remarks = '',
    required this.sourceCode,
    required this.sourceName,
    this.apiUrl,
    this.year,
    this.area,
    this.desc,
    this.playFrom,
    this.playUrl,
  });

  bool get hasPlayPayload =>
      (playUrl != null && playUrl!.trim().isNotEmpty);

  factory VodItem.fromApi(Map<String, dynamic> j, {
    required String sourceCode,
    required String sourceName,
    String? apiUrl,
  }) {
    final playUrl = '${j['vod_play_url'] ?? ''}'.trim();
    final playFrom = '${j['vod_play_from'] ?? ''}'.trim();
    return VodItem(
      vodId: '${j['vod_id'] ?? ''}',
      vodName: '${j['vod_name'] ?? ''}',
      vodPic: '${j['vod_pic'] ?? ''}',
      typeName: '${j['type_name'] ?? ''}',
      remarks: '${j['vod_remarks'] ?? ''}',
      sourceCode: sourceCode,
      sourceName: sourceName,
      apiUrl: apiUrl,
      year: j['vod_year']?.toString(),
      area: j['vod_area']?.toString(),
      desc: j['vod_content']?.toString(),
      playFrom: playFrom.isEmpty ? null : playFrom,
      playUrl: playUrl.isEmpty ? null : playUrl,
    );
  }
}

class Episode {
  final String name;
  final String url;
  const Episode(this.name, this.url);
}

/// 一条播放线路（如「4K」「蓝光」「超清」），对应 MacCMS 的 $$$ 分段
class PlayLine {
  final String name;
  final List<Episode> episodes;
  const PlayLine({required this.name, required this.episodes});

  /// 用于排序：分越高越优先默认选中（看线路名里有没有清晰度字样）
  int get qualityScore {
    final n = name.toLowerCase();
    if (RegExp(r'4k|2160|uhd|超高清|杜比|dolby').hasMatch(n)) return 100;
    if (RegExp(r'蓝光|bluray|blu-?ray|\bbd\b|1080|fhd|全高清').hasMatch(n)) {
      return 80;
    }
    if (RegExp(r'高清|720|\bhd\b').hasMatch(n)) return 60;
    if (n.contains('m3u8') || n.contains('hls')) return 50;
    if (RegExp(r'标清|360|480|\bsd\b').hasMatch(n)) return 20;
    return 40;
  }

  bool get looksLike4k => qualityScore >= 100;

  /// 浏览器/播放器实际能不能播：HLS/MP4 高，/share/ 网页分享链几乎必挂
  int get playabilityScore {
    if (episodes.isEmpty) return 0;
    final sample = episodes
        .take(6)
        .map((e) => e.url.toLowerCase())
        .join(' ');
    if (sample.contains('/share/')) return 5;
    if (RegExp(r'\.m3u8(\?|$|#)').hasMatch(sample) ||
        sample.contains('m3u8')) {
      return 100;
    }
    if (RegExp(r'\.mp4(\?|$|#)').hasMatch(sample)) return 80;
    if (sample.contains('.flv') || sample.contains('.mkv')) return 30;
    return 40;
  }

  bool get looksUnreliable => playabilityScore < 20;
}

class VodDetail {
  /// 全部播放线路；[episodes] 为兼容旧代码的「当前默认线路」剧集
  final List<PlayLine> lines;
  final List<Episode> episodes;
  final String title;
  final String cover;
  final String desc;
  final String type;
  final String year;
  final String area;
  final String remarks;
  /// 建议默认选中的线路下标（已按清晰度排过）
  final int preferredLineIndex;

  const VodDetail({
    required this.episodes,
    this.lines = const [],
    this.title = '',
    this.cover = '',
    this.desc = '',
    this.type = '',
    this.year = '',
    this.area = '',
    this.remarks = '',
    this.preferredLineIndex = 0,
  });

  List<PlayLine> get effectiveLines {
    if (lines.isNotEmpty) return lines;
    if (episodes.isEmpty) return const [];
    return [PlayLine(name: '默认', episodes: episodes)];
  }
}

class HistoryItem {
  final String title;
  final String cover;
  final String sourceCode;
  final String sourceName;
  final String? apiUrl;
  final String vodId;
  final int episodeIndex;
  final int positionMs;
  final int updatedAt;

  const HistoryItem({
    required this.title,
    required this.cover,
    required this.sourceCode,
    required this.sourceName,
    this.apiUrl,
    required this.vodId,
    this.episodeIndex = 0,
    this.positionMs = 0,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'cover': cover,
        'sourceCode': sourceCode,
        'sourceName': sourceName,
        'apiUrl': apiUrl,
        'vodId': vodId,
        'episodeIndex': episodeIndex,
        'positionMs': positionMs,
        'updatedAt': updatedAt,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        title: '${j['title'] ?? j['vod_name'] ?? ''}',
        cover: '${j['cover'] ?? j['vod_pic'] ?? ''}',
        sourceCode: '${j['sourceCode'] ?? j['source_code'] ?? ''}',
        sourceName: '${j['sourceName'] ?? j['source_name'] ?? ''}',
        apiUrl: j['apiUrl']?.toString() ?? j['api_url']?.toString(),
        vodId: '${j['vodId'] ?? j['vod_id'] ?? ''}',
        episodeIndex: (j['episodeIndex'] ?? j['episodeIndex'] ?? 0) is int
            ? (j['episodeIndex'] ?? 0) as int
            : int.tryParse('${j['episodeIndex']}') ?? 0,
        positionMs: (j['positionMs'] ?? 0) is int
            ? (j['positionMs'] ?? 0) as int
            : int.tryParse('${j['positionMs']}') ?? 0,
        updatedAt: (j['updatedAt'] ?? j['timestamp'] ?? 0) is int
            ? (j['updatedAt'] ?? j['timestamp'] ?? 0) as int
            : int.tryParse('${j['updatedAt'] ?? j['timestamp']}') ?? 0,
      );

  /// 历史卡片副标题：集数 + 进度
  String get progressLabel {
    final ep = '第${episodeIndex + 1}集';
    if (positionMs < 5000) return '续看$ep';
    final totalSec = positionMs ~/ 1000;
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$ep · $m:$s';
  }
}

/// 本地收藏（想看 / 常看）
class FavoriteItem {
  final String title;
  final String cover;
  final String sourceCode;
  final String sourceName;
  final String? apiUrl;
  final String vodId;
  final int updatedAt;

  const FavoriteItem({
    required this.title,
    required this.cover,
    required this.sourceCode,
    required this.sourceName,
    this.apiUrl,
    required this.vodId,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'cover': cover,
        'sourceCode': sourceCode,
        'sourceName': sourceName,
        'apiUrl': apiUrl,
        'vodId': vodId,
        'updatedAt': updatedAt,
      };

  factory FavoriteItem.fromJson(Map<String, dynamic> j) => FavoriteItem(
        title: '${j['title'] ?? ''}',
        cover: '${j['cover'] ?? ''}',
        sourceCode: '${j['sourceCode'] ?? ''}',
        sourceName: '${j['sourceName'] ?? ''}',
        apiUrl: j['apiUrl']?.toString(),
        vodId: '${j['vodId'] ?? ''}',
        updatedAt: (j['updatedAt'] ?? 0) is int
            ? (j['updatedAt'] ?? 0) as int
            : int.tryParse('${j['updatedAt']}') ?? 0,
      );

  factory FavoriteItem.fromHistory(HistoryItem h) => FavoriteItem(
        title: h.title,
        cover: h.cover,
        sourceCode: h.sourceCode,
        sourceName: h.sourceName,
        apiUrl: h.apiUrl,
        vodId: h.vodId,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
}
