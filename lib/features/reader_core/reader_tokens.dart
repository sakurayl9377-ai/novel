import 'package:flutter/material.dart';

/// Reader-specific visual tokens.
///
/// Add this extension to an app theme to customize reader chrome globally.
/// [of] also provides complete light/dark defaults for gradual adoption.
@immutable
class ReaderTokens extends ThemeExtension<ReaderTokens> {
  const ReaderTokens({
    required this.canvas,
    required this.onCanvas,
    required this.chromeSurface,
    required this.onChrome,
    required this.chromeMuted,
    required this.accent,
    required this.divider,
    required this.scrim,
  });

  static const ReaderTokens light = ReaderTokens(
    canvas: Color(0xFFFFF8ED),
    onCanvas: Color(0xFF2D2924),
    chromeSurface: Color(0xEE17191E),
    onChrome: Color(0xFFF7F8FA),
    chromeMuted: Color(0xFFB9BEC8),
    accent: Color(0xFF5C9AFF),
    divider: Color(0x33FFFFFF),
    scrim: Color(0x8A000000),
  );

  static const ReaderTokens dark = ReaderTokens(
    canvas: Color(0xFF121316),
    onCanvas: Color(0xFFC7C9CE),
    chromeSurface: Color(0xF20D0E11),
    onChrome: Color(0xFFF4F5F7),
    chromeMuted: Color(0xFFA8ADB8),
    accent: Color(0xFF78A9FF),
    divider: Color(0x3DFFFFFF),
    scrim: Color(0xA6000000),
  );

  static const Duration chromeTransitionDuration = Duration(milliseconds: 220);
  static const Duration hudTransitionDuration = Duration(milliseconds: 180);
  static const Duration sheetTransitionDuration = Duration(milliseconds: 240);

  static const double topChromeHeight = 56;
  static const double bottomChromeHeight = 60;
  static const double minimumTapTarget = 48;
  static const double sheetRadius = 20;
  static const double hudRadius = 10;

  static ReaderTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ReaderTokens>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  final Color canvas;
  final Color onCanvas;
  final Color chromeSurface;
  final Color onChrome;
  final Color chromeMuted;
  final Color accent;
  final Color divider;
  final Color scrim;

  @override
  ReaderTokens copyWith({
    Color? canvas,
    Color? onCanvas,
    Color? chromeSurface,
    Color? onChrome,
    Color? chromeMuted,
    Color? accent,
    Color? divider,
    Color? scrim,
  }) {
    return ReaderTokens(
      canvas: canvas ?? this.canvas,
      onCanvas: onCanvas ?? this.onCanvas,
      chromeSurface: chromeSurface ?? this.chromeSurface,
      onChrome: onChrome ?? this.onChrome,
      chromeMuted: chromeMuted ?? this.chromeMuted,
      accent: accent ?? this.accent,
      divider: divider ?? this.divider,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  ReaderTokens lerp(covariant ReaderTokens? other, double t) {
    if (other == null) return this;
    return ReaderTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      onCanvas: Color.lerp(onCanvas, other.onCanvas, t)!,
      chromeSurface: Color.lerp(chromeSurface, other.chromeSurface, t)!,
      onChrome: Color.lerp(onChrome, other.onChrome, t)!,
      chromeMuted: Color.lerp(chromeMuted, other.chromeMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }
}
