import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 自绘品牌标（不依赖 Flutter 默认图标），电视/Web 同一套。
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _MarkPainter()),
    );
  }
}

class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.height = 28, this.showText = true});
  final double height;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(size: height),
        if (showText) ...[
          SizedBox(width: height * 0.35),
          Text(
            '影视聚合',
            style: TextStyle(
              color: AppTheme.accent,
              fontWeight: FontWeight.w900,
              fontSize: height * 0.82,
              letterSpacing: 0.6,
              height: 1,
            ),
          ),
        ],
      ],
    );
  }
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width * 0.22;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(r),
    );
    canvas.drawRRect(rect, Paint()..color = AppTheme.accent);

    // 左侧胶片齿孔
    final hole = Paint()..color = const Color(0xFF141414);
    final holeW = size.width * 0.08;
    final holeH = size.height * 0.1;
    for (var i = 0; i < 4; i++) {
      final y = size.height * (0.14 + i * 0.2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * 0.1, y, holeW, holeH),
          const Radius.circular(2),
        ),
        hole,
      );
    }

    // 播放三角
    final path = Path()
      ..moveTo(size.width * 0.42, size.height * 0.28)
      ..lineTo(size.width * 0.42, size.height * 0.72)
      ..lineTo(size.width * 0.78, size.height * 0.5)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
