import 'package:flutter/material.dart';

class AppTokens {
  const AppTokens._();

  static const Color brand = Color(0xFF1677FF);
  static const Color brandDark = Color(0xFF0F4FC7);
  static const Color brandSoft = Color(0xFFE8F1FF);
  static const Color reward = Color(0xFFFFA51F);
  static const Color rewardSoft = Color(0xFFFFF2D8);
  static const Color success = Color(0xFF27B884);
  static const Color danger = Color(0xFFFF5A66);

  static const Color ink = Color(0xFF172033);
  static const Color inkMuted = Color(0xFF66748A);
  static const Color inkSubtle = Color(0xFF9AA6B8);
  static const Color line = Color(0xFFE7EDF5);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color canvas = Color(0xFFF4F7FB);
  static const Color darkCanvas = Color(0xFF0E1117);
  static const Color darkSurface = Color(0xFF171B24);
  static const Color darkLine = Color(0xFF2B3240);
  static const Color darkText = Color(0xFFE8ECF4);
  static const Color darkMuted = Color(0xFF9AA6B8);

  static const double radiusXs = 6;
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;

  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 20;
  static const double space2xl = 24;

  static const List<BoxShadow> softShadow = [
    BoxShadow(color: Color(0x0F172033), blurRadius: 18, offset: Offset(0, 8)),
  ];

  static Color cardColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkSurface
        : surface;
  }

  static Color canvasColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkCanvas
        : canvas;
  }

  static Color borderColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? darkLine : line;
  }

  static Color primaryText(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? darkText : ink;
  }

  static Color secondaryText(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkMuted
        : inkMuted;
  }
}
