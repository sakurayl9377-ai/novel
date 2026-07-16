import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Subtle deterministic paper grain for light reading themes.
///
/// The painter is static and isolated behind a repaint boundary, so it adds no
/// work while pages scroll or animate.
class NovelReaderBackdrop extends StatelessWidget {
  const NovelReaderBackdrop({
    super.key,
    required this.color,
    required this.child,
  });

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(painter: _PaperBackdropPainter(color), child: child),
    );
  }
}

class _PaperBackdropPainter extends CustomPainter {
  const _PaperBackdropPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final isLight = color.computeLuminance() > 0.42;
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isLight
          ? [
              Color.lerp(color, Colors.white, 0.08)!,
              color,
              Color.lerp(color, const Color(0xFFD6B979), 0.05)!,
            ]
          : [color, Color.lerp(color, Colors.black, 0.08)!],
      stops: isLight ? const [0, 0.55, 1] : const [0, 1],
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = gradient.createShader(Offset.zero & size),
    );
    if (!isLight || size.isEmpty) return;

    final random = math.Random(9377);
    final fleckPaint = Paint()
      ..color = const Color(0xFF8B6A31).withValues(alpha: 0.025);
    final lightPaint = Paint()..color = Colors.white.withValues(alpha: 0.045);
    final count = ((size.width * size.height) / 9000).clamp(80, 260).round();
    for (var index = 0; index < count; index++) {
      final point = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final radius = 0.25 + random.nextDouble() * 0.85;
      canvas.drawCircle(
        point,
        radius,
        random.nextBool() ? fleckPaint : lightPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PaperBackdropPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
