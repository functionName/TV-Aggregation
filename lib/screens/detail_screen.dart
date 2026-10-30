import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/settings_store.dart';
import '../services/vod_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import 'player_screen.dart';
import 'shell_screen.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.title,
    this.cover,
    this.resumeEpisode,
    this.resumePositionMs,
    this.preferSource,
    this.seedVodId,
    this.seedSourceName,
    this.seedApiUrl,
    this.seedRemarks,
    this.seedPlayFrom,
    this.seedPlayUrl,
    this.seedDesc,
    this.seedYear,
    this.seedArea,
    this.seedTypeName,
    required this.onBack,
  });

  final String title;
  final String? cover;
  final int? resumeEpisode;
  final int? resumePositionMs;
  final String? preferSource;
  /// 搜索/历史带入的精确条目，避免只靠标题重搜对不上
  final String? seedVodId;
  final String? seedSourceName;
  final String? seedApiUrl;
  final String? seedRemarks;
  final String? seedPlayFrom;
  final String? seedPlayUrl;
  final String? seedDesc;
  final String? seedYear;
  final String? seedArea;
  final String? seedTypeName;
  final VoidCallback onBack;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  bool loading = true;
  bool switching = false;
  String status = '正在查找片源…';
  String synopsis = '';
  final List<VodItem> results = [];
  final List<String> pending = [];
  /// 按源缓存详情，切换播放源时直接复用，不重复请求
  final Map<String, VodDetail> _detailCache = {};
  int selected = -1;
  VodDetail? detail;
  /// 当前播放线路（4K / 蓝光 / …）
  int lineIndex = 0;
  int token = 0;
  /// 选集标题行：正序/倒序
  final _epExitUpFocus = FocusNode(debugLabel: 'epExitUp');
  /// 选集标题行：全部选集
  final _epAllFocus = FocusNode(debugLabel: 'epAll');
  /// 避免多次 setState 反复抢 autofocus 导致「焦点突然消失」
  bool _epAutofocusDone = false;

  @override
  void dispose() {
    _epExitUpFocus.dispose();
    _epAllFocus.dispose();
    super.dispose();
  }

  List<PlayLine> get _lines => detail?.effectiveLines ?? const [];

  List<Episode> get _currentEpisodes {
    final lines = _lines;
    if (lines.isEmpty) return const [];
    final i = lineIndex.clamp(0, lines.length - 1);
    return lines[i].episodes;
  }

  void _selectLine(int i) {
    final lines = _lines;
    if (i < 0 || i >= lines.length) return;
    setState(() => lineIndex = i);
  }

  String _cacheKey(VodItem item) =>
      '${item.sourceCode}|${item.vodId}|${item.apiUrl ?? ''}';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  bool _sameItem(VodItem a, VodItem b) =>
      a.sourceCode == b.sourceCode && a.vodId == b.vodId && a.vodId.isNotEmpty;

  void _addResults(Iterable<VodItem> items) {
    for (final item in items) {
      if (results.any((e) => _sameItem(e, item))) continue;
      results.add(item);
    }
  }

  Future<void> _boot() async {
    final store = context.read<SettingsStore>();
    final vod = VodService(store);
    final sources = store.enabledSources;
    if (sources.isEmpty) {
      setState(() {
        loading = false;
        status = '没有可用采集源，请到设置添加';
      });
      return;
    }
    final my = ++token;
    final seedId = widget.seedVodId?.trim() ?? '';
    final seedSrc = widget.preferSource?.trim() ?? '';
    final hasSeed = seedId.isNotEmpty && seedSrc.isNotEmpty;

    // 有搜索带入：立刻钉住该源；无种子（首页/发现）也不挡操作，边搜边显示
    setState(() {
      loading = !hasSeed;
      switching = false;
      pending
        ..clear()
        ..addAll(sources
            .where((s) => !(hasSeed && s == seedSrc))
            .map((s) => store.resolveSource(s)?.name ?? s));
      results.clear();
      _detailCache.clear();
      selected = -1;
      detail = null;
      _epAutofocusDone = false;
      synopsis = widget.seedDesc?.trim() ?? '';
      status = hasSeed
          ? (synopsis.isNotEmpty ? synopsis : '加载剧集…')
          : '正在查找片源…';
    });

    if (hasSeed) {
      final seed = VodItem(
        vodId: seedId,
        vodName: widget.title,
        vodPic: widget.cover ?? '',
        typeName: widget.seedTypeName ?? '',
        sourceCode: seedSrc,
        sourceName: (widget.seedSourceName?.trim().isNotEmpty ?? false)
            ? widget.seedSourceName!.trim()
            : (store.resolveSource(seedSrc)?.name ?? seedSrc),
        apiUrl: widget.seedApiUrl,
        remarks: widget.seedRemarks ?? '',
        year: widget.seedYear,
        area: widget.seedArea,
        desc: widget.seedDesc,
        playFrom: widget.seedPlayFrom,
        playUrl: widget.seedPlayUrl,
      );
      final instant = vod.detailFromSearchHit(seed);
      setState(() {
        results.add(seed);
        selected = 0;
        loading = false;
        if (instant != null) {
          _detailCache[_cacheKey(seed)] = instant;
          detail = instant;
          lineIndex = instant.preferredLineIndex.clamp(
            0,
            (instant.effectiveLines.isEmpty
                    ? 1
                    : instant.effectiveLines.length) -
                1,
          );
          if (instant.desc.isNotEmpty) synopsis = instant.desc;
          status = synopsis.isEmpty ? '暂无简介' : synopsis;
          switching = false;
        }
      });
      if (instant == null) {
        // ignore: unawaited_futures
        _loadEpisodes(0, my);
      }
    }

    // 无种子：优先搜 prefer / 第一个启用源，尽快出选集，其余后台补
    final ordered = <String>[
      if (!hasSeed &&
          seedSrc.isNotEmpty &&
          sources.contains(seedSrc))
        seedSrc,
      ...sources.where((s) => s != seedSrc || hasSeed),
    ];
    // 去重保序
    final seenSrc = <String>{};
    final searchOrder = <String>[
      for (final s in ordered)
        if (seenSrc.add(s)) s,
    ];

    Future<void> handleSearchHit(String src, List<VodItem> list) async {
      if (!mounted || my != token) return;
      final usable = vod.applyYellowFilter(list);
      final exact = usable
          .where((i) => i.vodName.trim() == widget.title.trim())
          .toList();
      List<VodItem> pick;
      if (seedId.isNotEmpty && src == seedSrc) {
        final byId = usable.where((i) => i.vodId == seedId).toList();
        pick = byId.isNotEmpty ? byId : exact;
      } else {
        pick = exact;
      }
      final label = store.resolveSource(src)?.name ?? src;
      var shouldLoad = false;
      var loadIdx = selected;
      setState(() {
        pending.remove(label);
        if (pick.isNotEmpty) {
          _addResults(pick);
        } else if (usable.isNotEmpty && results.isEmpty && pending.isEmpty) {
          _addResults(usable);
        } else if (exact.isEmpty && usable.isNotEmpty) {
          if (pending.isEmpty && results.isEmpty) _addResults(usable);
        }
        if (selected < 0 && results.isNotEmpty) {
          var idx = 0;
          if (seedId.isNotEmpty) {
            final i = results.indexWhere((e) =>
                e.vodId == seedId &&
                (seedSrc.isEmpty || e.sourceCode == seedSrc));
            if (i >= 0) idx = i;
          } else if (widget.preferSource != null) {
            final i =
                results.indexWhere((e) => e.sourceCode == widget.preferSource);
            if (i >= 0) idx = i;
          }
          selected = idx;
        }
        if (results.isNotEmpty || pending.isEmpty) loading = false;
        if (results.isEmpty && pending.isEmpty) {
          status = '未找到可播放的片源';
        }
        if (!hasSeed && selected >= 0 && detail == null) {
          shouldLoad = true;
          loadIdx = selected;
        }
      });
      if (shouldLoad) await _loadEpisodes(loadIdx, my);
    }

    if (!hasSeed && searchOrder.isNotEmpty) {
      final first = searchOrder.first;
      try {
        final list = await vod.searchSource(first, widget.title);
        await handleSearchHit(first, list);
      } catch (_) {
        await handleSearchHit(first, const []);
      }
      for (final src in searchOrder.skip(1)) {
        // ignore: unawaited_futures
        vod.searchSource(src, widget.title).then((list) => handleSearchHit(src, list));
      }
    } else {
      for (final src in searchOrder) {
        // ignore: unawaited_futures
        vod.searchSource(src, widget.title).then((list) => handleSearchHit(src, list));
      }
    }
  }

  /// 正序 0..n-1；倒序须新建列表，禁止 setAll(reversed) 同表读写（会重复/错乱）
  List<int> _episodeOrder(int length, bool reversed) {
    if (length <= 0) return const [];
    if (!reversed) return List<int>.generate(length, (i) => i);
    return List<int>.generate(length, (i) => length - 1 - i);
  }

  Future<void> _openEpisodeSheet() async {
    final eps = _currentEpisodes;
    if (eps.isEmpty) return;
    final store = context.read<SettingsStore>();
    final order = _episodeOrder(eps.length, store.episodesReversed);
    final picked = await showDialog<int>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _EpisodePickDialog(
        title: '选集 · ${eps.length} 集',
        labels: [
          for (final i in order)
            eps.length == 1
                ? '播放'
                : (eps[i].name.isNotEmpty ? eps[i].name : '第${i + 1}集'),
        ],
        indexMap: order,
        resumeIndex: widget.resumeEpisode,
      ),
    );
    if (!mounted || picked == null) return;
    await _play(picked);
  }

  Future<void> _loadEpisodes(int idx, int my) async {
    if (idx < 0 || idx >= results.length) return;
    final item = results[idx];
    final key = _cacheKey(item);
    final cached = _detailCache[key];
    if (cached != null) {
      setState(() {
        selected = idx;
        detail = cached;
        lineIndex = cached.preferredLineIndex.clamp(
          0,
          (cached.effectiveLines.isEmpty
                  ? 1
                  : cached.effectiveLines.length) -
              1,
        );
        if (cached.desc.isNotEmpty) synopsis = cached.desc;
        status = synopsis.isEmpty ? '暂无简介' : synopsis;
        loading = false;
        switching = false;
      });
      return;
    }

    final store = context.read<SettingsStore>();
    final vod = VodService(store);
    setState(() {
      selected = idx;
      detail = null; // 只清空选集；简介保留
      lineIndex = 0;
      switching = true;
      _epAutofocusDone = false;
      if (synopsis.isEmpty) status = '加载剧集…';
    });
    try {
      final d = await vod.fetchDetail(item);
      if (!mounted || my != token) return;
      _detailCache[key] = d;
      // 用户可能已切到别的源，只在仍选中本源时更新展示
      if (selected != idx) return;
      setState(() {
        detail = d;
        lineIndex = d.preferredLineIndex.clamp(
          0,
          (d.effectiveLines.isEmpty ? 1 : d.effectiveLines.length) - 1,
        );
        if (d.desc.isNotEmpty) synopsis = d.desc;
        status = synopsis.isEmpty ? '暂无简介' : synopsis;
        loading = false;
        switching = false;
      });
    } catch (e) {
      if (!mounted || my != token) return;
      if (selected != idx) return;
      setState(() {
        loading = false;
        switching = false;
        if (synopsis.isEmpty) status = '剧集加载失败：$e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('该源加载失败：$e')),
        );
      }
    }
  }

  Future<void> _play(int epIndex, {bool fromNextSource = false}) async {
    final d = detail;
    final eps = _currentEpisodes;
    if (d == null || epIndex < 0 || epIndex >= eps.length) return;
    if (selected < 0 || selected >= results.length) return;
    final item = results[selected];
    final store = context.read<SettingsStore>();
    final lines = _lines;
    final title = d.title.isEmpty ? widget.title : d.title;
    final cover = widget.cover ?? d.cover;
    // 续播进度：历史入口带入，或本地历史同集（换源时不强行 seek）
    var resumeMs = 0;
    if (!fromNextSource) {
      if (widget.resumeEpisode == epIndex &&
          (widget.resumePositionMs ?? 0) > 0) {
        resumeMs = widget.resumePositionMs!;
      } else {
        final hit =
            store.findHistory(vodId: item.vodId, sourceCode: item.sourceCode);
        if (hit != null && hit.episodeIndex == epIndex) {
          resumeMs = hit.positionMs;
        }
      }
    }
    // 历史写入失败不能挡播放
    try {
      await store.recordHistory(HistoryItem(
        title: title,
        cover: cover,
        sourceCode: item.sourceCode,
        sourceName: item.sourceName,
        apiUrl: item.apiUrl,
        vodId: item.vodId,
        episodeIndex: epIndex,
        positionMs: resumeMs,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (_) {}
    if (!mounted) return;
    final popped = await Navigator.of(context).push<Object?>(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        title: title,
        episodes: eps,
        lines: lines,
        initialLineIndex: lineIndex,
        initialIndex: epIndex,
        initialPositionMs: resumeMs,
        cover: cover,
        sourceCode: item.sourceCode,
        sourceName: item.sourceName,
        apiUrl: item.apiUrl,
        vodId: item.vodId,
        hasNextSource: results.length > 1,
      ),
    ));
    if (!mounted) return;
    if (popped == PlayerScreen.popNextSource) {
      await _switchToNextSourceAndPlay(epIndex);
    }
  }

  Future<void> _switchToNextSourceAndPlay(int epIndex) async {
    if (results.length < 2) return;
    final next = (selected + 1) % results.length;
    final my = token;
    await _loadEpisodes(next, my);
    if (!mounted || my != token) return;
    if (detail == null || _currentEpisodes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下一源暂无剧集，可再试其它源')),
        );
      }
      return;
    }
    final safeEp = epIndex.clamp(0, _currentEpisodes.length - 1);
    await _play(safeEp, fromNextSource: true);
  }

  Future<void> _openSourceMenu(BuildContext buttonContext) async {
    final initial = selected >= 0 ? selected : 0;
    final picked = await showDialog<int>(
      context: buttonContext,
      barrierDismissible: true,
      builder: (ctx) => _SourcePickDialog(
        items: [
          for (var i = 0; i < results.length; i++)
            (
              index: i,
              label:
                  '${results[i].sourceName}${results[i].remarks.isNotEmpty ? ' · ${results[i].remarks}' : ''}',
              selected: i == selected,
            ),
        ],
        pendingLabel:
            pending.isEmpty ? null : '探测中：${pending.join('、')}',
        initialIndex: initial.clamp(0, results.isEmpty ? 0 : results.length - 1),
      ),
    );
    if (!mounted || picked == null || picked < 0) return;
    if (picked == selected) {
      if (_currentEpisodes.isNotEmpty) {
        await _play(widget.resumeEpisode ?? 0);
      }
      return;
    }
    await _loadEpisodes(picked, token);
  }

  Future<void> _toggleFavorite() async {
    if (selected < 0 || selected >= results.length) return;
    final item = results[selected];
    if (item.vodId.isEmpty) return;
    final store = context.read<SettingsStore>();
    final d = detail;
    await store.toggleFavorite(FavoriteItem(
      title: (d?.title.isNotEmpty == true) ? d!.title : widget.title,
      cover: widget.cover ?? d?.cover ?? item.vodPic,
      sourceCode: item.sourceCode,
      sourceName: item.sourceName,
      apiUrl: item.apiUrl,
      vodId: item.vodId,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cover = widget.cover ?? detail?.cover ?? '';
    final hd = cover
        .replaceAll('/s_ratio_poster/', '/l_ratio_poster/')
        .replaceAll('/m_ratio_poster/', '/l_ratio_poster/');
    final store = context.watch<SettingsStore>();
    final lines = _lines;
    final eps = _currentEpisodes;
    final safeLine =
        lines.isEmpty ? 0 : lineIndex.clamp(0, lines.length - 1);
    final order = _episodeOrder(eps.length, store.episodesReversed);
    final title = detail?.title.isNotEmpty == true ? detail!.title : widget.title;
    final metaBits = [
      if ((detail?.year ?? '').isNotEmpty) detail!.year,
      if ((detail?.area ?? '').isNotEmpty) detail!.area,
      if ((detail?.type ?? '').isNotEmpty) detail!.type,
      if (selected >= 0 && selected < results.length)
        results[selected].sourceName,
    ];
    final screenW = MediaQuery.sizeOf(context).width;
    final posterW = (screenW * 0.22).clamp(160.0, 280.0);

    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 8, 20, 28),
              child: SizedBox(
                width: posterW,
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55),
                          blurRadius: 36,
                          offset: const Offset(0, 18),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: hd.isEmpty
                          ? const ColoredBox(color: AppTheme.panel)
                          : AppNetworkImage(
                              url: hd,
                              fit: BoxFit.cover,
                              alignment: Alignment.topCenter,
                            ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(0, 4, 28, 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: (screenW * 0.032).clamp(28.0, 48.0),
                        fontWeight: FontWeight.w900,
                        height: 1.15,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (metaBits.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final m in metaBits)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: AppTheme.glass,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.1),
                                ),
                              ),
                              child: Text(
                                m,
                                style: const TextStyle(
                                  color: AppTheme.textDim,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: Text(
                        synopsis.isNotEmpty ? synopsis : status,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textDim,
                          height: 1.65,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (!loading &&
                        results.isEmpty &&
                        status.contains('设置')) ...[
                      const SizedBox(height: 16),
                      Focusable(
                        autofocus: true,
                        scale: 1.04,
                        borderRadius: 10,
                        glass: false,
                        onTap: () {
                          widget.onBack();
                          ShellScreen.of(context)?.go(AppTab.settings);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          color: AppTheme.accent,
                          child: const Text('去设置添加采集源',
                              style: TextStyle(fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ],
                    // 不再放「播放第x集」：直接下方选集点播
                    Builder(builder: (context) {
                      final canFav = selected >= 0 &&
                          selected < results.length &&
                          results[selected].vodId.isNotEmpty;
                      if (!canFav) return const SizedBox.shrink();
                      final fav = store.isFavorite(
                        vodId: results[selected].vodId,
                        sourceCode: results[selected].sourceCode,
                      );
                      return Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Focusable(
                            scale: 1.04,
                            borderRadius: 12,
                            onTap: _toggleFavorite,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: fav
                                    ? AppTheme.neon.withValues(alpha: 0.2)
                                    : AppTheme.panel,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: fav
                                      ? AppTheme.neon
                                      : Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              child: Text(
                                fav ? '已收藏' : '收藏',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: fav ? AppTheme.neon : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                    const _SectionTitle('播放源'),
                    const SizedBox(height: 8),
                    // 切换源：Material showMenu，不自研悬浮层
                    Builder(builder: (context) {
                      final curName = selected >= 0 && selected < results.length
                          ? results[selected].sourceName
                          : (widget.seedSourceName ?? '加载中');
                      final curRemark = selected >= 0 &&
                              selected < results.length &&
                              results[selected].remarks.isNotEmpty
                          ? ' · ${results[selected].remarks}'
                          : '';
                      final otherCount = (results.length - 1)
                              .clamp(0, 999) +
                          pending.length;
                      final canSwitch =
                          results.length > 1 || pending.isNotEmpty;
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 11),
                            decoration: BoxDecoration(
                              color: AppTheme.accent,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '$curName$curRemark',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          if (canSwitch)
                            Builder(builder: (btnCtx) {
                              return Focusable(
                                scale: 1.05,
                                borderRadius: 999,
                                onTap: () => _openSourceMenu(btnCtx),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 11),
                                  decoration: BoxDecoration(
                                    color: AppTheme.panel,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.white
                                          .withValues(alpha: 0.12),
                                    ),
                                  ),
                                  child: Text(
                                    otherCount > 0
                                        ? '切换源 · $otherCount'
                                        : '切换源',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              );
                            }),
                        ],
                      );
                    }),
                    if (lines.length > 1) ...[
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const _SectionTitle('播放线路'),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              lines.any((l) => l.looksLike4k)
                                  ? '已优先 4K'
                                  : '卡了可换 · 避开「易失败」',
                              style: const TextStyle(
                                color: AppTheme.neon,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < lines.length; i++)
                            Focusable(
                              scale: 1.05,
                              borderRadius: 999,
                              onTap: () => _selectLine(i),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 9),
                                decoration: BoxDecoration(
                                  color: i == safeLine
                                      ? AppTheme.neon.withValues(alpha: 0.22)
                                      : AppTheme.panel,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: i == safeLine
                                        ? AppTheme.neon
                                        : Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: Text(
                                  lines[i].looksLike4k
                                      ? '★ ${lines[i].name}'
                                      : lines[i].name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: i == safeLine
                                        ? AppTheme.neon
                                        : AppTheme.textDim,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    // 标题行按钮 + 5 排预览网格同一 FocusTraversalGroup，保证下键能进格子
                    LayoutBuilder(
                      builder: (context, c) {
                        const rowH = 48.0;
                        const gap = 10.0;
                        const maxRows = 5;
                        final colW = 108.0;
                        final cols =
                            (c.maxWidth / (colW + gap)).floor().clamp(3, 10);
                        final previewCount = eps.isEmpty
                            ? 0
                            : (cols * maxRows).clamp(0, order.length);
                        final gridH =
                            maxRows * rowH + (maxRows - 1) * gap;
                        final headerNodes = <FocusNode>[
                          _epExitUpFocus,
                          if (eps.isNotEmpty) _epAllFocus,
                        ];
                        return FocusTraversalGroup(
                          policy: _EpisodeGridTraversalPolicy(
                            cols,
                            headerFocusNodes: headerNodes,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  const _SectionTitle('选集'),
                                  const SizedBox(width: 14),
                                  Focusable(
                                    focusNode: _epExitUpFocus,
                                    autofocus: !loading &&
                                        results.isNotEmpty &&
                                        eps.isEmpty &&
                                        !switching,
                                    scale: 1.04,
                                    borderRadius: 999,
                                    glass: false,
                                    onTap: () => store.setEpReversed(
                                        !store.episodesReversed),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: AppTheme.panel,
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        border: Border.all(
                                          color: Colors.white
                                              .withValues(alpha: 0.1),
                                        ),
                                      ),
                                      child: Text(
                                        store.episodesReversed
                                            ? '正序排列'
                                            : '倒序排列',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (eps.isNotEmpty) ...[
                                    const SizedBox(width: 10),
                                    Focusable(
                                      focusNode: _epAllFocus,
                                      scale: 1.04,
                                      borderRadius: 999,
                                      glass: false,
                                      onTap: _openEpisodeSheet,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: AppTheme.accent,
                                          borderRadius:
                                              BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '全部选集 · ${eps.length}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 10),
                              if (switching)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      ),
                                      SizedBox(width: 10),
                                      Text('加载该源剧集…',
                                          style: TextStyle(
                                              color: AppTheme.textDim)),
                                    ],
                                  ),
                                )
                              else if (eps.isEmpty)
                                Text(
                                  loading ? '加载剧集…' : '该源暂无可播放剧集',
                                  style: const TextStyle(
                                      color: AppTheme.textDim),
                                )
                              else ...[
                                // 最多 5 排、不可滚动；更多请进「全部选集」
                                SizedBox(
                                  height: gridH,
                                  child: GridView.builder(
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    itemCount: previewCount,
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: cols,
                                      mainAxisExtent: rowH,
                                      crossAxisSpacing: gap,
                                      mainAxisSpacing: gap,
                                    ),
                                    itemBuilder: (_, idx) {
                                      final i = order[idx];
                                      final label = eps.length == 1
                                          ? '播放'
                                          : (eps[i].name.isNotEmpty
                                              ? eps[i].name
                                              : '第${i + 1}集');
                                      return FocusTraversalOrder(
                                        order: NumericFocusOrder(
                                            idx.toDouble()),
                                        child: _EpisodeCell(
                                          label: label,
                                          resume:
                                              i == widget.resumeEpisode,
                                          autofocus: idx == 0 &&
                                              !_epAutofocusDone,
                                          onTap: () => _play(i),
                                          onFocused: idx == 0
                                              ? () {
                                                  if (!_epAutofocusDone) {
                                                    _epAutofocusDone =
                                                        true;
                                                  }
                                                }
                                              : null,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                if (order.length > previewCount)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 10),
                                    child: Text(
                                      '仅显示前 5 排 · 其余请打开「全部选集」',
                                      style: TextStyle(
                                        color: AppTheme.textDim,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // 无指定源时：先全屏加载，找到片源后再交互（避免焦点被反复重建抢走）
        if (loading && results.isEmpty)
          const AbsorbPointer(
            child: LoadingOverlay(message: '正在查找片源…'),
          ),
      ],
    );
  }
}

/// 选集区：标题按钮与预览网格同一组。
/// 标题行按下 → 第 0 格；第 0 排按上 → 正序按钮；末排再下 → 全部选集（若有）。
class _EpisodeGridTraversalPolicy extends OrderedTraversalPolicy {
  _EpisodeGridTraversalPolicy(
    this.crossAxisCount, {
    required this.headerFocusNodes,
  });

  final int crossAxisCount;
  /// 标题行可聚焦节点，顺序一般为 [正序, 全部选集?]
  final List<FocusNode> headerFocusNodes;

  bool _isHeader(FocusNode n) => headerFocusNodes.contains(n);

  List<FocusNode> _gridNodes(FocusNode currentNode) {
    final scope = currentNode.nearestScope;
    if (scope == null) return const [];
    final sorted =
        sortDescendants(scope.traversalDescendants, currentNode).toList();
    final grid = <FocusNode>[];
    for (final n in sorted) {
      final ctx = n.context;
      if (ctx == null) continue;
      if (FocusTraversalOrder.maybeOf(ctx) is NumericFocusOrder) {
        grid.add(n);
      }
    }
    return grid;
  }

  FocusNode? _liveHeader(FocusNode preferred) {
    if (preferred.canRequestFocus) return preferred;
    for (final n in headerFocusNodes) {
      if (n.canRequestFocus) return n;
    }
    return null;
  }

  /// 离开选集 FocusTraversalGroup：用阅读序找组外控件（线路/源/收藏…）
  bool _exitSection(FocusNode currentNode, TraversalDirection direction) {
    return ReadingOrderTraversalPolicy().inDirection(currentNode, direction);
  }

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final grid = _gridNodes(currentNode);
    final cols = crossAxisCount.clamp(1, 99);
    final headers =
        headerFocusNodes.where((n) => n.canRequestFocus).toList();

    if (_isHeader(currentNode)) {
      final hi = headers.indexOf(currentNode);
      switch (direction) {
        case TraversalDirection.down:
          if (grid.isEmpty) return false;
          grid.first.requestFocus();
          return true;
        case TraversalDirection.right:
          if (hi >= 0 && hi + 1 < headers.length) {
            headers[hi + 1].requestFocus();
            return true;
          }
          return false;
        case TraversalDirection.left:
          if (hi > 0) {
            headers[hi - 1].requestFocus();
            return true;
          }
          // 标题行最左再左：离开选集区
          return _exitSection(currentNode, TraversalDirection.left);
        case TraversalDirection.up:
          // 标题行再上：回到线路 / 源 / 收藏等（不要 return false 把焦点困住）
          return _exitSection(currentNode, TraversalDirection.up);
      }
    }

    final i = grid.indexOf(currentNode);
    if (i < 0) return super.inDirection(currentNode, direction);

    int? next;
    switch (direction) {
      case TraversalDirection.right:
        if (i + 1 < grid.length) next = i + 1;
      case TraversalDirection.left:
        if (i > 0) next = i - 1;
      case TraversalDirection.down:
        if (i + cols < grid.length) {
          next = i + cols;
        } else {
          // 末排再下：落到「全部选集」（列表末项），否则停住
          final all = headers.length > 1 ? headers.last : null;
          if (all != null) {
            all.requestFocus();
            return true;
          }
          return false;
        }
      case TraversalDirection.up:
        if (i - cols >= 0) {
          next = i - cols;
        } else {
          final up = _liveHeader(headerFocusNodes.first);
          if (up != null) {
            up.requestFocus();
            return true;
          }
          return _exitSection(currentNode, TraversalDirection.up);
        }
    }
    if (next == null) return false;
    grid[next].requestFocus();
    return true;
  }
}

/// 选集悬浮窗：固定高度网格，可滚动，避免详情页铺开上百个焦点节点
class _EpisodePickDialog extends StatefulWidget {
  const _EpisodePickDialog({
    required this.title,
    required this.labels,
    required this.indexMap,
    this.resumeIndex,
  });

  final String title;
  final List<String> labels;
  final List<int> indexMap;
  final int? resumeIndex;

  @override
  State<_EpisodePickDialog> createState() => _EpisodePickDialogState();
}

class _EpisodePickDialogState extends State<_EpisodePickDialog> {
  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.7;
    return AlertDialog(
      backgroundColor: AppTheme.bgElevated,
      title: Text(widget.title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      content: SizedBox(
        width: 560,
        height: maxH,
        child: GridView.builder(
          itemCount: widget.labels.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            mainAxisExtent: 48,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemBuilder: (_, idx) {
            final epIndex = widget.indexMap[idx];
            return _EpisodeCell(
              label: widget.labels[idx],
              resume: epIndex == widget.resumeIndex,
              autofocus: idx == 0,
              // 文案溢出时焦点会弹出 Tooltip 显示全称
              onTap: () => Navigator.pop(context, epIndex),
            );
          },
        ),
      ),
      actions: [
        Focusable(
          scale: 1.04,
          borderRadius: 8,
          glass: false,
          glow: false,
          onTap: () => Navigator.pop(context),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text('取消', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

/// 切换源弹窗：用 Material ListTile（自带焦点），方向键/回车可切换
class _SourcePickDialog extends StatefulWidget {
  const _SourcePickDialog({
    required this.items,
    required this.initialIndex,
    this.pendingLabel,
  });

  final List<({int index, String label, bool selected})> items;
  final int initialIndex;
  final String? pendingLabel;

  @override
  State<_SourcePickDialog> createState() => _SourcePickDialogState();
}

class _SourcePickDialogState extends State<_SourcePickDialog> {
  late final FocusNode _firstFocus;

  @override
  void initState() {
    super.initState();
    _firstFocus = FocusNode(debugLabel: 'sourcePickFirst');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_firstFocus.canRequestFocus) _firstFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _firstFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final init = widget.initialIndex.clamp(0, widget.items.length - 1);
    return AlertDialog(
      backgroundColor: AppTheme.bgElevated,
      title: const Text('切换播放源',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.items.length; i++)
                ListTile(
                  focusNode: i == init ? _firstFocus : null,
                  autofocus: i == init,
                  selected: widget.items[i].selected,
                  selectedTileColor: AppTheme.accent.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: widget.items[i].selected
                          ? AppTheme.neon.withValues(alpha: 0.45)
                          : Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  title: Text(
                    '${widget.items[i].label}${widget.items[i].selected ? '  ✓' : ''}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: widget.items[i].selected
                          ? Colors.white
                          : AppTheme.textDim,
                    ),
                  ),
                  onTap: () =>
                      Navigator.of(context).pop(widget.items[i].index),
                ),
              if (widget.pendingLabel != null)
                ListTile(
                  enabled: false,
                  title: Text(
                    widget.pendingLabel!,
                    style: const TextStyle(
                        color: AppTheme.textDim, fontSize: 13),
                  ),
                ),
              ListTile(
                title: const Text('取消',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textDim)),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选集格：仅文案溢出时用 Material Tooltip 显示全称
class _EpisodeCell extends StatefulWidget {
  const _EpisodeCell({
    required this.label,
    required this.resume,
    required this.onTap,
    this.autofocus = false,
    this.onFocused,
  });

  final String label;
  final bool resume;
  final VoidCallback onTap;
  final bool autofocus;
  final VoidCallback? onFocused;

  @override
  State<_EpisodeCell> createState() => _EpisodeCellState();
}

class _EpisodeCellState extends State<_EpisodeCell> {
  final _tipKey = GlobalKey<TooltipState>();
  static const _style = TextStyle(
    fontWeight: FontWeight.w600,
    color: AppTheme.text,
  );

  void _onFocus(bool on, bool overflow) {
    if (on) widget.onFocused?.call();
    if (on && overflow) {
      Tooltip.dismissAllToolTips();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _tipKey.currentState?.ensureTooltipVisible();
      });
    } else if (!on) {
      Tooltip.dismissAllToolTips();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final overflow =
            textExceedsWidth(widget.label, _style, c.maxWidth - 16);
        // 选集不放大：放大会改几何，方向键容易跳行
        final chip = Focusable(
          autofocus: widget.autofocus,
          scale: 1.0,
          borderRadius: 8,
          glass: false,
          onTap: widget.onTap,
          onFocusChange: (on) => _onFocus(on, overflow),
          child: Stack(
            children: [
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                color: AppTheme.panel,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _style,
                ),
              ),
              if (widget.resume)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: const BoxDecoration(
                      color: AppTheme.neon,
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(6),
                      ),
                    ),
                    child: const Text(
                      '续',
                      style: TextStyle(
                        color: Color(0xFF04110C),
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
        if (!overflow) return chip;
        return Tooltip(
          key: _tipKey,
          message: widget.label,
          preferBelow: false,
          waitDuration: Duration.zero,
          showDuration: const Duration(seconds: 4),
          decoration: BoxDecoration(
            color: const Color(0xF0161F33),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.neon.withValues(alpha: 0.65)),
          ),
          textStyle: const TextStyle(
            color: AppTheme.text,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
          child: chip,
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 4,
          height: 18,
          margin: const EdgeInsets.only(right: 10),
          decoration: BoxDecoration(
            color: AppTheme.neon,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Text(
          text,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}
