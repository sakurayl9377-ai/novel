import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/models/content_progress.dart';
import 'package:novel_app/services/progress_database.dart';
import 'package:novel_app/services/progress_sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late ProgressDatabase database;

  setUp(() async {
    database = ProgressDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await database.init();
  });

  tearDown(() => database.close());

  test('HTTP API parses optional authoritative write results', () async {
    final identity = ContentIdentity.manga('http-result');
    final winner = _record(
      identity,
      deviceId: 'server-device',
      updatedAtMs: 200,
      payload: const {'pageIndex': 9},
    );
    final api = HttpProgressSyncApi(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        return http.Response(
          jsonEncode({
            'cursor': '2',
            'items': const [],
            'hasMore': false,
            'writeResults': [
              {
                'contentKey': identity.contentKey,
                'accepted': false,
                'winner': winner.toSyncJson(),
              },
            ],
          }),
          200,
        );
      }),
    );

    final page = await api.push(
      token: 'token',
      deviceId: 'device-a',
      cursor: '1',
      items: [winner],
    );

    expect(page.writeResults, hasLength(1));
    expect(page.writeResults?.single.accepted, isFalse);
    expect(page.writeResults?.single.winner?.payload['pageIndex'], 9);
  });

  test(
    'HTTP API rejects malformed writeResults instead of marking clean',
    () async {
      final api = HttpProgressSyncApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'cursor': '2',
              'items': const [],
              'hasMore': false,
              'writeResults': {'accepted': true},
            }),
            200,
          ),
        ),
      );

      await expectLater(
        api.push(
          token: 'token',
          deviceId: 'device-a',
          cursor: '1',
          items: const [],
        ),
        throwsA(isA<ProgressSyncException>()),
      );
    },
  );

  test(
    'a rejected stale push adopts the server winner and becomes clean',
    () async {
      final identity = ContentIdentity.manga('stale-book');
      await database.saveLocal(
        ownerUserId: 'user-a',
        identity: identity,
        subItemId: 'chapter-1',
        payload: const {'pageIndex': 1},
        metadata: const {},
        deviceId: 'device-a',
        clientUpdatedAtMs: 100,
      );
      final winner = _record(
        identity,
        deviceId: 'device-z',
        updatedAtMs: 200,
        payload: const {'pageIndex': 8},
      );
      final service = ProgressSyncService(
        database: database,
        api: _WriteResultApi(
          result: ProgressSyncWriteResult(
            contentKey: identity.contentKey,
            accepted: false,
            winner: winner,
          ),
        ),
      );

      await service.syncNow(token: 'token', userId: 'user-a');

      final stored = await database.get(identity, ownerUserId: 'user-a');
      expect(stored?.payload['pageIndex'], 8);
      expect(stored?.deviceId, 'device-z');
      expect(await database.claimDirty('user-a'), isEmpty);
    },
  );

  test(
    'an accepted server-normalized timestamp replaces the pushed value',
    () async {
      final identity = ContentIdentity.anime(42);
      await database.saveLocal(
        ownerUserId: 'user-a',
        identity: identity,
        subItemId: 'episode-1',
        payload: const {'positionMs': 50},
        metadata: const {},
        deviceId: 'device-a',
        clientUpdatedAtMs: 9000,
      );
      final winner = _record(
        identity,
        deviceId: 'device-a',
        updatedAtMs: 5000,
        payload: const {'positionMs': 50},
      );
      final service = ProgressSyncService(
        database: database,
        api: _WriteResultApi(
          result: ProgressSyncWriteResult(
            contentKey: identity.contentKey,
            accepted: true,
            winner: winner,
          ),
        ),
      );

      await service.syncNow(token: 'token', userId: 'user-a');

      final stored = await database.get(identity, ownerUserId: 'user-a');
      expect(stored?.clientUpdatedAtMs, 5000);
      expect(await database.claimDirty('user-a'), isEmpty);
    },
  );

  test('push reconciliation never overwrites a newer local mutation', () async {
    final identity = ContentIdentity.manga('concurrent-write');
    await database.saveLocal(
      ownerUserId: 'user-a',
      identity: identity,
      subItemId: 'chapter-1',
      payload: const {'pageIndex': 1},
      metadata: const {},
      deviceId: 'device-a',
      clientUpdatedAtMs: 100,
    );
    final service = ProgressSyncService(
      database: database,
      api: _ConcurrentMutationApi(database: database, identity: identity),
    );

    await expectLater(
      service.syncNow(token: 'token', userId: 'user-a'),
      throwsA(isA<StateError>()),
    );

    final stored = await database.get(identity, ownerUserId: 'user-a');
    expect(stored?.payload['pageIndex'], 99);
    expect(stored?.clientUpdatedAtMs, 300);
    expect(await database.claimDirty('user-a'), hasLength(1));
  });

  test('missing write acknowledgement leaves the row dirty', () async {
    final identity = ContentIdentity.manga('missing-result');
    await database.saveLocal(
      ownerUserId: 'user-a',
      identity: identity,
      subItemId: 'chapter-1',
      payload: const {'pageIndex': 1},
      metadata: const {},
      deviceId: 'device-a',
      clientUpdatedAtMs: 100,
    );
    final service = ProgressSyncService(
      database: database,
      api: const _StaticPageApi(
        ProgressSyncPage(
          cursor: '1',
          items: [],
          hasMore: false,
          writeResults: [],
        ),
      ),
    );

    await expectLater(
      service.syncNow(token: 'token', userId: 'user-a'),
      throwsA(isA<ProgressSyncException>()),
    );
    expect(await database.claimDirty('user-a'), hasLength(1));
  });

  test(
    'a winner with a mismatched identity is rejected and stays dirty',
    () async {
      final identity = ContentIdentity.manga('identity-a');
      await database.saveLocal(
        ownerUserId: 'user-a',
        identity: identity,
        subItemId: 'chapter-1',
        payload: const {'pageIndex': 1},
        metadata: const {},
        deviceId: 'device-a',
        clientUpdatedAtMs: 100,
      );
      final mismatchedWinner = ContentProgressRecord(
        identity: ContentIdentity.manga('identity-b'),
        contentKey: identity.contentKey,
        subItemId: 'chapter-2',
        payload: const {'pageIndex': 8},
        metadata: const {},
        deviceId: 'device-z',
        clientUpdatedAtMs: 200,
        deleted: false,
        dirty: false,
      );
      final service = ProgressSyncService(
        database: database,
        api: _WriteResultApi(
          result: ProgressSyncWriteResult(
            contentKey: identity.contentKey,
            accepted: false,
            winner: mismatchedWinner,
          ),
        ),
      );

      await expectLater(
        service.syncNow(token: 'token', userId: 'user-a'),
        throwsA(isA<ProgressSyncException>()),
      );
      expect(await database.claimDirty('user-a'), hasLength(1));
    },
  );

  test(
    'responses without writeResults keep old-server compatibility',
    () async {
      final identity = ContentIdentity.anime(7);
      await database.saveLocal(
        ownerUserId: 'user-a',
        identity: identity,
        subItemId: 'episode-1',
        payload: const {'positionMs': 10},
        metadata: const {},
        deviceId: 'device-a',
        clientUpdatedAtMs: 100,
      );
      final service = ProgressSyncService(
        database: database,
        api: const _StaticPageApi(
          ProgressSyncPage(cursor: '1', items: [], hasMore: false),
        ),
      );

      await service.syncNow(token: 'token', userId: 'user-a');

      expect(await database.claimDirty('user-a'), isEmpty);
    },
  );
}

ContentProgressRecord _record(
  ContentIdentity identity, {
  required String deviceId,
  required int updatedAtMs,
  required Map<String, dynamic> payload,
}) {
  return ContentProgressRecord(
    identity: identity,
    contentKey: identity.contentKey,
    subItemId: 'server-winner',
    payload: payload,
    metadata: const {},
    deviceId: deviceId,
    clientUpdatedAtMs: updatedAtMs,
    deleted: false,
    dirty: false,
  );
}

class _WriteResultApi implements ProgressSyncApi {
  const _WriteResultApi({required this.result});

  final ProgressSyncWriteResult result;

  @override
  Future<ProgressSyncPage> pull({
    required String token,
    required String cursor,
    required int limit,
  }) async {
    return ProgressSyncPage(cursor: cursor, items: const [], hasMore: false);
  }

  @override
  Future<ProgressSyncPage> push({
    required String token,
    required String deviceId,
    required String cursor,
    required List<ContentProgressRecord> items,
  }) async {
    return ProgressSyncPage(
      cursor: '1',
      items: const [],
      hasMore: false,
      writeResults: [result],
    );
  }
}

class _StaticPageApi implements ProgressSyncApi {
  const _StaticPageApi(this.page);

  final ProgressSyncPage page;

  @override
  Future<ProgressSyncPage> pull({
    required String token,
    required String cursor,
    required int limit,
  }) async {
    return ProgressSyncPage(cursor: cursor, items: const [], hasMore: false);
  }

  @override
  Future<ProgressSyncPage> push({
    required String token,
    required String deviceId,
    required String cursor,
    required List<ContentProgressRecord> items,
  }) async => page;
}

class _ConcurrentMutationApi implements ProgressSyncApi {
  _ConcurrentMutationApi({required this.database, required this.identity});

  final ProgressDatabase database;
  final ContentIdentity identity;
  int pushes = 0;

  @override
  Future<ProgressSyncPage> pull({
    required String token,
    required String cursor,
    required int limit,
  }) async {
    return ProgressSyncPage(cursor: cursor, items: const [], hasMore: false);
  }

  @override
  Future<ProgressSyncPage> push({
    required String token,
    required String deviceId,
    required String cursor,
    required List<ContentProgressRecord> items,
  }) async {
    pushes += 1;
    if (pushes > 1) throw StateError('stop after concurrent mutation');
    await database.saveLocal(
      ownerUserId: 'user-a',
      identity: identity,
      subItemId: 'chapter-2',
      payload: const {'pageIndex': 99},
      metadata: const {},
      deviceId: 'device-a',
      clientUpdatedAtMs: 300,
    );
    final winner = _record(
      identity,
      deviceId: 'device-z',
      updatedAtMs: 200,
      payload: const {'pageIndex': 8},
    );
    return ProgressSyncPage(
      cursor: '1',
      items: const [],
      hasMore: false,
      writeResults: [
        ProgressSyncWriteResult(
          contentKey: identity.contentKey,
          accepted: false,
          winner: winner,
        ),
      ],
    );
  }
}
