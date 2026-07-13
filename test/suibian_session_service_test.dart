import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/suibian_session_service.dart';

void main() {
  test(
    'exchanges the current Novel token without putting it in the URL',
    () async {
      late http.Request capturedRequest;
      final client = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({'token': 'video-session-token'}), 200);
      });
      final service = SuibianSessionService(
        client: client,
        apiBaseUrl: 'https://dfyc.cc.cd/video-api/',
      );

      final token = await service.exchangeNovelToken(' novel-session-token ');

      expect(token, 'video-session-token');
      expect(
        capturedRequest.url.toString(),
        'https://dfyc.cc.cd/video-api/auth/novel-exchange',
      );
      expect(capturedRequest.url.query, isEmpty);
      expect(jsonDecode(capturedRequest.body), {
        'token': 'novel-session-token',
      });
    },
  );

  test('surfaces the backend message when the exchange is rejected', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({'message': '登录已过期'}),
        401,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    final service = SuibianSessionService(client: client);

    expect(
      () => service.exchangeNovelToken('expired-token'),
      throwsA(
        isA<SuibianSessionException>().having(
          (error) => error.message,
          'message',
          '登录已过期',
        ),
      ),
    );
  });
}
