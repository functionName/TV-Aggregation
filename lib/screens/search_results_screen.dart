import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import 'home_screen.dart';

/// 单个采集源在本次搜索中的结果桶（TVBox：左侧源列表）
class SearchSourceBucket {
  SearchSourceBucket({
    required this.code,
    required this.name,
    required this.items,
    this.pending = false,
  });

  final String code;
  final String name;
  final List<VodItem> items;
  final bool pending;

  int get count => items.length;

  static List<SearchSourceBucket> merge({
    required List<VodItem> all,
    required List<({String code, String name})> pending,
  }) {
    final order = <String>[];
    final map = <String, SearchSourceBucket>{};
    for (final v in all) {
      final code = v.sourceCode;
      if (!map.containsKey(code)) {
        order.add(code);
        map[code] = SearchSourceBucket(
          code: code,
          name: v.sourceName.isNotEmpty ? v.sourceName : code,
          items: [],
        );
      }
      map[code]!.items.add(v);
    }
    for (final p in pending) {
      if (map.containsKey(p.code)) continue;
      order.add(p.code);
      map[p.code] = SearchSourceBucket(
        code: p.code,
        name: p.name,
        items: [],
        pending: true,
      );
    }
    final ready = order
        .where((c) => !(map[c]!.pending))
        .map((c) => map[c]!)
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    final waiting =
        order.where((c) => map[c]!.pending).map((c) => map[c]!).toList();
    return [...ready, ...waiting];
  }
}

/// 搜索结果页（TVBox）：左源列表+数量，右该源海报；支持边搜边出。
class SearchResultsScreen extends StatefulWidget {
  const SearchResultsScreen({
    super.key,
    required this.query,
    required this.rawResults,
    required this.pendingSources,
    required this.searching,
    required this.onOpen,
    required this.onBack,
  });

  final String query;
  final List<VodItem> rawResults;
  final List<({String code, String name})> pendingSources;
  final bool searching;
  final OpenDetail onOpen;
  final VoidCallback onBack;

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  List<SearchSourceBucket> _buckets = const [];
  int _selected = 0;
  String? _pinnedCode;
  final _firstSourceFocus = FocusNode(debugLabel: 'searchSrc0');
  final _firstPosterFocus = FocusNode(debugLabel: 'searchPoster0');
  bool _didFocusSource = false;

  @override
  void initState() {
    super.initState();
    _rebuildBuckets();
  }

  @override
  void didUpdateWidget(covariant SearchResultsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rawResults, widget.rawResults) ||
        oldWidget.pendingSources != widget.pendingSources ||
        oldWidget.searching != widget.searching) {
      _rebuildBuckets();
    }
  }

  void _rebuildBuckets() {
    final prevCode = _pinnedCode ??
        (_buckets.isNotEmpty && _selected < _buckets.length
            ? _buckets[_selected].code
            : null);
    _buckets = SearchSourceBucket.merge(
      all: widget.rawResults,
      pending: widget.pendingSources,
    );
    var idx = 0;
    if (prevCode != null) {
      final i = _buckets.indexWhere((b) => b.code == prevCode);
      if (i >= 0) idx = i;
    } else {
      final firstReady = _buckets.indexWhere((b) => !b.pending && b.count > 0);
      if (firstReady >= 0) idx = firstReady;
    }
    _selected = _buckets.isEmpty ? 0 : idx.clamp(0, _buckets.length - 1);
    if (!_didFocusSource && _buckets.any((b) => !b.pending && b.count > 0)) {
      _didFocusSource = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_firstSourceFocus.canRequestFocus) {
          _firstSourceFocus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _firstSourceFocus.dispose();
    _firstPosterFocus.dispose();
    super.dispose();
  }

  void _selectSource(int i) {
    if (i < 0 || i >= _buckets.length) return;
    setState(() {
      _selected = i;
      _pinnedCode = _buckets[i].code;
    });
    if (_buckets[i].items.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_firstPosterFocus.canRequestFocus) {
        _firstPosterFocus.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.rawResults.length;
    final bucket =
        _buckets.isEmpty ? null : _buckets[_selected.clamp(0, _buckets.length - 1)];
    final items = bucket?.items ?? const <VodItem>[];
    final doneSources = _buckets.where((b) => !b.pending).length;
    final allSources = _buckets.length;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final isBack = event.logicalKey == LogicalKeyboardKey.goBack ||
            event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.browserBack;
        if (isBack) {
          widget.onBack();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶栏单独一层，滚动海报不会画到它上面
            Material(
              color: AppTheme.bg.withValues(alpha: 0.92),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Focusable(
                      autofocus: _buckets.isEmpty && !widget.searching,
                      scale: 1.02,
                      borderRadius: 10,
                      glass: false,
                      onTap: widget.onBack,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        color: AppTheme.panel,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_back, size: 18),
                            SizedBox(width: 6),
                            Text('返回',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        widget.searching
                            ? '「${widget.query}」· 已出 $total 条 · 源 $doneSources/$allSources 搜索中…'
                            : '「${widget.query}」· $total 条 · $doneSources 个源',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (widget.searching) ...[
                      const SizedBox(width: 10),
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: _buckets.isEmpty
                  ? Center(
                      child: Text(
                        widget.searching ? '正在请求各采集源…' : '没有搜到，返回改词再试',
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 16),
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 220,
                          child: _SourceRail(
                            buckets: _buckets,
                            selected: _selected,
                            firstFocus: _firstSourceFocus,
                            onSelect: _selectSource,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _SourceResultsGrid(
                            items: items,
                            sourceName: bucket?.name ?? '',
                            pending: bucket?.pending ?? false,
                            searching: widget.searching,
                            firstFocus: _firstPosterFocus,
                            onOpen: widget.onOpen,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceRail extends StatelessWidget {
  const _SourceRail({
    required this.buckets,
    required this.selected,
    required this.firstFocus,
    required this.onSelect,
  });

  final List<SearchSourceBucket> buckets;
  final int selected;
  final FocusNode firstFocus;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.panel.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Text(
              '采集源',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: AppTheme.textDim,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              itemCount: buckets.length,
              itemBuilder: (_, i) {
                final b = buckets[i];
                final on = i == selected;
                final firstReady =
                    buckets.indexWhere((x) => !x.pending && x.count > 0);
                final focusHere = i == (firstReady >= 0 ? firstReady : 0);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Focusable(
                    focusNode: focusHere ? firstFocus : null,
                    scale: 1.03,
                    borderRadius: 10,
                    glass: false,
                    onTap: () => onSelect(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: on ? AppTheme.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: on
                              ? AppTheme.accent
                              : Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              b.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: on ? Colors.white : AppTheme.textDim,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (b.pending)
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: on ? Colors.white : AppTheme.neon,
                              ),
                            )
                          else
                            Text(
                              '${b.count}',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                color: on ? Colors.white : AppTheme.neon,
                              ),
                            ),
                        ],
                      ),
                    ),
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

class _SourceResultsGrid extends StatelessWidget {
  const _SourceResultsGrid({
    required this.items,
    required this.sourceName,
    required this.pending,
    required this.searching,
    required this.firstFocus,
    required this.onOpen,
  });

  final List<VodItem> items;
  final String sourceName;
  final bool pending;
  final bool searching;
  final FocusNode firstFocus;
  final OpenDetail onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.panel.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text(
              sourceName.isEmpty
                  ? '搜索结果'
                  : (pending
                      ? '$sourceName · 搜索中…'
                      : '$sourceName · ${items.length} 部'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      pending || searching ? '该源还在请求…' : '该源无结果',
                      style: const TextStyle(color: AppTheme.textDim),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, c) {
                      final cross = c.maxWidth > 1100
                          ? 6
                          : c.maxWidth > 800
                              ? 5
                              : c.maxWidth > 560
                                  ? 4
                                  : 3;
                      return GridView.builder(
                        // 顶部留白，焦点项不被标题条挡住
                        padding: const EdgeInsets.fromLTRB(14, 16, 14, 22),
                        clipBehavior: Clip.none,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cross,
                          childAspectRatio: 0.55,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 14,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          final v = items[i];
                          return PosterCard(
                            title: v.vodName,
                            cover: v.vodPic,
                            rate: v.remarks.isNotEmpty ? v.remarks : sourceName,
                            width: double.infinity,
                            focusNode: i == 0 ? firstFocus : null,
                            onTap: () => onOpen(
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
                              typeName:
                                  v.typeName.isEmpty ? null : v.typeName,
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
