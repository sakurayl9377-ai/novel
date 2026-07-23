import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/game_catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('accepts only enabled fixed local games and honors sortOrder', () async {
    final preferences = await SharedPreferences.getInstance();
    http.BaseRequest? capturedRequest;
    final service = GameCatalogService(
      preferences: preferences,
      httpClient: MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'generatedAt': '2026-07-23T08:00:00.000Z',
            'games': [
              _game('modao', sortOrder: 30),
              _game('bailian', visible: false, sortOrder: 20),
              _game('unknown', route: 'https://evil.example/game'),
              _game(
                'horse-race',
                route: 'https://evil.example/horse-race',
                sortOrder: 0,
              ),
              _game('horse-race', sortOrder: 10),
              _game('bailian', enabled: false, sortOrder: 5),
            ],
          }),
          200,
          request: request,
        );
      }),
    );

    final snapshot = await service.load();

    expect(snapshot.source, GameCatalogSource.network);
    expect(snapshot.gameIds, <String>['horse-race', 'modao']);
    expect(capturedRequest?.method, 'GET');
    expect(capturedRequest?.url.path, '/novel-api/games/catalog');
    expect(capturedRequest?.headers['Authorization'], isNull);
    expect(capturedRequest?.headers['Accept-Encoding'], 'identity');
    expect(capturedRequest?.followRedirects, isFalse);
    expect(preferences.getStringList(GameCatalogService.cacheKey), <String>[
      'horse-race',
      'modao',
    ]);
  });

  test(
    'fails closed for managed games when the catalog is unavailable',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final successful = GameCatalogService(
        preferences: preferences,
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'games': [
                _game('modao', sortOrder: 30),
                _game('horse-race', sortOrder: 10),
                _game('bailian', sortOrder: 20),
              ],
            }),
            200,
            request: request,
          );
        }),
      );
      expect((await successful.load()).gameIds, <String>[
        'horse-race',
        'bailian',
        'modao',
      ]);

      final failing = GameCatalogService(
        preferences: preferences,
        httpClient: MockClient((request) async {
          throw http.ClientException('offline', request.url);
        }),
      );
      final cached = await failing.load();

      expect(cached.source, GameCatalogSource.cache);
      expect(cached.gameIds, <String>['horse-race']);

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final emptyPreferences = await SharedPreferences.getInstance();
      final fallback = await GameCatalogService(
        preferences: emptyPreferences,
        httpClient: MockClient((request) async {
          throw http.ClientException('offline', request.url);
        }),
      ).load();

      expect(fallback.source, GameCatalogSource.fallback);
      expect(fallback.gameIds, <String>['horse-race']);
      expect(fallback.gameIds, isNot(contains('bailian')));
      expect(fallback.gameIds, isNot(contains('modao')));
    },
  );

  test('keeps a successful empty catalog as the last known state', () async {
    final preferences = await SharedPreferences.getInstance();
    final successful = GameCatalogService(
      preferences: preferences,
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({'games': <Object>[]}),
          200,
          request: request,
        );
      }),
    );
    expect((await successful.load()).gameIds, isEmpty);

    final cached = await GameCatalogService(
      preferences: preferences,
      httpClient: MockClient((request) async {
        throw http.ClientException('offline', request.url);
      }),
    ).load();

    expect(cached.source, GameCatalogSource.cache);
    expect(cached.gameIds, isEmpty);
  });

  test('rejects redirects and oversized responses and uses cache', () async {
    for (final response in <http.Response Function(http.BaseRequest)>[
      (request) => http.Response('', 302, request: request),
      (request) => http.Response(
        'x' * (GameCatalogService.maxResponseBytes + 1),
        200,
        request: request,
      ),
    ]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        GameCatalogService.cacheKey: <String>['modao'],
      });
      final preferences = await SharedPreferences.getInstance();
      final snapshot = await GameCatalogService(
        preferences: preferences,
        httpClient: MockClient((request) async => response(request)),
      ).load();

      expect(snapshot.source, GameCatalogSource.cache);
      expect(snapshot.gameIds, isEmpty);
    }
  });
}

Map<String, Object> _game(
  String id, {
  String? route,
  bool visible = true,
  bool enabled = true,
  int sortOrder = 10,
}) {
  final entryType = switch (id) {
    'horse-race' => 'native',
    'bailian' => 'web',
    'modao' => 'apk',
    _ => 'web',
  };
  return <String, Object>{
    'id': id,
    'route': route ?? id,
    'name': 'server supplied name',
    'description': 'server supplied description',
    'visible': visible,
    'enabled': enabled,
    'sortOrder': sortOrder,
    'entryType': entryType,
    'requiresLogin': true,
  };
}
