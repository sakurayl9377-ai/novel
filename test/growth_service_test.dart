import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/models/growth_models.dart';
import 'package:novel_app/services/growth_service.dart';

const _context = GrowthClientContext(
  installId: 'install-test',
  versionCode: 37,
  platform: 'android',
);

GrowthService _service(
  MockClient client, {
  String Function()? idFactory,
  DateTime Function()? now,
}) {
  return GrowthService(
    httpClient: client,
    baseUrl: 'https://api.example.test///',
    clientContextLoader: () async => _context,
    idFactory: idFactory,
    now: now,
  );
}

void main() {
  test('recommendations clamp query values and parse response', () async {
    late http.Request captured;
    final service = _service(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'items': [
              {
                'rank': 1,
                'score': 12,
                'content': {
                  'stableKey': 'novel:a:1',
                  'contentType': 'novel',
                  'sourceKey': 'a',
                  'sourceItemId': '1',
                  'title': '小说 A',
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final items = await service.fetchRecommendations(
      token: ' token-a ',
      contentType: 'NOVEL',
      limit: 999,
    );

    expect(items.single.content.title, '小说 A');
    expect(captured.method, 'GET');
    expect(captured.url.path, '/app/recommendations');
    expect(captured.url.queryParameters, {
      'contentType': 'novel',
      'limit': '50',
      'versionCode': '37',
      'installId': 'install-test',
      'platform': 'android',
    });
    expect(captured.headers['authorization'], 'Bearer token-a');
  });

  test('ranking cache is isolated by authenticated actor', () async {
    var requests = 0;
    final service = _service(
      MockClient((request) async {
        requests += 1;
        final actor = request.headers['authorization'] ?? 'guest';
        return http.Response(
          jsonEncode({
            'items': [
              {
                'rank': 1,
                'score': 10,
                'content': {
                  'stableKey': actor,
                  'contentType': 'novel',
                  'sourceKey': 'source',
                  'sourceItemId': '1',
                  'title': actor,
                },
              },
            ],
          }),
          200,
        );
      }),
    );

    final first = await service.fetchRankings(token: 'user-a');
    final second = await service.fetchRankings(token: 'user-b');
    final cachedFirst = await service.fetchRankings(token: 'user-a');

    expect(first.single.content.title, 'Bearer user-a');
    expect(second.single.content.title, 'Bearer user-b');
    expect(cachedFirst.single.content.title, 'Bearer user-a');
    expect(requests, 2);
  });

  test('claim and behavior requests are deterministic under test', () async {
    final requests = <http.Request>[];
    var nextId = 0;
    final service = _service(
      MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
      idFactory: () => 'id-${++nextId}',
      now: () => DateTime.utc(2026, 7, 10, 1, 2, 3),
    );

    await service.claimActivityTask(token: 'abc', campaignId: 4, taskId: 5);
    await service.recordBehavior(
      content: const GrowthContent(
        stableKey: 'anime:1',
        contentType: 'anime',
        sourceKey: 'anime',
        sourceItemId: '1',
        title: '动画',
      ),
      event: 'click',
      source: 'ranking',
    );

    expect(requests[0].url.path, '/app/activities/4/tasks/5/claim');
    expect(jsonDecode(requests[0].body), {'idempotencyKey': 'id-1'});
    expect(requests[1].url.path, '/app/behavior-events');
    expect(jsonDecode(requests[1].body), containsPair('eventId', 'id-2'));
    expect(
      jsonDecode(requests[1].body),
      containsPair('occurredAt', '2026-07-10T01:02:03.000Z'),
    );
  });

  test('non-success responses expose server message and status code', () async {
    final service = _service(
      MockClient(
        (_) async => http.Response(
          jsonEncode({'message': '请先登录'}),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      service.fetchActivities(token: 'expired'),
      throwsA(
        isA<GrowthServiceException>()
            .having((error) => error.message, 'message', '请先登录')
            .having((error) => error.statusCode, 'statusCode', 401),
      ),
    );
  });
}
