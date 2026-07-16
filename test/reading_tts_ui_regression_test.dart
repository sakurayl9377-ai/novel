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

  test('voice engine settings live in the reading control panel', () {
    final reader = File('lib/screens/reading_screen.dart').readAsStringSync();
    final settings = File(
      'lib/widgets/reading_settings_panel.dart',
    ).readAsStringSync();

    expect(reader, contains('_buildTtsEngineControls'));
    expect(reader, contains("Text('朗读引擎'"));
    expect(reader, contains("label: Text('系统 TTS')"));
    expect(reader, contains("label: Text('科大讯飞')"));
    expect(settings, isNot(contains("_SectionTitle('朗读引擎'")));
    expect(settings, isNot(contains("_SectionTitle('发音人'")));
  });
}
