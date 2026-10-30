import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_logo.dart';
import '../widgets/widgets.dart';
import 'detail_screen.dart';
import 'discover_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

enum AppTab { home, discover, search, history, settings }

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => ShellScreenState();

  static ShellScreenState? of(BuildContext context) =>
      context.findAncestorStateOfType<ShellScreenState>();
}

class ShellScreenState extends State<ShellScreen> {
  AppTab tab = AppTab.home;
  String? detailTitle;
  String? detailCover;
  int? resumeEpisode;
  int? resumePositionMs;
  String? preferSource;
  String? seedVodId;
  String? seedSourceName;
  String? seedApiUrl;
  String? seedRemarks;
  String? seedPlayFrom;
  String? seedPlayUrl;
  String? seedDesc;
  String? seedYear;
  String? seedArea;
  String? seedTypeName;

  DateTime? _exitArmed;

  /// 子页（如搜索结果）优先消费返回键；返回 true 表示已处理
  bool Function()? _tabConsumeBack;

  void registerTabBack(bool Function()? fn) => _tabConsumeBack = fn;

  void go(AppTab t) => setState(() {
        tab = t;
        detailTitle = null;
        _tabConsumeBack = null;
      });

  void openDetail(
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
  }) {
    setState(() {
      detailTitle = title;
      detailCover = cover;
      resumeEpisode = resume;
      resumePositionMs = resumePosition;
      preferSource = source;
      seedVodId = vodId;
      seedSourceName = sourceName;
      seedApiUrl = apiUrl;
      seedRemarks = remarks;
      seedPlayFrom = playFrom;
      seedPlayUrl = playUrl;
      seedDesc = desc;
      seedYear = year;
      seedArea = area;
      seedTypeName = typeName;
    });
  }

  void closeDetail() => setState(() {
        detailTitle = null;
        seedVodId = null;
        seedSourceName = null;
        seedApiUrl = null;
        seedRemarks = null;
        seedPlayFrom = null;
        seedPlayUrl = null;
        seedDesc = null;
        seedYear = null;
        seedArea = null;
        seedTypeName = null;
        preferSource = null;
        resumeEpisode = null;
        resumePositionMs = null;
      });

  /// 遥控/键盘 Esc：详情 → 子页返回 → 回首页 → 再按退出
  bool handleRemoteBack() {
    if (detailTitle != null) {
      closeDetail();
      return true;
    }
    if (_tabConsumeBack?.call() == true) return true;
    if (tab != AppTab.home) {
      go(AppTab.home);
      return true;
    }
    final now = DateTime.now();
    if (_exitArmed != null &&
        now.difference(_exitArmed!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return true;
    }
    _exitArmed = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('再按一次返回退出'),
        duration: Duration(seconds: 2),
      ),
    );
    return true;
  }

  KeyEventResult onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isBack = event.logicalKey == LogicalKeyboardKey.goBack ||
        event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.browserBack;
    if (!isBack) return KeyEventResult.ignored;
    handleRemoteBack();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        handleRemoteBack();
      },
      child: Focus(
        // 不抢子页面焦点：只负责兜底返回键
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: onKey,
        child: Scaffold(
          backgroundColor: AppTheme.bg,
          body: MeshBackdrop(
            child: Column(
              children: [
                // 裁切顶栏焦点放大，避免盖住下方内容
                ClipRect(
                  child: _TopBar(
                    tab: tab,
                    onSelect: go,
                    compact: !wide,
                  ),
                ),
                Expanded(
                  // 详情盖在 Tab 上，不销毁搜索结果页（返回仍在分源列表）
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Offstage(
                        offstage: detailTitle != null,
                        child: TickerMode(
                          enabled: detailTitle == null,
                          child: switch (tab) {
                            AppTab.home => HomeScreen(onOpen: openDetail),
                            AppTab.discover =>
                              DiscoverScreen(onOpen: openDetail),
                            AppTab.search => SearchScreen(onOpen: openDetail),
                            AppTab.history =>
                              HistoryScreen(onOpen: openDetail),
                            AppTab.settings => const SettingsScreen(),
                          },
                        ),
                      ),
                      if (detailTitle != null)
                        DetailScreen(
                          title: detailTitle!,
                          cover: detailCover,
                          resumeEpisode: resumeEpisode,
                          resumePositionMs: resumePositionMs,
                          preferSource: preferSource,
                          seedVodId: seedVodId,
                          seedSourceName: seedSourceName,
                          seedApiUrl: seedApiUrl,
                          seedRemarks: seedRemarks,
                          seedPlayFrom: seedPlayFrom,
                          seedPlayUrl: seedPlayUrl,
                          seedDesc: seedDesc,
                          seedYear: seedYear,
                          seedArea: seedArea,
                          seedTypeName: seedTypeName,
                          onBack: closeDetail,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.tab,
    required this.onSelect,
    required this.compact,
  });

  final AppTab tab;
  final ValueChanged<AppTab> onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final items = <(AppTab, String, IconData?)>[
      (AppTab.home, '首页', null),
      (AppTab.discover, '发现', null),
      (AppTab.search, '搜索', Icons.search),
      (AppTab.history, '历史', Icons.history),
      (AppTab.settings, '设置', Icons.settings),
    ];
    return GlassBar(
      height: compact ? 58 : 72,
      child: Row(
        children: [
          BrandLogo(height: compact ? 26 : 30),
          SizedBox(width: compact ? 12 : 28),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (t, label, icon) in items)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _NavButton(
                        label: label,
                        icon: icon,
                        active: tab == t,
                        onTap: () => onSelect(t),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Consumer<SettingsStore>(
            builder: (_, s, _) => Text(
              _clock(),
              style: const TextStyle(
                color: AppTheme.textDim,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _clock() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }
}

class _NavButton extends StatefulWidget {
  const _NavButton({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.active || focused;
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: focused
                ? AppTheme.neon.withValues(alpha: 0.2)
                : widget.active
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.transparent,
            border: Border.all(
              color: focused
                  ? AppTheme.neon
                  : widget.active
                      ? Colors.white.withValues(alpha: 0.18)
                      : Colors.transparent,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppTheme.neon.withValues(alpha: 0.25),
                      blurRadius: 14,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 18,
                  color: focused
                      ? AppTheme.neon
                      : widget.active
                          ? Colors.white
                          : AppTheme.textDim,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: focused
                      ? AppTheme.neon
                      : widget.active
                          ? Colors.white
                          : AppTheme.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
