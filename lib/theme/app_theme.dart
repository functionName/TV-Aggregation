import 'package:flutter/material.dart';

/// Web3 科技风：深空底 + 冰蓝主强调 + 玻璃拟态（电视/Web 共用）
/// LOGO 可用独立红色，界面交互色统一冰蓝，避免红绿撞车。
class AppTheme {
  static const bg = Color(0xFF060B16);
  static const bgElevated = Color(0xFF0C1424);
  static const panel = Color(0xCC121C30);
  static const glass = Color(0x331A2A44);
  static const text = Color(0xFFF2F7FF);
  static const textDim = Color(0xFF8FA3C4);
  /// 主操作（播放按钮等）
  static const accent = Color(0xFF3B82F6);
  /// 焦点环 / 高亮冰蓝
  static const neon = Color(0xFF5CC8FF);
  /// 辅色电蓝
  static const neon2 = Color(0xFF2563EB);
  static const gold = Color(0xFFFFC857);
  static const focusRing = Color(0xFF5CC8FF);
  static const danger = Color(0xFFFF5C7A);

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: neon,
        secondary: neon2,
        surface: bgElevated,
        error: danger,
        onPrimary: Color(0xFF041018),
        onSurface: text,
      ),
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: text,
      ),
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      dialogTheme: DialogThemeData(
        backgroundColor: bgElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: neon.withValues(alpha: 0.25)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: bgElevated,
        contentTextStyle: const TextStyle(color: text),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: neon.withValues(alpha: 0.35)),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: neon),
    );
  }

  static BoxDecoration meshBackground() => const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF060B16),
            Color(0xFF0A162C),
            Color(0xFF0B1830),
            Color(0xFF060B16),
          ],
          stops: [0, 0.35, 0.7, 1],
        ),
      );

  static BoxDecoration glassCard({
    double radius = 16,
    bool focused = false,
  }) =>
      BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: focused ? const Color(0x55203658) : glass,
        border: Border.all(
          color: focused
              ? neon.withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.12),
          width: focused ? 2 : 1,
        ),
        boxShadow: [
          if (focused)
            BoxShadow(
              color: neon.withValues(alpha: 0.28),
              blurRadius: 22,
              spreadRadius: 1,
            ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: focused ? 0.14 : 0.08),
            Colors.white.withValues(alpha: 0.02),
          ],
        ),
      );
}

class MeshBackdrop extends StatelessWidget {
  const MeshBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppTheme.meshBackground(),
      child: child,
    );
  }
}

class GlassBar extends StatelessWidget {
  const GlassBar({super.key, required this.child, this.height = 72});
  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: BoxDecoration(
        color: const Color(0xEE0C1422),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: child,
    );
  }
}
