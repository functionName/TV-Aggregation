import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/pinyin_dict.dart';
import '../services/settings_store.dart';
import '../services/suggest_service.dart';
import '../services/vod_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import 'home_screen.dart';
import 'search_results_screen.dart';
import 'shell_screen.dart';

/// 搜索页：键盘搜词；搜完进入分源结果页（TVBox）。
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.onOpen});
  final OpenDetail onOpen;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String query = '';
  String pyBuf = '';
  int pyPage = 0;
  bool queryCommitted = false;
  bool loading = false;
  /// 是否在「分源结果」页（一点搜索就进入，边搜边出）
  bool showResultsPage = false;
  bool resultsSearching = false;
  List<VodItem> rawResults = [];
  List<({String code, String name})> pendingSources = [];
  List<String> suggests = [];
  int suggestToken = 0;
  int searchGen = 0;
  Timer? suggestTimer;
  final _searchBtnFocus = FocusNode(debugLabel: 'searchBtn');
  final _sideFirstFocus = FocusNode(debugLabel: 'searchSideFirst');
  final _deleteFocus = FocusNode(debugLabel: 'searchDelete');
  ShellScreenState? _shell;

  static const keys = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J',
    'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T',
    'U', 'V', 'W', 'X', 'Y', 'Z', '0', '1', '2', '3',
    '4', '5', '6', '7', '8', '9',
  ];
  static const pyPageSize = 10;

  @override
  void initState() {
    super.initState();
    PinyinDict.ensureLoaded();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shell = ShellScreen.of(context);
      _shell?.registerTabBack(_consumeBack);
    });
  }

  @override
  void dispose() {
    suggestTimer?.cancel();
    _searchBtnFocus.dispose();
    _sideFirstFocus.dispose();
    _deleteFocus.dispose();
    _shell?.registerTabBack(null);
    _shell = null;
    super.dispose();
  }

  bool _consumeBack() {
    if (showResultsPage) {
      searchGen++; // 取消进行中的增量搜索
      setState(() {
        showResultsPage = false;
        resultsSearching = false;
        pendingSources = [];
      });
      return true;
    }
    return false;
  }

  void _closeResults() {
    if (!showResultsPage) return;
    searchGen++;
    setState(() {
      showResultsPage = false;
      resultsSearching = false;
      pendingSources = [];
    });
  }

  String get typedQuery {
    final q = query.trim();
    if (pyBuf.isNotEmpty && !SuggestService.hasCjk(q)) {
      return (q + pyBuf).trim();
    }
    return q;
  }

  String get displayQuery {
    if (pyBuf.isEmpty) return query;
    return '$query$pyBuf';
  }

  void _scheduleSuggest() {
    suggestTimer?.cancel();
    final q = typedQuery;
    if (q.length < 2) {
      setState(() => suggests = []);
      suggestToken++;
      return;
    }
    suggestTimer = Timer(const Duration(milliseconds: 450), () async {
      final token = ++suggestToken;
      try {
        final titles = await SuggestService.resolveTitles(q);
        if (!mounted || token != suggestToken || typedQuery != q) return;
        setState(() => suggests = titles);
      } catch (_) {}
    });
  }

  void _append(String ch) {
    if (queryCommitted) {
      query = '';
      pyBuf = '';
      queryCommitted = false;
      showResultsPage = false;
      rawResults = [];
    }
    final mode = context.read<SettingsStore>().kbPinyin;
    if (mode && RegExp(r'^[a-zA-Z]$').hasMatch(ch)) {
      setState(() {
        pyBuf += ch.toLowerCase();
        pyPage = 0;
      });
      _scheduleSuggest();
      return;
    }
    setState(() => query += ch);
    _scheduleSuggest();
  }

  void _backspace() {
    if (pyBuf.isNotEmpty) {
      setState(() {
        queryCommitted = false;
        pyBuf = pyBuf.substring(0, pyBuf.length - 1);
        pyPage = 0;
      });
      _scheduleSuggest();
      return;
    }
    if (query.isEmpty) return;
    setState(() {
      queryCommitted = false;
      query = query.substring(0, query.length - 1);
    });
    _scheduleSuggest();
  }

  void _clear() {
    setState(() {
      queryCommitted = false;
      query = '';
      pyBuf = '';
      pyPage = 0;
      suggests = [];
      showResultsPage = false;
      rawResults = [];
    });
  }

  void _pickPinyin(String ch, int eat) {
    setState(() {
      queryCommitted = false;
      query += ch;
      pyBuf = pyBuf.length > eat ? pyBuf.substring(eat) : '';
      pyPage = 0;
    });
    _scheduleSuggest();
  }

  Future<void> _toggleMode() async {
    final store = context.read<SettingsStore>();
    final next = !store.kbPinyin;
    if (!next && pyBuf.isNotEmpty) {
      setState(() {
        query += pyBuf;
        pyBuf = '';
      });
    }
    await store.setKbPinyin(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(next ? '拼音：打全拼后选字' : '字母：首字母/全拼联想'),
      duration: const Duration(seconds: 2),
    ));
    _scheduleSuggest();
    setState(() {});
  }

  Future<void> _search([String? forced]) async {
    if (pyBuf.isNotEmpty) {
      setState(() {
        query = typedQuery;
        pyBuf = '';
      });
    }
    final raw = (forced ?? query).trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入片名')));
      return;
    }
    final store = context.read<SettingsStore>();
    final vod = VodService(store);
    final sources = store.enabledSources;
    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可用采集源，请到「设置」中添加')),
      );
      return;
    }

    final gen = ++searchGen;
    final pending = sources
        .map((c) => (
              code: c,
              name: store.resolveSource(c)?.name ?? c,
            ))
        .toList();

    // 立刻进结果页，再按源增量填充
    setState(() {
      loading = false;
      query = raw;
      queryCommitted = true;
      rawResults = [];
      pendingSources = pending;
      resultsSearching = true;
      showResultsPage = true;
    });

    try {
      final built = await SuggestService.buildSearchQueries(raw);
      if (!mounted || gen != searchGen) return;
      if (!SuggestService.hasCjk(raw)) {
        final titles = await SuggestService.resolveTitles(raw);
        if (mounted && gen == searchGen) setState(() => suggests = titles);
      }

      final queries = <String>[
        ...built.primary,
        ...built.fallback.where((q) => !built.primary.contains(q)),
      ];
      if (queries.isEmpty) queries.add(raw);

      var anyHit = false;
      for (var qi = 0; qi < queries.length; qi++) {
        if (!mounted || gen != searchGen) return;
        if (anyHit) break;
        final q = queries[qi];
        // 换词重试时清空；同一词下各源并行，谁先回谁先上屏
        setState(() {
          pendingSources = sources
              .map((c) => (
                    code: c,
                    name: store.resolveSource(c)?.name ?? c,
                  ))
              .toList();
          if (qi > 0) rawResults = [];
        });
        final hits = await Future.wait(sources.map((src) async {
          final list = await vod.searchSource(src, q);
          if (!mounted || gen != searchGen) return <VodItem>[];
          final filtered = vod.applyYellowFilter(list);
          if (!mounted || gen != searchGen) return filtered;
          setState(() {
            pendingSources =
                pendingSources.where((p) => p.code != src).toList();
            if (filtered.isNotEmpty) {
              rawResults = [...rawResults, ...filtered];
            }
          });
          return filtered;
        }));
        anyHit = hits.any((e) => e.isNotEmpty);
      }

      try {
        await store.pushSearchHistory(
          SuggestService.hasCjk(raw)
              ? raw
              : (built.primary.isNotEmpty ? built.primary.first : raw),
        );
      } catch (_) {}
    } catch (e) {
      if (mounted && gen == searchGen) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted && gen == searchGen) {
        setState(() {
          resultsSearching = false;
          pendingSources = [];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (showResultsPage) {
      return SearchResultsScreen(
        query: query,
        rawResults: rawResults,
        pendingSources: pendingSources,
        searching: resultsSearching,
        onOpen: widget.onOpen,
        onBack: _closeResults,
      );
    }

    final store = context.watch<SettingsStore>();
    final pySeg =
        store.kbPinyin && pyBuf.isNotEmpty ? PinyinDict.segment(pyBuf) : null;
    final pyChars = pySeg?.chars ?? const <String>[];
    final pyPages =
        pyChars.isEmpty ? 1 : ((pyChars.length + pyPageSize - 1) ~/ pyPageSize);
    final safePyPage = pyPage.clamp(0, pyPages - 1);
    final pageChars = pyChars.isEmpty
        ? const <String>[]
        : pyChars.skip(safePyPage * pyPageSize).take(pyPageSize).toList();

    final history = store.searchHistory;
    final showSuggest = suggests.isNotEmpty && !queryCommitted;

    return Stack(
      children: [
        // 用几何阅读序：右出键盘进快捷入口，下出字母进删除/搜索，上进顶栏按钮
        FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              // 方向键留给焦点遍历，不要当输入吞掉
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.arrowUp ||
                  key == LogicalKeyboardKey.arrowDown ||
                  key == LogicalKeyboardKey.arrowLeft ||
                  key == LogicalKeyboardKey.arrowRight ||
                  key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.numpadEnter ||
                  key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.escape) {
                return KeyEventResult.ignored;
              }
              final k = event.character;
              if (k != null &&
                  k.length == 1 &&
                  RegExp(r'[a-zA-Z0-9\u4e00-\u9fff]').hasMatch(k)) {
                _append(k);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.backspace) {
                _backspace();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SearchBar(
                    text: displayQuery,
                    pyMode: store.kbPinyin,
                    searchFocus: _searchBtnFocus,
                    onClear: _clear,
                    onSearch: () => _search(),
                    onToggleMode: _toggleMode,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 380,
                          child: _KeyboardPad(
                            keys: keys,
                            pyMode: store.kbPinyin,
                            pyChars: pageChars,
                            pyPage: safePyPage,
                            pyPages: pyPages,
                            autofocusFirst: true,
                            deleteFocus: _deleteFocus,
                            exitRightFocus: _sideFirstFocus,
                            onAppend: _append,
                            onBackspace: _backspace,
                            onSearch: () => _search(),
                            onPickPinyin: (ch) =>
                                _pickPinyin(ch, pySeg?.eat ?? pyBuf.length),
                            onPyPrev: () => setState(() =>
                                pyPage = (safePyPage - 1).clamp(0, pyPages - 1)),
                            onPyNext: () => setState(() =>
                                pyPage = (safePyPage + 1).clamp(0, pyPages - 1)),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _SearchSidePanel(
                            history: history,
                            suggests: showSuggest ? suggests : const [],
                            emptySources: store.enabledSources.isEmpty,
                            firstFocus: _sideFirstFocus,
                            onPickHistory: _search,
                            onPickSuggest: (t) {
                              setState(() {
                                query = t;
                                pyBuf = '';
                              });
                              _search(t);
                            },
                            onClearHistory: () async {
                              try {
                                await store.clearSearchHistory();
                              } catch (_) {}
                            },
                            onGoSettings: store.enabledSources.isEmpty
                                ? () => ShellScreen.of(context)
                                    ?.go(AppTab.settings)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (loading)
          const ModalBarrier(dismissible: false, color: Color(0x66000000)),
        if (loading)
          AbsorbPointer(
            child: LoadingOverlay(
              message: SuggestService.hasCjk(query) ? '全源搜索中…' : '正在联想片名…',
            ),
          ),
      ],
    );
  }
}

// ─── 顶栏搜词 ─────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.text,
    required this.pyMode,
    required this.searchFocus,
    required this.onClear,
    required this.onSearch,
    required this.onToggleMode,
  });

  final String text;
  final bool pyMode;
  final FocusNode searchFocus;
  final VoidCallback onClear;
  final VoidCallback onSearch;
  final VoidCallback onToggleMode;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF121A2B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                const Icon(Icons.search, color: AppTheme.neon, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text.isEmpty ? '输入片名搜索…' : text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: text.isEmpty ? AppTheme.textDim : Colors.white,
                    ),
                  ),
                ),
                Text(
                  pyMode ? '拼音' : '字母',
                  style: const TextStyle(
                    color: AppTheme.textDim,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        _BarBtn(label: '清空', onTap: onClear),
        const SizedBox(width: 8),
        _BarBtn(label: pyMode ? '字母' : '拼音', onTap: onToggleMode),
        const SizedBox(width: 8),
        Focusable(
          focusNode: searchFocus,
          scale: 1.04,
          borderRadius: 10,
          glass: false,
          onTap: onSearch,
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              '搜索',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }
}

class _BarBtn extends StatelessWidget {
  const _BarBtn({
    required this.label,
    required this.onTap,
  });
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      scale: 1.04,
      borderRadius: 10,
      glass: false,
      onTap: onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

// ─── 紧凑键盘 ─────────────────────────────────────────────

class _KeyboardPad extends StatelessWidget {
  const _KeyboardPad({
    required this.keys,
    required this.pyMode,
    required this.pyChars,
    required this.pyPage,
    required this.pyPages,
    required this.autofocusFirst,
    required this.deleteFocus,
    required this.exitRightFocus,
    required this.onAppend,
    required this.onBackspace,
    required this.onSearch,
    required this.onPickPinyin,
    required this.onPyPrev,
    required this.onPyNext,
  });

  final List<String> keys;
  final bool pyMode;
  final List<String> pyChars;
  final int pyPage;
  final int pyPages;
  final bool autofocusFirst;
  final FocusNode deleteFocus;
  final FocusNode exitRightFocus;
  final ValueChanged<String> onAppend;
  final VoidCallback onBackspace;
  final VoidCallback onSearch;
  final ValueChanged<String> onPickPinyin;
  final VoidCallback onPyPrev;
  final VoidCallback onPyNext;

  static const cols = 6;

  KeyEventResult _edgeKey(
    KeyEvent event, {
    bool exitRight = false,
    bool exitDown = false,
  }) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (exitRight && event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (exitRightFocus.canRequestFocus) {
        exitRightFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    if (exitDown && event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (deleteFocus.canRequestFocus) {
        deleteFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final lastRowStart = keys.length - (keys.length % cols == 0 ? cols : keys.length % cols);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.panel.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          if (pyMode && pyChars.isNotEmpty) ...[
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  if (pyPages > 1)
                    Focusable(
                      scale: 1.05,
                      borderRadius: 8,
                      glass: false,
                      onTap: onPyPrev,
                      child: const SizedBox(
                        width: 36,
                        child: Center(child: Icon(Icons.chevron_left, size: 22)),
                      ),
                    ),
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var ci = 0; ci < pyChars.length; ci++)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Focus(
                              canRequestFocus: false,
                              skipTraversal: true,
                              onKeyEvent: (n, e) => _edgeKey(e,
                                  exitRight: ci == pyChars.length - 1 &&
                                      pyPages <= 1),
                              child: Focusable(
                                scale: 1.08,
                                borderRadius: 8,
                                glass: false,
                                onTap: () => onPickPinyin(pyChars[ci]),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  color: const Color(0xFF1A2740),
                                  child: Text(pyChars[ci],
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800)),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (pyPages > 1)
                    Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: (n, e) => _edgeKey(e, exitRight: true),
                      child: Focusable(
                        scale: 1.05,
                        borderRadius: 8,
                        glass: false,
                        onTap: onPyNext,
                        child: const SizedBox(
                          width: 36,
                          child: Center(
                              child: Icon(Icons.chevron_right, size: 22)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final gap = 6.0;
                final cellW = (c.maxWidth - gap * (cols - 1)) / cols;
                final cellH = (cellW * 0.72).clamp(36.0, 48.0);
                return GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: keys.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisExtent: cellH,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: gap,
                  ),
                  itemBuilder: (_, i) {
                    final k = keys[i];
                    final rightEdge = i % cols == cols - 1;
                    final bottomEdge = i >= lastRowStart;
                    return Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: (n, e) => _edgeKey(
                        e,
                        exitRight: rightEdge,
                        exitDown: bottomEdge,
                      ),
                      child: Focusable(
                        autofocus: autofocusFirst && i == 0,
                        scale: 1.08,
                        borderRadius: 8,
                        glass: false,
                        onTap: () => onAppend(k),
                        child: Container(
                          alignment: Alignment.center,
                          color: const Color(0xFF0E1626),
                          child: Text(
                            k,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _PadAction(
                  label: '删除',
                  focusNode: deleteFocus,
                  onTap: onBackspace,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (n, e) => _edgeKey(e, exitRight: true),
                  child: _PadAction(
                    label: '搜索',
                    accent: true,
                    onTap: onSearch,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PadAction extends StatelessWidget {
  const _PadAction({
    required this.label,
    required this.onTap,
    this.accent = false,
    this.focusNode,
  });
  final String label;
  final VoidCallback onTap;
  final bool accent;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      focusNode: focusNode,
      scale: 1.04,
      borderRadius: 8,
      glass: false,
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        color: accent ? AppTheme.accent : const Color(0xFF0E1626),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }
}

// ─── 键盘右侧：历史 / 联想（别空着）────────────────────────

class _SearchSidePanel extends StatelessWidget {
  const _SearchSidePanel({
    required this.history,
    required this.suggests,
    required this.emptySources,
    required this.onPickHistory,
    required this.onPickSuggest,
    required this.onClearHistory,
    this.firstFocus,
    this.onGoSettings,
  });

  final List<String> history;
  final List<String> suggests;
  final bool emptySources;
  final FocusNode? firstFocus;
  final ValueChanged<String> onPickHistory;
  final ValueChanged<String> onPickSuggest;
  final VoidCallback onClearHistory;
  final VoidCallback? onGoSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.panel.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: emptySources
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('请先添加采集源',
                      style: TextStyle(color: AppTheme.textDim)),
                  if (onGoSettings != null) ...[
                    const SizedBox(height: 14),
                    Focusable(
                      scale: 1.05,
                      borderRadius: 10,
                      glass: false,
                      onTap: onGoSettings,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        color: AppTheme.accent,
                        child: const Text('去设置',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ],
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
              children: [
                const Text(
                  '快捷入口',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '点下面词条直接搜 · 也会进分源结果页',
                  style: TextStyle(color: AppTheme.textDim, fontSize: 13),
                ),
                if (suggests.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('猜你想搜',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.neon,
                          fontSize: 13)),
                  const SizedBox(height: 8),
                  Builder(builder: (_) {
                    final list = suggests.take(12).toList();
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (var si = 0; si < list.length; si++)
                          Focusable(
                            focusNode: si == 0 ? firstFocus : null,
                            scale: 1.04,
                            borderRadius: 10,
                            glass: false,
                            onTap: () => onPickSuggest(list[si]),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: AppTheme.neon.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color:
                                        AppTheme.neon.withValues(alpha: 0.45)),
                              ),
                              child: Text(list[si],
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                            ),
                          ),
                      ],
                    );
                  }),
                ],
                if (history.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('搜索历史',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textDim,
                                fontSize: 13)),
                      ),
                      Focusable(
                        scale: 1.04,
                        borderRadius: 8,
                        glass: false,
                        onTap: onClearHistory,
                        child: const Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Text('清空',
                              style: TextStyle(
                                  color: AppTheme.textDim, fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Builder(builder: (_) {
                    final list = history.take(10).toList();
                    return Column(
                      children: [
                        for (var hi = 0; hi < list.length; hi++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Focusable(
                              focusNode: suggests.isEmpty && hi == 0
                                  ? firstFocus
                                  : null,
                              scale: 1.02,
                              borderRadius: 10,
                              glass: false,
                              onTap: () => onPickHistory(list[hi]),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0E1626),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: Colors.white
                                          .withValues(alpha: 0.06)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.history,
                                        size: 16, color: AppTheme.textDim),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(list[hi],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 15)),
                                    ),
                                    const Icon(Icons.chevron_right,
                                        size: 18, color: AppTheme.textDim),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  }),
                ],
                if (history.isEmpty && suggests.isEmpty) ...[
                  const SizedBox(height: 28),
                  const Text(
                    '左边键盘输入片名，按「搜索」\n右侧这里会放历史和联想',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppTheme.textDim, height: 1.55, fontSize: 14),
                  ),
                ],
              ],
            ),
    );
  }
}
