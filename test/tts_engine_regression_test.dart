import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/tts_settings.dart';

void main() {
  test('iflytek selection never silently falls back to system TTS', () {
    final source = File('lib/services/tts_service.dart').readAsStringSync();

    expect(source, contains('if (settings.useIflytek)'));
    expect(source, contains('if (!settings.hasIflytekCredentials)'));
    expect(source, contains('return _speakIflytekChunk(token);'));
    expect(
      source,
      isNot(
        contains(
          'settings.useIflytek && settings.hasIflytekCredentials\n'
          '          ? await _speakIflytekChunk(token)\n'
          '          : await _speakSystemChunk(token)',
        ),
      ),
    );
  });

  test('Android system TTS pause stops the native utterance', () {
    final source = File('lib/services/tts_service.dart').readAsStringSync();

    expect(source, contains('if (Platform.isAndroid)'));
    expect(source, contains('await _flutterTts.stop().timeout('));
    expect(source, contains('_isPaused = true;'));
  });

  test('legacy cloud TTS settings migrate without client credentials', () {
    final settings = TtsSettings.fromJson({
      'engine': TtsSettings.engineIflytek,
      'iflytekAppId': '',
      'iflytekApiKey': '',
      'iflytekApiSecret': '',
    });

    expect(settings.engine, TtsSettings.engineSystem);
    expect(settings.hasIflytekCredentials, isFalse);
    expect(settings.iflytekAppId, isEmpty);
    expect(settings.iflytekApiKey, isEmpty);
    expect(settings.iflytekApiSecret, isEmpty);
    expect(settings.toJson(), isNot(contains('iflytekAppId')));
    expect(settings.toJson(), isNot(contains('iflytekApiKey')));
    expect(settings.toJson(), isNot(contains('iflytekApiSecret')));
  });

  test('TTS settings screen does not expose credential inputs', () {
    final source = File('lib/screens/settings_screen.dart').readAsStringSync();

    expect(source, contains('不在 App 内保存第三方密钥'));
    expect(source, isNot(contains('App 已内置语音服务配置')));
    expect(source, isNot(contains('_buildCredentialField')));
    expect(source, isNot(contains("label: 'AppID'")));
    expect(source, isNot(contains("label: 'API Key'")));
    expect(source, isNot(contains("label: 'API Secret'")));
  });
}
