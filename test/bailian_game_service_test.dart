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
            'total': 2,
            'nextOffset': 2,
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
      searchQuery: '仙玉',
      fromDate: DateTime(2026, 7, 1),
      toDate: DateTime(2026, 7, 29),
    );

    expect(page.items, hasLength(2));
    expect(page.items.first.id, 'order-1');
    expect(page.hasMore, isFalse);
    expect(page.snapshotMaxId, 88);
    expect(page.total, 2);
    expect(page.nextOffset, 2);
    expect(captured.url.path, '/novel-api/users/me/orders');
    expect(captured.url.queryParameters, {
      'offset': '0',
      'limit': '2',
      'snapshotMaxId': '88',
      'q': '仙玉',
      'from': '2026-07-01',
      'to': '2026-07-29',
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
