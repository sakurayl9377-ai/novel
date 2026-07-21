import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/tts_settings.dart';
import 'package:novel_app/services/tts_audio_session.dart';
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
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(nativeSpeakCalls, 2);

      await emit('speak.onStart');
      await emit('speak.onComplete');
      expect(startCallbacks, 1);
      expect(completionCallbacks, 0);

      replacementNativeSpeak.complete(1);
      expect(await replacement, isTrue);
      expect(startCallbacks, 2);
      await emit('speak.onStart');
      expect(service.isSpeaking, isTrue);
      await emit('speak.onComplete');
      await emit('speak.onComplete');
      expect(startCallbacks, 2);
      expect(completionCallbacks, 1);
      expect(service.isSpeaking, isFalse);
    },
  );

  test('a late old cancel does not pause an accepted replacement', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => 1,
    );
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
    var interruptionCallbacks = 0;
    service.onInterrupted = () => interruptionCallbacks++;
    addTearDown(service.dispose);

    expect(await service.speak('old utterance'), isTrue);
    expect(await service.stop(), isTrue);
    expect(await service.speak('accepted replacement'), isTrue);
    await messenger.handlePlatformMessage(
      'flutter_tts',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('speak.onCancel'),
      ),
      null,
    );
    await messenger.handlePlatformMessage(
      'flutter_tts',
      const StandardMethodCodec().encodeMethodCall(MethodCall('speak.onStart')),
      null,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(interruptionCallbacks, 0);
    expect(service.isPaused, isFalse);
    expect(service.isSpeaking, isTrue);
  });

  test('a new utterance cancel is not hidden by an old stop marker', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => 1,
    );
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
    var interruptionCallbacks = 0;
    service.onInterrupted = () => interruptionCallbacks++;
    addTearDown(service.dispose);

    expect(await service.speak('old utterance'), isTrue);
    expect(await service.stop(), isTrue);
    expect(await service.speak('new utterance'), isTrue);
    await messenger.handlePlatformMessage(
      'flutter_tts',
      const StandardMethodCodec().encodeMethodCall(MethodCall('speak.onStart')),
      null,
    );
    await messenger.handlePlatformMessage(
      'flutter_tts',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('speak.onCancel'),
      ),
      null,
    );
    await _waitUntil(() => interruptionCallbacks == 1);

    expect(service.isPaused, isTrue);
    expect(service.isSpeaking, isFalse);
  });

  test(
    'audio focus interruption pauses once and never automatically resumes',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (_) async => 1,
      );
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

      final audioSession = _FakeTtsAudioSession();
      final service = TtsService(audioSession: audioSession);
      var interruptionCallbacks = 0;
      service.onInterrupted = () => interruptionCallbacks++;
      addTearDown(service.dispose);

      expect(await service.speak('音频焦点被其他应用抢占'), isTrue);
      expect(audioSession.activateCalls, 1);

      audioSession.emit(
        const TtsAudioInterruptionEvent(
          begin: true,
          kind: TtsAudioInterruptionKind.focusDuck,
        ),
      );
      audioSession.emit(
        const TtsAudioInterruptionEvent(
          begin: true,
          kind: TtsAudioInterruptionKind.focusPause,
        ),
      );
      await _waitUntil(() => interruptionCallbacks == 1);

      expect(service.isPaused, isTrue);
      expect(service.isSpeaking, isFalse);
      expect(audioSession.deactivateCalls, 1);

      audioSession.emit(
        const TtsAudioInterruptionEvent(
          begin: false,
          kind: TtsAudioInterruptionKind.focusPause,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.isPaused, isTrue);
      expect(interruptionCallbacks, 1);
    },
  );

  test('becoming noisy pauses through the same interruption path', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => 1,
    );
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

    final audioSession = _FakeTtsAudioSession();
    final service = TtsService(audioSession: audioSession);
    var interruptionCallbacks = 0;
    service.onInterrupted = () => interruptionCallbacks++;
    addTearDown(service.dispose);

    expect(await service.speak('耳机断开时暂停'), isTrue);
    audioSession.emit(const TtsAudioInterruptionEvent.becomingNoisy());
    await _waitUntil(() => interruptionCallbacks == 1);

    expect(service.isPaused, isTrue);
    expect(audioSession.deactivateCalls, 1);
  });

  test('system TTS errors release audio focus before notifying', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => 1,
    );
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

    final audioSession = _FakeTtsAudioSession();
    final service = TtsService(audioSession: audioSession);
    var errorCallbacks = 0;
    var deactivateCallsAtNotification = 0;
    service.onError = () {
      errorCallbacks++;
      deactivateCallsAtNotification = audioSession.deactivateCalls;
    };
    addTearDown(service.dispose);

    expect(await service.speak('system engine error'), isTrue);
    await messenger.handlePlatformMessage(
      'flutter_tts',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('speak.onError', 'engine failed'),
      ),
      null,
    );
    await _waitUntil(() => errorCallbacks == 1);

    expect(service.isSpeaking, isFalse);
    expect(service.isPaused, isFalse);
    expect(audioSession.deactivateCalls, 1);
    expect(deactivateCallsAtNotification, 1);
  });

  test(
    'cancel callback caused by an explicit stop is not an interruption',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (_) async => 1,
      );
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

      final audioSession = _FakeTtsAudioSession();
      final service = TtsService(audioSession: audioSession);
      var interruptionCallbacks = 0;
      service.onInterrupted = () => interruptionCallbacks++;
      addTearDown(service.dispose);

      expect(await service.speak('用户主动停止'), isTrue);
      expect(await service.stop(), isTrue);
      await messenger.handlePlatformMessage(
        'flutter_tts',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('speak.onCancel'),
        ),
        null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(interruptionCallbacks, 0);
      expect(service.isPaused, isFalse);
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

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

class _FakeTtsAudioSession implements TtsAudioSessionPort {
  final StreamController<TtsAudioInterruptionEvent> _events =
      StreamController<TtsAudioInterruptionEvent>.broadcast(sync: true);
  int configureCalls = 0;
  int activateCalls = 0;
  int deactivateCalls = 0;

  @override
  Stream<TtsAudioInterruptionEvent> get events => _events.stream;

  void emit(TtsAudioInterruptionEvent event) => _events.add(event);

  @override
  Future<void> configureForSpeech() async {
    configureCalls++;
  }

  @override
  Future<bool> activate() async {
    activateCalls++;
    return true;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls++;
  }

  @override
  Future<void> dispose() => _events.close();
}
