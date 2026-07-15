import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readNormalized(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  test('Android fullscreen can draw through display cutouts', () {
    final activity = _readNormalized(
      'android/app/src/main/kotlin/com/novel/novel_app/MainActivity.kt',
    );
    final lightTheme = _readNormalized(
      'android/app/src/main/res/values/styles.xml',
    );
    final darkTheme = _readNormalized(
      'android/app/src/main/res/values-night/styles.xml',
    );

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

  test('video stays complete while controls fill the physical viewport', () {
    final player = _readNormalized(
      'lib/screens/anime_player_screen.dart',
    );

    expect(player, contains('fit: BoxFit.contain'));
    expect(player, contains('Positioned.fill(child: controlsBuilder())'));
    expect(
      player,
      isNot(contains('SafeArea(bottom: false, child: controlsBuilder())')),
    );
  });

  test('inline player restores a clear standalone black title app bar', () {
    final player = _readNormalized(
      'lib/screens/anime_player_screen.dart',
    );

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
