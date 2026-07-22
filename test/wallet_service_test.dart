import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/interaction_service.dart';

void main() {
  test('wallet service sends auth and bounded pagination', () async {
    late http.Request captured;
    final service = InteractionService(
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'balance': 120,
            'snapshotMaxId': 345,
            'ledger': {
              'page': 1,
              'pageSize': 50,
              'total': 0,
              'items': const [],
            },
          }),
          200,
        );
      }),
    );

    final wallet = await service.fetchWallet(
      token: 'token-a',
      page: 0,
      pageSize: 999,
      snapshotMaxId: 345,
    );

    expect(wallet.balance, 120);
    expect(captured.method, 'GET');
    expect(captured.url.path, '/novel-api/users/me/wallet');
    expect(captured.url.queryParameters, {
      'page': '1',
      'pageSize': '50',
      'snapshotMaxId': '345',
    });
    expect(wallet.snapshotMaxId, 345);
    expect(captured.headers['authorization'], 'Bearer token-a');
  });
}
