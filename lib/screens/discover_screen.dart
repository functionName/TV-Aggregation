import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/douban_service.dart';
import '../services/settings_store.dart';
import '../services/vod_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import 'home_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, required this.onOpen});
  final OpenDetail onOpen;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _douban = DoubanService();
  static const forms = ['电影', '电视剧', '综艺', '动画', '纪录片'];
  static const genres = ['剧情', '喜剧', '动作', '爱情', '科幻', '悬疑', '恐怖', '犯罪'];
  static const countries = ['中国大陆', '美国', '韩国', '日本', '英国', '法国', '香港', '台湾'];
  static const pageSize = 20;

  String? form = '电影';
  String? genre;
  String? country;
  List<DoubanSubject> results = [];
  List<VodItem> sourceResults = [];
  List<VodCategory> categories = [];
  /// null = 最新
  String? selectedTypeId;
  bool loading = false;
  bool loadingMore = false;
  bool hasMore = true;
  bool useSourceFeed = false;
  int _sourcePage = 1;
  String? _seenFeedKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final store = context.read<SettingsStore>();
    final doubanOn = store.useDoubanFeed;
    final code = store.effectiveFeedSourceCode;
    setState(() {
      loading = true;
      hasMore = true;
      results = [];
      sourceResults = [];
      categories = [];
      selectedTypeId = null;
      _sourcePage = 1;
      useSourceFeed = !doubanOn;
    });
    try {
      if (!doubanOn) {
        if (code == null) {
          if (!mounted) return;
          setState(() {
            sourceResults = [];
            hasMore = false;
          });
          return;
        }
        final vod = VodService(store);
        final cats = await vod.fetchCategories(code);
        final list = await vod.listByType(code, typeId: null, page: 1);
        if (!mounted) return;
        setState(() {
          categories = cats;
          sourceResults = list;
          hasMore = list.length >= 10;
          _sourcePage = 1;
        });
      } else {
        final list = await _douban.discover(
          form: form,
          type: genre,
          country: country,
          start: 0,
          limit: pageSize,
        );
        if (!mounted) return;
        setState(() {
          results = list;
          hasMore = list.length >= pageSize;
          useSourceFeed = false;
        });
      }
    } catch (e) {
      if (mounted && doubanOn) {
        // 豆瓣失败：若有推荐单源则兜底
        final codeFb = store.effectiveFeedSourceCode ??
            (store.enabledSources.isNotEmpty
                ? store.enabledSources.first
                : null);
        if (codeFb != null) {
          try {
            final vod = VodService(store);
            final cats = await vod.fetchCategories(codeFb);
            final list = await vod.listByType(codeFb, page: 1);
            if (!mounted) return;
            setState(() {
              useSourceFeed = true;
              categories = cats;
              sourceResults = list;
              hasMore = list.length >= 10;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(
                      '豆瓣不可用，已显示「${store.resolveSource(codeFb)?.name ?? '采集源'}」')),
            );
          } catch (_) {
            if (mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('加载失败：$e')));
            }
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('加载失败：$e')));
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _selectCategory(String? typeId) async {
    final store = context.read<SettingsStore>();
    final code = store.effectiveFeedSourceCode;
    if (code == null) return;
    setState(() {
      selectedTypeId = typeId;
      loading = true;
      sourceResults = [];
      _sourcePage = 1;
      hasMore = true;
    });
    try {
      final list = await VodService(store)
          .listByType(code, typeId: typeId, page: 1);
      if (!mounted) return;
      setState(() {
        sourceResults = list;
        hasMore = list.length >= 10;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (loading || loadingMore || !hasMore) return;
    if (useSourceFeed) {
      final store = context.read<SettingsStore>();
      final code = store.effectiveFeedSourceCode;
      if (code == null) return;
      setState(() => loadingMore = true);
      try {
        final next = _sourcePage + 1;
        final list = await VodService(store).listByType(
          code,
          typeId: selectedTypeId,
          page: next,
        );
        if (!mounted) return;
        setState(() {
          final seen = {
            for (final v in sourceResults) '${v.sourceCode}|${v.vodId}',
          };
          final add = list
              .where((v) =>
                  v.vodId.isNotEmpty &&
                  !seen.contains('${v.sourceCode}|${v.vodId}'))
              .toList();
          sourceResults = [...sourceResults, ...add];
          _sourcePage = next;
          hasMore = list.length >= 10;
        });
      } catch (_) {
      } finally {
        if (mounted) setState(() => loadingMore = false);
      }
      return;
    }

    setState(() => loadingMore = true);
    try {
      final list = await _douban.discover(
        form: form,
        type: genre,
        country: country,
        start: results.length,
        limit: pageSize,
      );
      if (!mounted) return;
      setState(() {
        final seen = results.map((e) => e.id).toSet();
        results = [
          ...results,
          ...list.where((e) => e.id.isEmpty || !seen.contains(e.id)),
        ];
        hasMore = list.length >= pageSize;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => loadingMore = false);
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 480) {
      _loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final cross = w > 1200 ? 8 : w > 800 ? 6 : 4;
    final store = context.watch<SettingsStore>();
    final feedKey = '${store.feedMode}|${store.feedSourceCode}';
    if (_seenFeedKey != feedKey) {
      final changed = _seenFeedKey != null;
      _seenFeedKey = feedKey;
      if (changed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _reload();
        });
      }
    }

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (useSourceFeed) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            '${store.feedModeLabel} · 分类浏览',
                            style: const TextStyle(
                              color: AppTheme.neon,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        _sourceCategoryChips(),
                      ] else ...[
                        _chips('形态', forms, form, (v) {
                          setState(() => form = v);
                          _reload();
                        }),
                        _chips('类型', genres, genre, (v) {
                          setState(() => genre = v == genre ? null : v);
                          _reload();
                        }),
                        _chips('地区', countries, country, (v) {
                          setState(() => country = v == country ? null : v);
                          _reload();
                        }),
                      ],
                    ],
                  ),
                ),
              ),
              if (loading && results.isEmpty && sourceResults.isEmpty)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (!loading &&
                  results.isEmpty &&
                  sourceResults.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Text(
                      useSourceFeed && store.effectiveFeedSourceCode == null
                          ? '请到设置选择一个采集源作为推荐'
                          : '暂无内容',
                      style: const TextStyle(color: AppTheme.textDim),
                    ),
                  ),
                )
              else if (useSourceFeed)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
                  sliver: loading && sourceResults.isEmpty
                      ? const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        )
                      : SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: cross,
                            childAspectRatio: 0.55,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (_, i) {
                              final v = sourceResults[i];
                              return PosterCard(
                                title: v.vodName,
                                cover: v.vodPic,
                                rate: v.remarks.isNotEmpty
                                    ? v.remarks
                                    : v.sourceName,
                                width: double.infinity,
                                autofocus: i == 0,
                                onTap: () => widget.onOpen(
                                  v.vodName,
                                  cover: v.vodPic,
                                  source: v.sourceCode,
                                  vodId: v.vodId.isEmpty ? null : v.vodId,
                                  sourceName: v.sourceName,
                                  apiUrl: v.apiUrl,
                                  remarks:
                                      v.remarks.isEmpty ? null : v.remarks,
                                ),
                              );
                            },
                            childCount: sourceResults.length,
                          ),
                        ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cross,
                      childAspectRatio: 0.55,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final s = results[i];
                        return PosterCard(
                          title: s.title,
                          cover: s.cover,
                          rate: s.rate,
                          width: double.infinity,
                          autofocus: i == 0,
                          onTap: () => widget.onOpen(
                            s.title,
                            cover: s.cover,
                          ),
                        );
                      },
                      childCount: results.length,
                    ),
                  ),
                ),
              if (loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 24),
                    child: Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sourceCategoryChips() {
    // 最新 + 分类；分类过多时优先顶层，再补子类（上限约 24，避免遥控难选）
    final tops = categories.where((c) => c.isTopLevel).toList();
    final rest = categories.where((c) => !c.isTopLevel).toList();
    final show = <VodCategory>[
      ...tops,
      ...rest,
    ];
    final capped = show.length > 24 ? show.take(24).toList() : show;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _catChip(
            label: '最新',
            selected: selectedTypeId == null,
            onTap: () {
              if (selectedTypeId == null) return;
              _selectCategory(null);
            },
          ),
          for (final c in capped)
            _catChip(
              label: c.name,
              selected: selectedTypeId == c.id,
              onTap: () {
                if (selectedTypeId == c.id) return;
                _selectCategory(c.id);
              },
            ),
          if (categories.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '该源未返回分类，仅显示最新',
                style: TextStyle(color: AppTheme.textDim, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _catChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Focusable(
      scale: 1.04,
      borderRadius: 8,
      glass: false,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accent : const Color(0xFF121A2B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? AppTheme.neon
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _chips(
    String label,
    List<String> options,
    String? value,
    ValueChanged<String> onPick,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(label,
                  style: const TextStyle(
                      color: AppTheme.textDim, fontWeight: FontWeight.w600)),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in options)
                  Focusable(
                    scale: 1.04,
                    borderRadius: 8,
                    glass: false,
                    onTap: () => onPick(o),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: value == o
                            ? AppTheme.accent
                            : const Color(0xFF121A2B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: value == o
                              ? AppTheme.neon
                              : Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Text(o,
                          style: TextStyle(
                            fontWeight:
                                value == o ? FontWeight.w800 : FontWeight.w600,
                            fontSize: 13,
                          )),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
