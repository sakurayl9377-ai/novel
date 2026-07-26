import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/interaction_auth_service.dart';

void main() {
  test('beta auth service sends no embedded credential', () async {
    late http.Request captured;
    final service = InteractionAuthService(
      betaTestSessionEnabled: true,
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'token': 'server-created-session-token',
            'user': {
              'id': 90210,
              'email': 'reader-beta-session@local.invalid',
              'nickname': 'Sakura Beta 测试员',
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await service.createBetaTestSession();

    expect(captured.method, 'POST');
    expect(captured.url.path, endsWith('/auth/beta-session'));
    expect(captured.headers['X-Sakura-Reader-Beta'], '1');
    expect(captured.headers['Content-Type'], 'application/json');
    expect(captured.headers.containsKey('Authorization'), isFalse);
    expect(jsonDecode(captured.body), isEmpty);
    expect(result.token, 'server-created-session-token');
    expect(result.user.id, 90210);
  });

  test(
    'beta auth service is locally disabled without the build gate',
    () async {
      var requested = false;
      final service = InteractionAuthService(
        betaTestSessionEnabled: false,
        client: MockClient((request) async {
          requested = true;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        service.createBetaTestSession(),
        throwsA(isA<InteractionAuthException>()),
      );
      expect(requested, isFalse);
    },
  );

  test('KDJX session revocation uses the Sakura bearer session', () async {
    late http.Request captured;
    final service = InteractionAuthService(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'ok': true, 'revoked': 1}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await service.revokeKdjxSessions('sakura-access-token');

    expect(captured.method, 'POST');
    expect(captured.url.path, endsWith('/games/kdjx/sessions/revoke'));
    expect(captured.headers['Authorization'], 'Bearer sakura-access-token');
    expect(jsonDecode(captured.body), isEmpty);
  });
}
