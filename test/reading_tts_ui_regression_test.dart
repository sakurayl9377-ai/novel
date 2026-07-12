import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starting TTS does not show notification or lock-screen guidance', () {
    final source = File('lib/screens/reading_screen.dart').readAsStringSync();

    expect(source, isNot(contains('prepareNotificationAccess()')));
    expect(source, isNot(contains('openNotificationSettings(')));
    expect(source, isNot(contains('锁屏通知')));
    expect(source, isNot(contains('去设置')));

    // The prompt is removed without disabling the media-session card itself.
    expect(source, contains('_showTtsMediaControls(playing: true)'));
    expect(source, contains('mediaControlService.stop()'));
  });
}
