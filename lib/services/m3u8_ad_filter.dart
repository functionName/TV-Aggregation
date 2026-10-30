/// m3u8 中插广告过滤。
///
/// 主逻辑对齐 Veliora `js/player.js` 的 `filterAdsFromM3U8`：
/// 按 `#EXT-X-DISCONTINUITY` 切块，删「异源目录 + 不太长」的广告块。
///
/// 补充：TVBox 常见按时长 / 域名规则（量子、非凡等）。
class M3u8AdFilter {
  M3u8AdFilter._();

  /// 中插广告通常几十秒；更长的异源块宁可保留，避免误伤正片
  static const maxAdBlockSec = 180.0;

  /// TVBox 系常见广告切片时长（精确匹配 EXTINF）
  static const tvboxAdDurations = <double>[
    6.666667,
    6.566667,
    6.667,
    6.600000,
    6.6,
    2.966667,
    2.433333,
    2.266667,
    3.480000,
    5.640000,
    4.000000,
    0.960000,
    1.266667,
    10.000000,
  ];

  /// 路径级广告痕迹（不要写 ffzy/lz 等正片 CDN，会误删整片）
  static const tvboxAdHostHints = <String>[
    '/ad/',
    '/ads/',
    '/advert/',
    'advertisement',
    'adjump',
    'adgg.',
    'adonline',
  ];

  static bool _isDisc(String line) => line.trim() == '#EXT-X-DISCONTINUITY';

  static double _extinfDuration(String line) {
    final i = line.indexOf(':');
    if (i < 0) return 0;
    final v = double.tryParse(line.substring(i + 1).split(',').first.trim());
    return v ?? 0;
  }

  static bool _isTvboxAdDuration(double d) {
    for (final t in tvboxAdDurations) {
      if ((d - t).abs() < 0.0005) return true;
    }
    // 也认「约 6.66 / 2.96」这类四舍五入写法
    if (d > 6.55 && d < 6.68) return true;
    if (d > 2.95 && d < 2.98) return true;
    return false;
  }

  static bool _uriLooksAdHost(String uri) {
    final low = uri.toLowerCase();
    return tvboxAdHostHints.any(low.contains);
  }

  static String _segmentDir(String segUri, String? baseUrl) {
    var abs = segUri;
    try {
      if (baseUrl != null && baseUrl.isNotEmpty) {
        abs = Uri.parse(baseUrl).resolve(segUri).toString();
      }
    } catch (_) {
      abs = segUri;
    }
    final noQuery = abs.split('?').first.split('#').first;
    final cut = noQuery.lastIndexOf('/');
    return cut >= 0 ? noQuery.substring(0, cut) : noQuery;
  }

  static ({String prefix, int num, String ext})? _splitSegmentName(String uri) {
    final name = uri.split('?').first.split('#').first.split('/').last;
    final m = RegExp(r'^(.*?)(\d+)(\.[A-Za-z0-9]+)?$').firstMatch(name);
    if (m == null) return null;
    return (
      prefix: m.group(1) ?? '',
      num: int.tryParse(m.group(2) ?? '') ?? -1,
      ext: m.group(3) ?? '',
    );
  }

  static bool _consecutiveSegmentNames(String prevUri, String nextUri) {
    final a = _splitSegmentName(prevUri);
    final b = _splitSegmentName(nextUri);
    if (a == null || b == null) return false;
    return a.prefix == b.prefix && a.ext == b.ext && b.num - a.num == 1;
  }

  static String _blockDir(
    List<({List<String> tags, String uri, double duration})> block,
    String? baseUrl,
  ) {
    final counts = <String, int>{};
    for (final seg in block) {
      final dir = _segmentDir(seg.uri, baseUrl);
      counts[dir] = (counts[dir] ?? 0) + 1;
    }
    var best = '';
    var bestCount = -1;
    counts.forEach((dir, n) {
      if (n > bestCount) {
        best = dir;
        bestCount = n;
      }
    });
    return best;
  }

  static double _blockSec(
    List<({List<String> tags, String uri, double duration})> block,
  ) =>
      block.fold<double>(0, (s, seg) => s + seg.duration);

  /// 返回过滤后的播放列表；无需改写则返回原文。
  static String filter(String m3u8Content, {String? baseUrl}) {
    if (m3u8Content.isEmpty) return m3u8Content;
    if (!m3u8Content.contains('#EXTINF')) return m3u8Content;

    final rawLines =
        m3u8Content.split('\n').map((l) => l.replaceAll('\r', '')).toList();
    if (!rawLines.any(_isDisc)) {
      // 无 DISCONTINUITY 时仍尝试 TVBox「整段按时长+域名」轻量清理
      return _filterTvboxInline(rawLines, baseUrl) ?? m3u8Content;
    }

    final header = <String>[];
    final trailer = <String>[];
    final blocks = <List<({List<String> tags, String uri, double duration})>>[
      []
    ];
    var pendingTags = <String>[];
    var seenSegment = false;

    for (final line in rawLines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (_isDisc(t)) {
        blocks.add([]);
      } else if (t == '#EXT-X-ENDLIST') {
        trailer.add(line);
      } else if (t.startsWith('#')) {
        if (seenSegment || t.startsWith('#EXTINF')) {
          pendingTags.add(line);
        } else {
          header.add(line);
        }
      } else {
        seenSegment = true;
        String? extinf;
        for (final l in pendingTags) {
          if (l.trim().startsWith('#EXTINF')) {
            extinf = l;
            break;
          }
        }
        blocks.last.add((
          tags: List<String>.from(pendingTags),
          uri: t,
          duration: extinf != null ? _extinfDuration(extinf) : 0,
        ));
        pendingTags = [];
      }
    }
    final dangling = pendingTags;

    final kept = blocks.where((b) => b.isNotEmpty).toList();
    if (kept.length < 2) {
      return _filterTvboxInline(rawLines, baseUrl) ?? m3u8Content;
    }

    final selfDir = _segmentDir('.', baseUrl ?? '');
    final dirs = [for (final b in kept) _blockDir(b, baseUrl)];
    var longestIdx = 0;
    for (var i = 1; i < kept.length; i++) {
      if (_blockSec(kept[i]) > _blockSec(kept[longestIdx])) longestIdx = i;
    }
    final mainDir =
        dirs.contains(selfDir) ? selfDir : dirs[longestIdx];

    final totalSec = kept.fold<double>(0, (s, b) => s + _blockSec(b));
    var mainSec = 0.0;
    for (var i = 0; i < kept.length; i++) {
      if (dirs[i] == mainDir) mainSec += _blockSec(kept[i]);
    }
    if (totalSec > 0 && mainSec < totalSec * 0.6) {
      return m3u8Content;
    }

    final out = <String>[...header];
    var droppedSegments = 0;
    var droppedSec = 0.0;
    ({List<String> tags, String uri, double duration})? lastEmitted;
    var lastEmittedDir = '';
    var droppedSinceEmit = false;

    for (var i = 0; i < kept.length; i++) {
      final block = kept[i];
      final sec = _blockSec(block);
      final dir = dirs[i];
      final hasKey = block.any(
        (seg) => seg.tags.any((l) => l.trim().startsWith('#EXT-X-KEY')),
      );
      final tvboxBlock = _isTvboxAdBlock(block);
      // 对齐 Veliora：只删异源目录短块；TVBox 时长/路径仅作补充
      final isAd = !hasKey &&
          sec <= maxAdBlockSec &&
          (tvboxBlock || dir != mainDir);

      if (isAd) {
        droppedSegments += block.length;
        droppedSec += sec;
        droppedSinceEmit = true;
        continue;
      }

      if (lastEmitted != null) {
        final stitched = droppedSinceEmit &&
            lastEmittedDir == mainDir &&
            dir == mainDir &&
            _consecutiveSegmentNames(lastEmitted.uri, block.first.uri);
        if (!stitched) out.add('#EXT-X-DISCONTINUITY');
      }
      for (final seg in block) {
        out.addAll(seg.tags);
        out.add(seg.uri);
      }
      lastEmitted = block.last;
      lastEmittedDir = dir;
      droppedSinceEmit = false;
    }

    if (droppedSegments == 0) {
      return _filterTvboxInline(rawLines, baseUrl) ?? m3u8Content;
    }
    out.addAll(dangling);
    out.addAll(trailer);
    // ignore: avoid_print
    print(
      'm3u8 已过滤广告分片 $droppedSegments 个 / ${droppedSec.round()} 秒',
    );
    return out.join('\n');
  }

  /// 块内大部分切片命中 TVBox 时长，或 URI 命中广告域
  static bool _isTvboxAdBlock(
    List<({List<String> tags, String uri, double duration})> block,
  ) {
    if (block.isEmpty) return false;
    var durationHits = 0;
    var hostHits = 0;
    for (final seg in block) {
      if (_isTvboxAdDuration(seg.duration)) durationHits++;
      if (_uriLooksAdHost(seg.uri)) hostHits++;
    }
    if (hostHits >= (block.length + 1) ~/ 2) return true;
    if (durationHits >= (block.length * 2 + 2) ~/ 3 &&
        _blockSec(block) <= maxAdBlockSec) {
      return true;
    }
    return false;
  }

  /// 无 DISCONTINUITY 时：删掉「时长像广告且域名可疑」的单片
  static String? _filterTvboxInline(List<String> rawLines, String? baseUrl) {
    final out = <String>[];
    var i = 0;
    var dropped = 0;
    while (i < rawLines.length) {
      final line = rawLines[i];
      final t = line.trim();
      if (t.startsWith('#EXTINF') && i + 1 < rawLines.length) {
        final next = rawLines[i + 1].trim();
        if (next.isNotEmpty && !next.startsWith('#')) {
          final dur = _extinfDuration(t);
          if (_isTvboxAdDuration(dur) && _uriLooksAdHost(next)) {
            dropped++;
            i += 2;
            // 顺带丢掉紧跟的孤立 DISCONTINUITY
            if (i < rawLines.length && _isDisc(rawLines[i])) i++;
            continue;
          }
        }
      }
      out.add(line);
      i++;
    }
    if (dropped == 0) return null;
    // ignore: avoid_print
    print('m3u8 TVBox 规则已删 $dropped 个广告片');
    return out.join('\n');
  }

  /// 把相对分片 / 标签内 URI= 改成绝对 URL（换基址播放必需）
  static String absolutize(String m3u8Content, String baseUrl) {
    final base = Uri.tryParse(baseUrl);
    if (base == null) return m3u8Content;
    final out = <String>[];
    for (final line in m3u8Content.split('\n')) {
      final raw = line.replaceAll('\r', '');
      final t = raw.trim();
      if (t.isEmpty) {
        out.add(raw);
        continue;
      }
      if (t.startsWith('#')) {
        out.add(_absolutizeTagUris(raw, base));
        continue;
      }
      try {
        out.add(base.resolve(t).toString());
      } catch (_) {
        out.add(t);
      }
    }
    return out.join('\n');
  }

  static String _absolutizeTagUris(String line, Uri base) {
    return line.replaceAllMapped(
      RegExp(r'URI="([^"]+)"', caseSensitive: false),
      (m) {
        final u = m.group(1) ?? '';
        if (u.isEmpty) return m.group(0)!;
        if (u.startsWith('http://') || u.startsWith('https://')) {
          return m.group(0)!;
        }
        try {
          return 'URI="${base.resolve(u)}"';
        } catch (_) {
          return m.group(0)!;
        }
      },
    );
  }

  /// 主播放列表：取码率最高的变体 URL（相对则相对 base）
  static String? pickBestVariant(String masterContent, String baseUrl) {
    if (!masterContent.contains('#EXT-X-STREAM-INF')) return null;
    final base = Uri.tryParse(baseUrl);
    if (base == null) return null;
    final lines =
        masterContent.split('\n').map((l) => l.replaceAll('\r', '')).toList();
    var bestBw = -1;
    String? bestUri;
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (!t.startsWith('#EXT-X-STREAM-INF')) continue;
      final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(t);
      final bw = int.tryParse(bwMatch?.group(1) ?? '') ?? 0;
      if (i + 1 >= lines.length) continue;
      final uriLine = lines[i + 1].trim();
      if (uriLine.isEmpty || uriLine.startsWith('#')) continue;
      if (bw >= bestBw) {
        bestBw = bw;
        try {
          bestUri = base.resolve(uriLine).toString();
        } catch (_) {
          bestUri = uriLine;
        }
      }
    }
    return bestUri;
  }
}
