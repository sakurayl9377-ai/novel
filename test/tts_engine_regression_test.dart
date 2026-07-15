import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/tts_settings.dart';
import 'package:novel_app/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iflytek selection uses the authenticated backend path', () {
    final source = File('lib/services/tts_service.dart').readAsStringSync();

    expect(source, contains('if (settings.useIflytek)'));
    expect(source, contains('if (authToken.trim().isEmpty)'));
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

  test('speak followed immediately by stop never starts later', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var nativeSpeakCalls = 0;

    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
      call,
    ) async {
      if (call.method == 'speak') nativeSpeakCalls++;
      return 1;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        null,
      );
    });

    final service = TtsService();
    var startCallbacks = 0;
    var completionCallbacks = 0;
    service.onStart = () => startCallbacks++;
    service.onComplete = () => completionCallbacks++;
    addTearDown(service.dispose);

    final speakResult = service.speak('这段文字不应该在停止后重新朗读');
    final stopResult = service.stop();

    expect(await speakResult, isFalse);
    expect(await stopResult, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(nativeSpeakCalls, 0);
    expect(service.isSpeaking, isFalse);

    for (final callback in ['speak.onStart', 'speak.onComplete']) {
      await messenger.handlePlatformMessage(
        'flutter_tts',
        const StandardMethodCodec().encodeMethodCall(MethodCall(callback)),
        null,
      );
    }
    expect(startCallbacks, 0);
    expect(completionCallbacks, 0);
    expect(service.isSpeaking, isFalse);
  });

  test(
    'callbacks from a stopped utterance cannot complete its replacement',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final replacementNativeSpeak = Completer<dynamic>();
      var nativeSpeakCalls = 0;

      messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
        call,
      ) async {
        if (call.method != 'speak') return 1;
        nativeSpeakCalls++;
        return nativeSpeakCalls == 2 ? await replacementNativeSpeak.future : 1;
      });
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (_) async => null,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers.global'),
          null,
        );
      });

      Future<void> emit(String callback) => messenger.handlePlatformMessage(
        'flutter_tts',
        const StandardMethodCodec().encodeMethodCall(MethodCall(callback)),
        null,
      );

      final service = TtsService();
      var startCallbacks = 0;
      var completionCallbacks = 0;
      service.onStart = () => startCallbacks++;
      service.onComplete = () => completionCallbacks++;
      addTearDown(service.dispose);

      expect(await service.speak('第一段朗读内容'), isTrue);
      await emit('speak.onStart');
      expect(startCallbacks, 1);
      expect(await service.stop(), isTrue);

      final replacement = service.speak('第二段替换后的朗读内容');
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(nativeSpeakCalls, 2);

      await emit('speak.onStart');
      await emit('speak.onComplete');
      expect(startCallbacks, 1);
      expect(completionCallbacks, 0);

      replacementNativeSpeak.complete(1);
      expect(await replacement, isTrue);
      expect(startCallbacks, 2);
      await emit('speak.onStart');
      await emit('speak.onComplete');
      await emit('speak.onComplete');
      expect(startCallbacks, 2);
      expect(completionCallbacks, 1);
      expect(service.isSpeaking, isFalse);
    },
  );

  test('cloud TTS settings retain engine and never persist credentials', () {
    final settings = TtsSettings.fromJson({
      'engine': TtsSettings.engineIflytek,
      'iflytekAppId': '',
      'iflytekApiKey': '',
      'iflytekApiSecret': '',
    });

    expect(settings.engine, TtsSettings.engineIflytek);
    expect(settings.toJson(), isNot(contains('iflytekAppId')));
    expect(settings.toJson(), isNot(contains('iflytekApiKey')));
    expect(settings.toJson(), isNot(contains('iflytekApiSecret')));
  });

  test('TTS settings screen does not expose credential inputs', () {
    final source = File('lib/screens/settings_screen.dart').readAsStringSync();

    expect(source, contains('需要登录；App 不保存科大讯飞密钥'));
    expect(source, contains('value: TtsSettings.engineIflytek'));
    expect(source, isNot(contains('_buildCredentialField')));
    expect(source, isNot(contains("label: 'AppID'")));
    expect(source, isNot(contains("label: 'API Key'")));
    expect(source, isNot(contains("label: 'API Secret'")));
  });
}
