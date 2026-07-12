import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android fullscreen can draw through display cutouts', () {
    final activity = File(
      'android/app/src/main/kotlin/com/novel/novel_app/MainActivity.kt',
    ).readAsStringSync();
    final lightTheme = File(
      'android/app/src/main/res/values/styles.xml',
    ).readAsStringSync();
    final darkTheme = File(
      'android/app/src/main/res/values-night/styles.xml',
    ).readAsStringSync();

    expect(activity, contains('LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES'));
    expect(activity, contains('LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS'));
    expect(
      activity,
      contains('WindowCompat.setDecorFitsSystemWindows(window, false)'),
    );
    expect(
      activity,
      contains('window.isNavigationBarContrastEnforced = false'),
    );
    expect(
      activity,
      contains('controller.hide(WindowInsetsCompat.Type.systemBars())'),
    );
    expect(activity, contains('FLAG_LAYOUT_NO_LIMITS'));
    expect(activity, contains('View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY'));
    expect(activity, contains('View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN'));
    expect(activity, contains('View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION'));
    expect(lightTheme, contains('windowLayoutInDisplayCutoutMode'));
    expect(lightTheme, contains('shortEdges'));
    expect(darkTheme, contains('windowLayoutInDisplayCutoutMode'));
    expect(darkTheme, contains('shortEdges'));
  });

  test('video and the control overlay fill the physical viewport', () {
    final player = File(
      'lib/screens/anime_player_screen.dart',
    ).readAsStringSync();

    expect(player, contains('fit: BoxFit.cover'));
    expect(player, contains('Positioned.fill(child: controlsBuilder())'));
    expect(
      player,
      isNot(contains('SafeArea(bottom: false, child: controlsBuilder())')),
    );
  });

  test('inline player restores a clear standalone black title app bar', () {
    final player = File(
      'lib/screens/anime_player_screen.dart',
    ).readAsStringSync();

    expect(
      player,
      contains("title: Text(\n            '\${widget.anime.title}"),
    );
    expect(player, contains('backgroundColor: Colors.black'));
    expect(player, contains('foregroundColor: Colors.white'));
    expect(player, contains('color: Colors.white'));
    expect(player, contains('fontWeight: FontWeight.w600'));
    expect(player, contains("tooltip: '弹幕设置'"));
    expect(player, isNot(contains('Positioned(\n            left: 6,')));
  });
}
