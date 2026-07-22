import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/bailian_game_service.dart';

void main() {
  test('order paging respects an explicit false hasMore value', () async {
    late http.Request captured;
    final service = BailianGameService(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'items': [
              {'id': 'order-1', 'title': '订单 1'},
              {'id': 'order-2', 'title': '订单 2'},
            ],
            'hasMore': false,
            'snapshotMaxId': 88,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final page = await service.listPayments(
      'token-a',
      limit: 2,
      snapshotMaxId: 88,
    );

    expect(page.items, hasLength(2));
    expect(page.items.first.id, 'order-1');
    expect(page.hasMore, isFalse);
    expect(page.snapshotMaxId, 88);
    expect(captured.url.path, '/novel-api/users/me/orders');
    expect(captured.url.queryParameters, {
      'offset': '0',
      'limit': '2',
      'snapshotMaxId': '88',
    });
  });

  test('legacy order responses fall back to full-page detection', () async {
    final service = BailianGameService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'items': [
              {'id': 'order-1'},
              {'id': 'order-2'},
            ],
          }),
          200,
        ),
      ),
    );

    final page = await service.listPayments('token-a', limit: 2);

    expect(page.hasMore, isTrue);
  });
}
