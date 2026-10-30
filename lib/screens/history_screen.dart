import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import 'shell_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.onOpen});
  final void Function(
    String title, {
    String? cover,
    int? resume,
    int? resumePosition,
    String? source,
    String? vodId,
    String? sourceName,
    String? apiUrl,
    String? remarks,
  }) onOpen;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  /// false=观看历史，true=我的收藏
  bool showFavorites = false;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final history = store.viewingHistory;
    final favs = store.favorites;
    final listEmpty = showFavorites ? favs.isEmpty : history.isEmpty;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
          child: Row(
            children: [
              TvChip(
                label: '观看历史',
                selected: !showFavorites,
                onTap: () => setState(() => showFavorites = false),
              ),
              const SizedBox(width: 8),
              TvChip(
                label: '我的收藏',
                selected: showFavorites,
                onTap: () => setState(() => showFavorites = true),
              ),
              const Spacer(),
              if (!listEmpty)
                TvChip(
                  label: showFavorites ? '清空收藏' : '清空历史',
                  onTap: () => showFavorites
                      ? store.clearFavorites()
                      : store.clearHistory(),
                ),
            ],
          ),
        ),
        Expanded(
          child: listEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        showFavorites ? '暂无收藏' : '暂无观看历史',
                        style: const TextStyle(
                            color: AppTheme.textDim, fontSize: 16),
                      ),
                      const SizedBox(height: 18),
                      Focusable(
                        autofocus: true,
                        scale: 1.05,
                        borderRadius: 10,
                        glass: false,
                        onTap: () =>
                            ShellScreen.of(context)?.go(AppTab.search),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 12),
                          color: AppTheme.accent,
                          child: Text(
                            showFavorites ? '去搜索加收藏' : '去搜索影片',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : _buildGrid(context, store),
        ),
      ],
    );
  }

  Widget _buildGrid(BuildContext context, SettingsStore store) {
    final w = MediaQuery.sizeOf(context).width;
    final cross = w > 1200 ? 8 : w > 800 ? 6 : 4;
    if (showFavorites) {
      final list = store.favorites;
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 40),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cross,
          childAspectRatio: 0.55,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: list.length,
        itemBuilder: (_, i) {
          final f = list[i];
          return PosterCard(
            title: f.title,
            cover: f.cover,
            rate: f.sourceName.isEmpty ? '收藏' : f.sourceName,
            width: double.infinity,
            autofocus: i == 0,
            onTap: () => widget.onOpen(
              f.title,
              cover: f.cover,
              source: f.sourceCode,
              vodId: f.vodId.isEmpty ? null : f.vodId,
              sourceName: f.sourceName.isEmpty ? null : f.sourceName,
              apiUrl: f.apiUrl,
            ),
          );
        },
      );
    }
    final list = store.viewingHistory;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 40),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cross,
        childAspectRatio: 0.55,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final h = list[i];
        return PosterCard(
          title: h.title,
          cover: h.cover,
          rate: h.progressLabel,
          width: double.infinity,
          autofocus: i == 0,
          onTap: () => widget.onOpen(
            h.title,
            cover: h.cover,
            resume: h.episodeIndex,
            resumePosition: h.positionMs > 0 ? h.positionMs : null,
            source: h.sourceCode,
            vodId: h.vodId.isEmpty ? null : h.vodId,
            sourceName: h.sourceName.isEmpty ? null : h.sourceName,
            apiUrl: h.apiUrl,
          ),
        );
      },
    );
  }
}
