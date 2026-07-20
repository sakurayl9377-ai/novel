import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/models/tts_settings.dart';
import 'package:novel_app/services/iflytek_tts_service.dart';

void main() {
  test(
    'sends TTS text and options through authenticated backend proxy',
    () async {
      late http.Request captured;
      final service = IflytekTtsService(
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }),
      );

      final result = await service.synthesize(
        text: '测试朗读',
        settings: const TtsSettings(
          engine: TtsSettings.engineIflytek,
          iflytekVoiceName: 'aisjiuxu',
        ),
        authToken: 'session-token',
        rate: 0.6,
        volume: 0.8,
        pitch: 1.1,
      );

      expect(result, [1, 2, 3]);
      expect(captured.url.path, endsWith('/speech/tts'));
      expect(captured.headers['Authorization'], 'Bearer session-token');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['text'], '测试朗读');
      expect(body['voice'], 'aisjiuxu');
      expect(body, isNot(contains('apiKey')));
      expect(body, isNot(contains('apiSecret')));
    },
  );

  test('requires login before calling backend proxy', () async {
    final service = IflytekTtsService(
      httpClient: MockClient((_) async => http.Response('', 500)),
    );

    await expectLater(
      service.synthesize(
        text: '测试',
        settings: const TtsSettings(engine: TtsSettings.engineIflytek),
        authToken: '',
        rate: 0.5,
        volume: 0.8,
        pitch: 1,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'retries one transient timeout and returns the next audio result',
    () async {
      var attempts = 0;
      final service = IflytekTtsService(
        requestTimeout: const Duration(milliseconds: 10),
        retryDelay: Duration.zero,
        httpClient: MockClient((_) async {
          attempts++;
          if (attempts == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          return http.Response.bytes([4, 5, 6], 200);
        }),
      );

      final result = await service.synthesize(
        text: '重试测试',
        settings: const TtsSettings(engine: TtsSettings.engineIflytek),
        authToken: 'session-token',
        rate: 0.5,
        volume: 0.8,
        pitch: 1,
      );

      expect(result, [4, 5, 6]);
      expect(attempts, 2);
    },
  );

  test(
    'reports a friendly recoverable error after repeated timeouts',
    () async {
      final service = IflytekTtsService(
        requestTimeout: const Duration(milliseconds: 5),
        retryDelay: Duration.zero,
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response('', 200);
        }),
      );

      await expectLater(
        service.synthesize(
          text: '超时测试',
          settings: const TtsSettings(engine: TtsSettings.engineIflytek),
          authToken: 'session-token',
          rate: 0.5,
          volume: 0.8,
          pitch: 1,
        ),
        throwsA(
          isA<IflytekTtsException>()
              .having((error) => error.isRetryable, 'isRetryable', isTrue)
              .having(
                (error) => error.toString(),
                'message',
                '科大讯飞响应超时，请检查网络后点击继续',
              ),
        ),
      );
    },
  );
}
