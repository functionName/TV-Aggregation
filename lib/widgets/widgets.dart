import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'app_network_image.dart';

export 'app_network_image.dart';
export 'brand_logo.dart';

class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.child,
    this.onTap,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
    this.scale = 1.08,
    this.borderRadius = 14,
    this.glass = true,
    this.scaleAlignment = Alignment.center,
    /// 选中态也放大（首页与 Billboard 同步时，不一定有焦点高亮）
    this.emphasized = false,
    /// false：不画外扩光晕、不放大（弹窗列表等会被父级裁切的场景）
    this.glow = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;
  final double scale;
  final double borderRadius;
  final bool glass;
  final Alignment scaleAlignment;
  final bool emphasized;
  final bool glow;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  bool _focused = false;
  bool _hovered = false;

  bool get _active => _focused || _hovered || widget.emphasized;

  void _setActive({bool? focused, bool? hovered}) {
    final nextFocus = focused ?? _focused;
    final nextHover = hovered ?? _hovered;
    final was = _focused || _hovered || widget.emphasized;
    setState(() {
      _focused = nextFocus;
      _hovered = nextHover;
    });
    final now = nextFocus || nextHover || widget.emphasized;
    if (was != now) widget.onFocusChange?.call(now);
    // 遥控焦点滚进可视区，避免设置页等长列表里“点不到”
    if (nextFocus && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_focused) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.35,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) => _setActive(focused: v),
      onShowHoverHighlight: (v) => _setActive(hovered: v),
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
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
        child: AnimatedScale(
          scale: (active && widget.glow) ? widget.scale : 1,
          alignment: widget.scaleAlignment,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          filterQuality: FilterQuality.medium,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: widget.glass
                ? AppTheme.glassCard(
                    radius: widget.borderRadius,
                    focused: active,
                  )
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                    border: Border.all(
                      color: active
                          ? AppTheme.neon
                          : Colors.white.withValues(alpha: 0.08),
                      width: active ? (widget.glow ? 3 : 2) : 1,
                    ),
                    boxShadow: (active && widget.glow)
                        ? [
                            BoxShadow(
                              color: AppTheme.neon.withValues(alpha: 0.3),
                              blurRadius: 14,
                            ),
                          ]
                        : null,
                  ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius - 1),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 单行文案是否会在 [maxWidth] 内被截断（给 Material Tooltip 决策用）
bool textExceedsWidth(String text, TextStyle style, double maxWidth) {
  if (maxWidth <= 0 || !maxWidth.isFinite) return false;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
  return tp.didExceedMaxLines;
}

class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    required this.cover,
    this.rate,
    this.onTap,
    this.width = 120,
    this.autofocus = false,
    this.focusNode,
    this.selected = false,
    this.onFocus,
  });

  final String title;
  final String cover;
  final String? rate;
  final VoidCallback? onTap;
  final double width;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool selected;
  final VoidCallback? onFocus;

  /// 横排：上方留放大余量 + 海报 + 下方片名（片名不参与缩放）
  static double rowHeight(double tileW) => tileW * 0.14 + tileW * 1.5 + 58;

  static String displayRate(String? rate) {
    final t = (rate ?? '').trim();
    if (t.isEmpty || t == 'null') return '—';
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final rateText = displayRate(rate);
    // 网格里常传 infinity；必须先拿到有限宽度，否则 memCacheWidth.round() 会抛 Infinity
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = width.isFinite && width > 0
            ? width
            : (constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : 120.0);
        final cacheW = (w * 2).round().clamp(160, 480);
        return SizedBox(
          width: width.isFinite ? width : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: w * 0.08),
                child: Focusable(
                  autofocus: autofocus,
                  focusNode: focusNode,
                  emphasized: selected,
                  onTap: onTap,
                  onFocusChange: (f) {
                    if (f) onFocus?.call();
                  },
                  scale: 1.06,
                  scaleAlignment: Alignment.center,
                  borderRadius: 8,
                  glass: false,
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: Stack(
                      fit: StackFit.expand,
                      clipBehavior: Clip.hardEdge,
                      children: [
                        AppNetworkImage(url: cover, memCacheWidth: cacheW),
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              color: const Color(0xF2000000),
                            ),
                            child: Text(
                              '★ $rateText',
                              style: TextStyle(
                                color: rateText == '—'
                                    ? AppTheme.textDim
                                    : AppTheme.gold,
                                fontSize: (w * 0.085).clamp(12.0, 15.0),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                title.isEmpty ? '未知影片' : title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: (w * 0.095).clamp(13.0, 16.0),
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                  color: selected ? AppTheme.neon : AppTheme.text,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({super.key, this.message = '加载中…'});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xE6070B14),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        decoration: AppTheme.glassCard(radius: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 42,
              height: 42,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 18),
            Text(message, style: const TextStyle(color: AppTheme.textDim)),
          ],
        ),
      ),
    );
  }
}

class TvChip extends StatelessWidget {
  const TvChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.autofocus = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 8),
      child: Focusable(
        autofocus: autofocus,
        scale: 1.05,
        borderRadius: 999,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: selected
              ? AppTheme.neon.withValues(alpha: 0.22)
              : Colors.transparent,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: selected ? AppTheme.neon : AppTheme.textDim,
            ),
          ),
        ),
      ),
    );
  }
}
