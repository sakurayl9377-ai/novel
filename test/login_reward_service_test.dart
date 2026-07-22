import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/login_reward_service.dart';

void main() {
  test('sync sends the app version and parses pending notices', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, endsWith('/growth/login-rewards/sync'));
      expect(request.headers['authorization'], 'Bearer test-token');
      expect(jsonDecode(request.body), {'versionCode': 99});
      return http.Response(
        jsonEncode({
          'balance': 320,
          'items': [
            {
              'id': 7,
              'campaignId': 3,
              'title': 'Today bonus',
              'content': 'Welcome back',
              'coinsAwarded': 20,
              'createdAt': '2026-07-22T08:00:00.000Z',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = LoginRewardService(
      httpClient: client,
      versionCodeLoader: () async => 99,
    );

    final result = await service.sync(token: 'test-token');

    expect(result.balance, 320);
    expect(result.items, hasLength(1));
    expect(result.items.single.id, 7);
    expect(result.items.single.coinsAwarded, 20);
  });

  test('acknowledge confirms only the selected notice', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, endsWith('/growth/login-rewards/42/ack'));
      expect(request.headers['authorization'], 'Bearer test-token');
      return http.Response('{"ok":true}', 200);
    });
    final service = LoginRewardService(httpClient: client);

    await service.acknowledge(token: 'test-token', noticeId: 42);
  });
}
