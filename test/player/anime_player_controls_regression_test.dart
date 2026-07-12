import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps transport controls in the bottom bar only', () {
    final controls = File(
      'lib/screens/anime_player_controls.part.dart',
    ).readAsStringSync();

    expect(controls, isNot(contains('Icons.replay_30_rounded')));
    expect(controls, isNot(contains('Icons.forward_30_rounded')));
    expect(controls, isNot(contains('Icons.pause_circle_filled_rounded')));
    expect(controls, contains('_CompactDanmakuInputButton('));
    expect(controls, contains('Icons.pause_rounded'));
    expect(controls, contains('Icons.skip_next_rounded'));
    expect(controls, contains('Icons.subtitles_rounded'));
    expect(controls, contains('Icons.fullscreen_rounded'));
  });

  test('does not reuse one controls GlobalKey across fullscreen routes', () {
    final screen = File(
      'lib/screens/anime_player_screen.dart',
    ).readAsStringSync();
    final controls = File(
      'lib/screens/anime_player_controls.part.dart',
    ).readAsStringSync();

    expect(screen, isNot(contains('_videoControlsKey')));
    expect(controls, contains('_handleChewieChanged'));
    expect(controls, contains('setState(() => _controlsVisible = true)'));
  });

  test('does not render a second danmaku dock below the compact player', () {
    final screen = File(
      'lib/screens/anime_player_screen.dart',
    ).readAsStringSync();
    final contentWidgets = File(
      'lib/screens/anime_player_content_widgets.part.dart',
    ).readAsStringSync();

    expect(screen, isNot(contains('_DanmakuQuickDock(')));
    expect(contentWidgets, isNot(contains('class _DanmakuQuickDock')));
  });
}
