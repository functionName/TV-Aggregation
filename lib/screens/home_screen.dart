import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/douban_service.dart';
import '../services/settings_store.dart';
import '../services/vod_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import 'shell_screen.dart';

typedef OpenDetail = void Function(
  String title, {
  String? cover,
  int? resume,
  int? resumePosition,
  String? source,
  String? vodId,
  String? sourceName,
  String? apiUrl,
  String? remarks,
  String? playFrom,
  String? playUrl,
  String? desc,
  String? year,
  String? area,
  String? typeName,
});

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onOpen});
  final OpenDetail onOpen;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _douban = DoubanService();
  final Map<String, List<DoubanSubject>> _rows = {};
  DoubanSubject? _hero;
  List<VodItem> _vodItems = [];
  VodItem? _vodHero;
  String _heroCover = '';
  String _heroBadge = '';
  Timer? _heroCoverDebounce;
  bool _loading = true;
  String? _error;
  String? _seenFeedKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _heroCoverDebounce?.cancel();
    super.dispose();
  }

  void _setHeroCover(String cover, {bool immediate = false}) {
    if (immediate) {
      _heroCoverDebounce?.cancel();
      setState(() => _heroCover = cover);
      return;
    }
    _heroCoverDebounce?.cancel();
    _heroCoverDebounce = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      if (cover != _heroCover) setState(() => _heroCover = cover);
    });
  }

  void _selectHero(DoubanSubject s, {bool immediateCover = false}) {
    setState(() {
      _hero = s;
      _vodHero = null;
      _heroBadge = '★ ${PosterCard.displayRate(s.rate)}  ·  豆瓣';
    });
    final cover = s.hdCover.isNotEmpty ? s.hdCover : s.cover;
    _setHeroCover(cover, immediate: immediateCover);
  }

  void _selectVodHero(VodItem v, {bool immediateCover = false}) {
    setState(() {
      _vodHero = v;
      _hero = null;
      _heroBadge = v.sourceName.isNotEmpty
          ? (v.remarks.isNotEmpty ? '${v.remarks}  ·  ${v.sourceName}' : v.sourceName)
          : (v.remarks.isNotEmpty ? v.remarks : '采集源');
    });
    _setHeroCover(v.vodPic, immediate: immediateCover);
  }

  void _openVod(VodItem v) {
    widget.onOpen(
      v.vodName,
      cover: v.vodPic,
      source: v.sourceCode,
      vodId: v.vodId.isEmpty ? null : v.vodId,
      sourceName: v.sourceName,
      apiUrl: v.apiUrl,
      remarks: v.remarks.isEmpty ? null : v.remarks,
      playFrom: v.playFrom,
      playUrl: v.playUrl,
      desc: v.desc,
      year: v.year,
      area: v.area,
      typeName: v.typeName.isEmpty ? null : v.typeName,
    );
  }

  Future<void> _load() async {
    final store = context.read<SettingsStore>();
    setState(() {
      _loading = true;
      _error = null;
      _rows.clear();
      _hero = null;
      _vodItems = [];
      _vodHero = null;
      _heroCover = '';
      _heroBadge = '';
    });

    if (!store.useDoubanFeed) {
      try {
        final list = await VodService(store).listFeedLatest(limit: 24);
        if (!mounted) return;
        if (list.isEmpty) {
          setState(() {
            _error = store.effectiveFeedSourceCode == null
                ? '请到「设置 → 推荐数据」选择一个采集源，或改回豆瓣。'
                : '该源暂无最新内容。请用顶部「搜索」，或换一个源。';
          });
        } else {
          final first = list.first;
          _heroCoverDebounce?.cancel();
          setState(() {
            _vodItems = list;
            _vodHero = first;
            _hero = null;
            _heroCover = first.vodPic;
            _heroBadge = first.sourceName.isNotEmpty
                ? (first.remarks.isNotEmpty
                    ? '${first.remarks}  ·  ${first.sourceName}'
                    : first.sourceName)
                : (first.remarks.isNotEmpty ? first.remarks : '采集源');
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() => _error = '采集源推荐加载失败。请用顶部「搜索」。');
        }
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }

    try {
      for (final cfg in homeRows) {
        List<DoubanSubject> list = const [];
        try {
          list = await _douban
              .searchSubjects(type: cfg.type, tag: cfg.tag, limit: 8)
              .timeout(const Duration(seconds: 8));
        } catch (_) {
          list = const [];
        }
        if (!mounted) return;
        if (list.isEmpty) continue;
        setState(() {
          _rows[cfg.title] = list;
          if (_hero == null && list.isNotEmpty) {
            final s = list.first;
            _hero = s;
            _vodHero = null;
            _heroCoverDebounce?.cancel();
            _heroCover = s.hdCover.isNotEmpty ? s.hdCover : s.cover;
            _heroBadge = '★ ${PosterCard.displayRate(s.rate)}  ·  豆瓣';
          }
          _loading = false;
        });
      }
      if (_rows.isEmpty && mounted) {
        setState(() =>
            _error = '无法加载豆瓣推荐（网络）。仍可用顶部「搜索」或「继续观看」。');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '豆瓣推荐暂时无法加载。请先用顶部「搜索」。');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final history = store.viewingHistory;
    final continueList = history.take(12).toList();
    final feedKey = '${store.feedMode}|${store.feedSourceCode}';
    if (_seenFeedKey != feedKey) {
      final changed = _seenFeedKey != null;
      _seenFeedKey = feedKey;
      if (changed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load();
        });
      }
    }

    final hasFeed = _rows.isNotEmpty || _vodItems.isNotEmpty;
    final heroTitle = _vodHero?.vodName ?? _hero?.title;
    final canOpenHero = _vodHero != null || _hero != null;

    if (_loading && !hasFeed && continueList.isEmpty) {
      return const LoadingOverlay(message: '加载首页推荐…');
    }
    if (!hasFeed && continueList.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandLogo(height: 40),
              const SizedBox(height: 24),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(
                  _error ?? '暂无推荐内容',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textDim, height: 1.5),
                ),
              ),
              const SizedBox(height: 20),
              Focusable(
                autofocus: true,
                onTap: () => ShellScreen.of(context)?.go(AppTab.search),
                scale: 1.05,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  color: AppTheme.accent,
                  child: const Text('去搜索',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 12),
              Focusable(
                onTap: _load,
                scale: 1.05,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  color: AppTheme.panel,
                  child: const Text('重试加载',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final w = MediaQuery.sizeOf(context).width;
    // 大约一屏 5～6 张，单卡更大更好认
    final tileW = (w * 0.155).clamp(140.0, 220.0);
    final vodRowTitle = '${store.feedModeLabel} · 最新';

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            if (canOpenHero)
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: _Hero(
                    title: heroTitle ?? '影视聚合',
                    coverUrl: _heroCover,
                    badge: _heroBadge,
                    onOpen: () {
                      if (_vodHero != null) {
                        _openVod(_vodHero!);
                      } else if (_hero != null) {
                        widget.onOpen(_hero!.title, cover: _hero!.cover);
                      }
                    },
                  ),
                ),
              ),
            if (continueList.isNotEmpty)
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: _ContinueRow(
                    items: continueList,
                    tileW: tileW,
                    autofocusFirst: !hasFeed,
                    onOpen: widget.onOpen,
                  ),
                ),
              ),
            if (_vodItems.isNotEmpty)
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: _VodRow(
                    title: vodRowTitle,
                    items: _vodItems,
                    tileW: tileW,
                    autofocusFirst: continueList.isEmpty,
                    selectedKey: _vodHero == null
                        ? null
                        : '${_vodHero!.sourceCode}|${_vodHero!.vodId}',
                    onOpen: _openVod,
                    onFocusItem: _selectVodHero,
                  ),
                ),
              ),
            for (final e in _rows.entries)
              SliverToBoxAdapter(
                child: RepaintBoundary(
                  child: _Row(
                    title: e.key,
                    items: e.value,
                    tileW: tileW,
                    autofocusFirst: e.key == _rows.keys.first &&
                        continueList.isEmpty &&
                        _vodItems.isEmpty,
                    selectedId: _hero?.id,
                    onOpen: widget.onOpen,
                    onFocusItem: _selectHero,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 48)),
          ],
        ),
        if (_loading)
          const Positioned(
            right: 24,
            top: 8,
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

class _ContinueRow extends StatelessWidget {
  const _ContinueRow({
    required this.items,
    required this.tileW,
    required this.onOpen,
    this.autofocusFirst = false,
  });

  final List<HistoryItem> items;
  final double tileW;
  final OpenDetail onOpen;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Row(
              children: [
                SizedBox(
                  width: 4,
                  height: 18,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
                SizedBox(width: 10),
                Text(
                  '继续观看',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: PosterCard.rowHeight(tileW),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 4),
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 18),
              itemBuilder: (_, i) {
                final h = items[i];
                return PosterCard(
                  title: h.title,
                  cover: h.cover,
                  rate: h.progressLabel,
                  width: tileW,
                  autofocus: autofocusFirst && i == 0,
                  onTap: () => onOpen(
                    h.title,
                    cover: h.cover,
                    resume: h.episodeIndex,
                    resumePosition: h.positionMs > 0 ? h.positionMs : null,
                    source: h.sourceCode,
                    vodId: h.vodId.isEmpty ? null : h.vodId,
                    sourceName:
                        h.sourceName.isEmpty ? null : h.sourceName,
                    apiUrl: h.apiUrl,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.title,
    required this.coverUrl,
    required this.badge,
    required this.onOpen,
  });
  final String title;
  final String coverUrl;
  final String badge;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final h = (size.height * 0.58).clamp(360.0, 620.0);
    final cover = coverUrl;
    final titleSize = (size.width * 0.038).clamp(34.0, 56.0);
    // 全幅海报 + 多层柔和遮罩，避免左侧硬切一块黑
    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: AppTheme.bg),
          if (cover.isNotEmpty)
            AppNetworkImage(
              key: ValueKey(cover),
              url: cover,
              fit: BoxFit.cover,
              alignment: const Alignment(0.15, -0.2),
              memCacheWidth: 1280,
            ),

          // 左侧文字可读区：长距离柔化，不出现竖线硬切
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xF2070B14),
                  Color(0xCC070B14),
                  Color(0x66070B14),
                  Color(0x22070B14),
                  Colors.transparent,
                ],
                stops: [0.0, 0.22, 0.42, 0.62, 0.88],
              ),
            ),
          ),
          // 底部接到海报行
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  AppTheme.bg,
                  Color(0xE6070B14),
                  Color(0x66070B14),
                  Colors.transparent,
                ],
                stops: [0.0, 0.18, 0.42, 0.72],
              ),
            ),
          ),
          // 顶部略压暗，和导航栏衔接
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x99070B14),
                  Colors.transparent,
                ],
                stops: [0.0, 0.28],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 40, 36),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: size.width * 0.48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: AppTheme.accent,
                          ),
                          child: const Text(
                            '精选',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        if (badge.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                color: Colors.black.withValues(alpha: 0.55),
                                border: Border.all(
                                  color: AppTheme.gold.withValues(alpha: 0.45),
                                ),
                              ),
                              child: Text(
                                badge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppTheme.gold,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: titleSize,
                        fontWeight: FontWeight.w900,
                        height: 1.08,
                        letterSpacing: 0.6,
                        shadows: const [
                          Shadow(blurRadius: 20, color: Colors.black87),
                          Shadow(
                            blurRadius: 2,
                            offset: Offset(0, 1),
                            color: Colors.black54,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        Focusable(
                          onTap: onOpen,
                          scale: 1.04,
                          borderRadius: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 30, vertical: 15),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.play_arrow_rounded,
                                    color: Color(0xFF0A0F18), size: 26),
                                SizedBox(width: 6),
                                Text(
                                  '播放',
                                  style: TextStyle(
                                    color: Color(0xFF0A0F18),
                                    fontWeight: FontWeight.w900,
                                    fontSize: 17,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Focusable(
                          onTap: onOpen,
                          scale: 1.04,
                          borderRadius: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 15),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.28),
                              ),
                            ),
                            child: const Text(
                              '更多信息',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VodRow extends StatelessWidget {
  const _VodRow({
    required this.title,
    required this.items,
    required this.tileW,
    required this.onOpen,
    required this.onFocusItem,
    this.autofocusFirst = false,
    this.selectedKey,
  });

  final String title;
  final List<VodItem> items;
  final double tileW;
  final ValueChanged<VodItem> onOpen;
  final ValueChanged<VodItem> onFocusItem;
  final bool autofocusFirst;
  final String? selectedKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 4, 40, 10),
            child: Row(
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
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: PosterCard.rowHeight(tileW),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 4),
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 18),
              itemBuilder: (_, i) {
                final v = items[i];
                final key = '${v.sourceCode}|${v.vodId}';
                return PosterCard(
                  title: v.vodName,
                  cover: v.vodPic,
                  rate: v.sourceName.isNotEmpty ? v.sourceName : v.remarks,
                  width: tileW,
                  autofocus: autofocusFirst && i == 0,
                  selected: selectedKey != null && selectedKey == key,
                  onTap: () => onOpen(v),
                  onFocus: () => onFocusItem(v),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    required this.items,
    required this.tileW,
    required this.onOpen,
    required this.onFocusItem,
    this.autofocusFirst = false,
    this.selectedId,
  });

  final String title;
  final List<DoubanSubject> items;
  final double tileW;
  final OpenDetail onOpen;
  final ValueChanged<DoubanSubject> onFocusItem;
  final bool autofocusFirst;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 4, 40, 10),
            child: Row(
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
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: PosterCard.rowHeight(tileW),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 4),
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 18),
              itemBuilder: (_, i) {
                final s = items[i];
                final selected = selectedId != null && selectedId == s.id;
                return PosterCard(
                  title: s.title,
                  cover: s.cover,
                  rate: s.rate,
                  width: tileW,
                  autofocus: autofocusFirst && i == 0,
                  selected: selected,
                  onTap: () => onOpen(s.title, cover: s.cover),
                  onFocus: () => onFocusItem(s),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
