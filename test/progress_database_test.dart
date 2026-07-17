import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/content_progress.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/models/reading_progress.dart';
import 'package:novel_app/services/legacy_progress_migrator.dart';
import 'package:novel_app/services/progress_database.dart';
import 'package:novel_app/services/progress_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('ContentIdentity', () {
    test('all entry points keep the furthest intra-chapter position', () {
      final saved = ReadingProgress(
        novelId: 'builtin_bqg995_bqg_5678',
        chapterIndex: 10,
        charPosition: 500,
      );
      final staleHome = ReadingProgress(
        novelId: 'builtin_bqg995_bqg_5678',
        chapterIndex: 10,
        charPosition: 0,
      );
      final staleHistory = ReadingProgress(
        novelId: 'old_bqg_source_bqg_5678',
        chapterIndex: 10,
        charPosition: 120,
      );

      final merged = furthestReadingProgress(
        furthestReadingProgress(saved, staleHome),
        staleHistory,
      );
      expect(merged?.chapterIndex, 10);
      expect(merged?.charPosition, 500);
    });

    test(
      'uses stable source and item identities instead of temporary URLs',
      () {
        final first = ContentIdentity.novel(
          Novel(
            id: 'book-42',
            title: '旧标题',
            sourceId: 'BQG_PRIMARY',
            chapterUrl: 'https://first.example/book/42',
          ),
        );
        final second = ContentIdentity.novel(
          Novel(
            id: 'book-42',
            title: '新标题',
            sourceId: 'bqg_primary',
            chapterUrl: 'https://fallback.example/book/42',
          ),
        );

        expect(first.contentKey, second.contentKey);
        final wenku8Home = ContentIdentity.novel(
          Novel(
            id: 'builtin_wenku8_wenku8_1234',
            title: 'Wenku8 home',
            sourceId: 'builtin_wenku8',
            chapterUrl:
                'https://www.wenku8.cc/wap/article/articleinfo.php?id=1234',
          ),
        );
        final wenku8Shelf = ContentIdentity.novel(
          Novel(
            id: 'old_source_wenku8_1234',
            title: 'Wenku8 shelf',
            sourceId: 'old_source',
            chapterUrl:
                'https://www.wenku8.net/wap/article/readbook.php?aid=1234',
          ),
        );
        expect(wenku8Home.contentKey, wenku8Shelf.contentKey);
        expect(wenku8Home.sourceKey, ContentIdentity.wenku8NovelSourceKey);
        expect(wenku8Home.itemId, 'wenku8:1234');
        final bqgHome = ContentIdentity.novel(
          Novel(
            id: 'builtin_bqg995_bqg_5678',
            title: 'BQG home',
            sourceId: 'builtin_bqg995',
            chapterUrl: 'https://example.com/#/book/5678/',
          ),
        );
        final bqgShelf = ContentIdentity.novel(
          Novel(
            id: 'old_bqg_source_bqg_5678',
            title: 'BQG shelf',
            sourceId: 'old_bqg_source',
            chapterUrl: 'https://fallback.example/book/5678/',
          ),
        );
        expect(bqgHome.contentKey, bqgShelf.contentKey);
        expect(bqgHome.sourceKey, ContentIdentity.bqgNovelSourceKey);
        expect(bqgHome.itemId, 'bqg:5678');
        expect(ContentIdentity.manga('m-1').sourceKey, 'manga_baozi');
        expect(ContentIdentity.anime(8).sourceKey, 'anime_yinhua');
        expect(ContentIdentity.normalizeSubItemId('  第  01 集  '), '第 01 集');

        final local = ContentIdentity.novel(
          Novel(id: 'local-1', title: '本地书', isLocal: true),
        );
        expect(local.syncEligible, isFalse);
        expect(local.sourceKey, ContentIdentity.localNovelSourceKey);
      },
    );
  });

  group('ProgressDatabase', () {
    late ProgressDatabase database;

    setUp(() async {
      database = ProgressDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      await database.init();
    });

    tearDown(() => database.close());

    test('migrates legacy preferences once and keeps the old values', () async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'bookshelf': jsonEncode([
          Novel(id: 'novel-1', title: '测试小说', sourceId: 'bqg_primary').toJson(),
        ]),
        'progress_novel-1': jsonEncode({
          'novelId': 'novel-1',
          'chapterIndex': 3,
          'scrollPosition': 12.0,
          'charPosition': 88,
          'lastReadAt': now.toIso8601String(),
        }),
        'anime_watch_history': jsonEncode([
          {
            'animeId': 7,
            'title': '动画',
            'coverUrl': '',
            'sourceName': '线路一',
            'episodeTitle': '第 1 集',
            'episodeUrl': 'https://temporary.example/video.m3u8',
            'positionMs': 2000,
            'durationMs': 9000,
            'updatedAtMs': now.millisecondsSinceEpoch,
            'episodes': const [],
          },
        ]),
        'manga_read_history': jsonEncode([
          {
            'mangaId': 'manga-9',
            'title': '漫画',
            'coverUrl': '',
            'chapterTitle': '第 2 话',
            'chapterUrl': 'https://temporary.example/chapter',
            'chapterIndex': 1,
            'scrollOffset': 100.0,
            'contentExtent': 1000.0,
            'updatedAtMs': now.millisecondsSinceEpoch,
            'chapters': const [],
          },
        ]),
      });
      final preferences = await SharedPreferences.getInstance();
      final migrator = LegacyProgressMigrator(
        database: database,
        preferences: preferences,
        deviceId: 'device-a',
      );

      expect(await migrator.migrate(), isTrue);
      expect(await migrator.migrate(), isFalse);

      expect(await database.countRows(), 3);
      expect(preferences.getString('progress_novel-1'), isNotNull);
      expect(preferences.getString('anime_watch_history'), isNotNull);
      final novel = await database.get(
        ContentIdentity(
          contentType: ContentType.novel,
          sourceKey: 'bqg_primary',
          itemId: 'novel-1',
        ),
        ownerUserId: ProgressOwner.guest,
      );
      expect(novel?.payload['chapterIndex'], 3);
    });

    test('updates one row without rewriting unrelated progress', () async {
      final anime = ContentIdentity.anime(1);
      final manga = ContentIdentity.manga('m-2');
      await database.saveLocal(
        ownerUserId: 'user-a',
        identity: anime,
        subItemId: '第1集',
        payload: const {'positionMs': 10},
        metadata: const {'title': 'A'},
        deviceId: 'device-a',
        clientUpdatedAtMs: 10,
      );
      await database.saveLocal(
        ownerUserId: 'user-a',
        identity: manga,
        subItemId: '第1话',
        payload: const {'pageIndex': 4},
        metadata: const {'title': 'M'},
        deviceId: 'device-a',
        clientUpdatedAtMs: 11,
      );
      final mangaBefore = await database.get(manga, ownerUserId: 'user-a');

      await database.saveLocal(
        ownerUserId: 'user-a',
        identity: anime,
        subItemId: '第2集',
        payload: const {'positionMs': 20},
        metadata: const {'title': 'A'},
        deviceId: 'device-a',
        clientUpdatedAtMs: 12,
      );

      expect(await database.countRows(), 2);
      expect(
        (await database.get(
          anime,
          ownerUserId: 'user-a',
        ))?.payload['positionMs'],
        20,
      );
      expect(await database.get(manga, ownerUserId: 'user-a'), isNotNull);
      expect(
        (await database.get(manga, ownerUserId: 'user-a'))?.clientUpdatedAtMs,
        mangaBefore?.clientUpdatedAtMs,
      );
    });

    test(
      'legacy fallback never crosses a source with the same item id',
      () async {
        const owner = 'user-a';
        const sourceA = ContentIdentity(
          contentType: ContentType.novel,
          sourceKey: 'source-a',
          itemId: 'shared-id',
        );
        const sourceB = ContentIdentity(
          contentType: ContentType.novel,
          sourceKey: 'source-b',
          itemId: 'shared-id',
        );
        await database.saveLocal(
          ownerUserId: owner,
          identity: sourceA,
          subItemId: 'chapter:1',
          payload: const {'chapterIndex': 1},
          metadata: const {},
          deviceId: 'device-a',
          clientUpdatedAtMs: 10,
        );

        expect(await database.get(sourceB, ownerUserId: owner), isNull);
        expect(
          await database.promoteLegacyNovel(sourceB, ownerUserId: owner),
          isNull,
        );

        final legacy = ContentIdentity.legacyNovel('shared-id');
        await database.saveLocal(
          ownerUserId: owner,
          identity: legacy,
          subItemId: 'chapter:3',
          payload: const {'chapterIndex': 3},
          metadata: const {},
          deviceId: 'device-a',
          clientUpdatedAtMs: 30,
        );
        final promoted = await database.promoteLegacyNovel(
          sourceB,
          ownerUserId: owner,
        );

        expect(promoted?.payload['chapterIndex'], 3);
        expect(await database.get(legacy, ownerUserId: owner), isNull);
        expect(
          (await database.get(
            sourceA,
            ownerUserId: owner,
          ))?.payload['chapterIndex'],
          1,
        );
      },
    );

    test('applies LWW and keeps remote tombstones clean', () async {
      final identity = ContentIdentity.anime(12);
      await database.saveLocal(
        ownerUserId: '8',
        identity: identity,
        subItemId: '第1集',
        payload: const {'positionMs': 500},
        metadata: const {},
        deviceId: 'local-z',
        clientUpdatedAtMs: 500,
      );
      final olderApplied = await database.applyRemote(
        _remoteRecord(identity, updatedAtMs: 400, deleted: true),
        userId: '8',
      );
      expect(olderApplied, isFalse);
      expect(await database.get(identity, ownerUserId: '8'), isNotNull);

      final newerApplied = await database.applyRemote(
        _remoteRecord(identity, updatedAtMs: 600, deleted: true),
        userId: '8',
      );
      expect(newerApplied, isTrue);
      expect(await database.get(identity, ownerUserId: '8'), isNull);
      expect(await database.claimDirty('8'), isEmpty);
    });

    test('isolates accounts and adopts guest progress only once', () async {
      final sharedIdentity = ContentIdentity.anime(99);
      await database.saveLocal(
        ownerUserId: 'user-a',
        identity: sharedIdentity,
        subItemId: '第1集',
        payload: const {'positionMs': 100},
        metadata: const {},
        deviceId: 'a',
        clientUpdatedAtMs: 100,
      );
      await database.applyRemote(
        ContentProgressRecord(
          identity: sharedIdentity,
          contentKey: sharedIdentity.contentKey,
          subItemId: '第2集',
          payload: const {'positionMs': 900},
          metadata: const {},
          deviceId: 'b',
          clientUpdatedAtMs: 900,
          deleted: false,
          dirty: false,
        ),
        userId: 'user-b',
      );

      expect(
        (await database.get(
          sharedIdentity,
          ownerUserId: 'user-a',
        ))?.payload['positionMs'],
        100,
      );
      expect(
        (await database.get(
          sharedIdentity,
          ownerUserId: 'user-b',
        ))?.payload['positionMs'],
        900,
      );

      final guestOnly = ContentIdentity.manga('guest-only');
      await database.saveLocal(
        ownerUserId: ProgressOwner.guest,
        identity: guestOnly,
        subItemId: '第1话',
        payload: const {'pageIndex': 3},
        metadata: const {},
        deviceId: 'guest-device',
        clientUpdatedAtMs: 300,
      );
      expect(await database.adoptGuestProgress('user-a'), isTrue);
      expect(await database.adoptGuestProgress('user-b'), isFalse);
      expect(
        await database.get(guestOnly, ownerUserId: ProgressOwner.guest),
        isNull,
      );
      expect(await database.get(guestOnly, ownerUserId: 'user-a'), isNotNull);
      expect(await database.get(guestOnly, ownerUserId: 'user-b'), isNull);
    });

    test('rolls back guest adoption when the session becomes stale', () async {
      final identities = [
        ContentIdentity.manga('guest-race-a'),
        ContentIdentity.manga('guest-race-b'),
      ];
      for (var index = 0; index < identities.length; index++) {
        await database.saveLocal(
          ownerUserId: ProgressOwner.guest,
          identity: identities[index],
          subItemId: '第${index + 1}话',
          payload: {'pageIndex': index},
          metadata: const {},
          deviceId: 'guest-device',
          clientUpdatedAtMs: 400 + index,
        );
      }
      var activeChecks = 0;

      final adopted = await database.adoptGuestProgress(
        'old-user',
        isSessionActive: () {
          activeChecks += 1;
          return activeChecks < 5;
        },
      );

      expect(adopted, isFalse);
      expect(activeChecks, 5);
      for (final identity in identities) {
        expect(
          await database.get(identity, ownerUserId: ProgressOwner.guest),
          isNotNull,
        );
        expect(await database.get(identity, ownerUserId: 'old-user'), isNull);
      }
    });

    test('invalidates an in-flight guest adoption on logout', () async {
      final adoptionDatabase = _BlockingAdoptionDatabase();
      final api = _CountingApi();
      final service = ProgressSyncService(database: adoptionDatabase, api: api);

      service.bindSession(token: 'old-token', userId: 'old-user');
      await adoptionDatabase.started.future;
      service.clearSession();
      adoptionDatabase.release.complete();
      await adoptionDatabase.finished.future;
      await Future<void>.delayed(Duration.zero);

      expect(adoptionDatabase.wasActiveWhenReleased, isFalse);
      expect(api.pullAttempts, 0);
      expect(api.pushAttempts, 0);
      expect(service.activeUserId, isNull);
    });

    test(
      'invalidates the old guest adoption after an account switch',
      () async {
        final adoptionDatabase = _SwitchingAdoptionDatabase();
        final api = _CountingApi();
        final service = ProgressSyncService(
          database: adoptionDatabase,
          api: api,
        );

        service.bindSession(token: 'old-token', userId: 'old-user');
        await adoptionDatabase.firstStarted.future;
        service.bindSession(token: 'new-token', userId: 'new-user');
        await adoptionDatabase.secondStarted.future;

        expect(adoptionDatabase.firstSessionActive?.call(), isFalse);
        expect(adoptionDatabase.secondSessionActive?.call(), isTrue);

        service.clearSession();
        adoptionDatabase.releaseFirst.complete();
        adoptionDatabase.releaseSecond.complete();
        await Future.wait([
          adoptionDatabase.firstFinished.future,
          adoptionDatabase.secondFinished.future,
        ]);
        await Future<void>.delayed(Duration.zero);

        expect(api.pullAttempts, 0);
        expect(api.pushAttempts, 0);
      },
    );

    test(
      'keeps dirty rows after an offline failure and retries them',
      () async {
        final identity = ContentIdentity.manga('retry-me');
        await database.saveLocal(
          ownerUserId: 'user-1',
          identity: identity,
          subItemId: '第3话',
          payload: const {'pageIndex': 2},
          metadata: const {},
          deviceId: 'device-a',
          clientUpdatedAtMs: 100,
        );
        final api = _RetryApi();
        final service = ProgressSyncService(database: database, api: api);

        await expectLater(
          service.syncNow(token: 'token', userId: 'user-1'),
          throwsA(isA<StateError>()),
        );
        expect(await database.claimDirty('user-1'), hasLength(1));

        await service.syncNow(token: 'token', userId: 'user-1');

        expect(api.pushAttempts, 2);
        expect(await database.claimDirty('user-1'), isEmpty);
        expect(await database.getState('progress_cursor_user_user-1'), 'c-1');
        expect(
          await database.getState('progress_cursor_user_another-user'),
          isNull,
        );
      },
    );

    test('retention pruning keeps unsynced rows and tombstones', () async {
      const owner = 'offline-user';
      final dirtyIdentity = ContentIdentity.manga('old-dirty');
      await database.saveLocal(
        ownerUserId: owner,
        identity: dirtyIdentity,
        subItemId: 'chapter-1',
        payload: const {'pageIndex': 1},
        metadata: const {},
        deviceId: 'device-a',
        clientUpdatedAtMs: 100,
      );
      final tombstoneIdentity = ContentIdentity.anime(77);
      await database.deleteLocal(
        tombstoneIdentity,
        ownerUserId: owner,
        deviceId: 'device-a',
        clientUpdatedAtMs: 110,
      );

      await database.pruneVisibleBefore(
        ContentType.manga,
        1000,
        ownerUserId: owner,
      );
      await database.pruneVisibleBefore(
        ContentType.anime,
        1000,
        ownerUserId: owner,
      );

      expect(await database.claimDirty(owner), hasLength(2));
      expect(await database.countRows(ownerUserId: owner), 2);

      final dirty = await database.claimDirty(owner);
      await database.markClean(owner, [
        dirty.firstWhere((item) => item.contentKey == dirtyIdentity.contentKey),
      ]);
      await database.pruneVisibleBefore(
        ContentType.manga,
        1000,
        ownerUserId: owner,
      );
      expect(await database.countRows(ownerUserId: owner), 1);
      expect((await database.claimDirty(owner)).single.deleted, isTrue);
    });
  });
}

ContentProgressRecord _remoteRecord(
  ContentIdentity identity, {
  required int updatedAtMs,
  required bool deleted,
}) {
  return ContentProgressRecord(
    identity: identity,
    contentKey: identity.contentKey,
    subItemId: '第1集',
    payload: const {'positionMs': 1},
    metadata: const {},
    deviceId: 'remote-a',
    clientUpdatedAtMs: updatedAtMs,
    deleted: deleted,
    dirty: false,
  );
}

class _RetryApi implements ProgressSyncApi {
  int pushAttempts = 0;

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
    pushAttempts += 1;
    if (pushAttempts == 1) throw StateError('offline');
    return const ProgressSyncPage(cursor: 'c-1', items: [], hasMore: false);
  }
}

class _BlockingAdoptionDatabase extends ProgressDatabase {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  final Completer<void> finished = Completer<void>();
  bool? wasActiveWhenReleased;

  @override
  Future<bool> adoptGuestProgress(
    String userId, {
    bool Function()? isSessionActive,
  }) async {
    started.complete();
    await release.future;
    wasActiveWhenReleased = isSessionActive?.call();
    finished.complete();
    return false;
  }
}

class _SwitchingAdoptionDatabase extends ProgressDatabase {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> secondStarted = Completer<void>();
  final Completer<void> releaseFirst = Completer<void>();
  final Completer<void> releaseSecond = Completer<void>();
  final Completer<void> firstFinished = Completer<void>();
  final Completer<void> secondFinished = Completer<void>();
  bool Function()? firstSessionActive;
  bool Function()? secondSessionActive;
  int _calls = 0;

  @override
  Future<bool> adoptGuestProgress(
    String userId, {
    bool Function()? isSessionActive,
  }) async {
    _calls += 1;
    if (_calls == 1) {
      firstSessionActive = isSessionActive;
      firstStarted.complete();
      await releaseFirst.future;
      firstFinished.complete();
      return false;
    }
    if (_calls == 2) {
      secondSessionActive = isSessionActive;
      secondStarted.complete();
      await releaseSecond.future;
      secondFinished.complete();
      return false;
    }
    throw StateError('Unexpected adoption call $_calls');
  }
}

class _CountingApi implements ProgressSyncApi {
  int pullAttempts = 0;
  int pushAttempts = 0;

  @override
  Future<ProgressSyncPage> pull({
    required String token,
    required String cursor,
    required int limit,
  }) async {
    pullAttempts += 1;
    return ProgressSyncPage(cursor: cursor, items: const [], hasMore: false);
  }

  @override
  Future<ProgressSyncPage> push({
    required String token,
    required String deviceId,
    required String cursor,
    required List<ContentProgressRecord> items,
  }) async {
    pushAttempts += 1;
    return ProgressSyncPage(cursor: cursor, items: const [], hasMore: false);
  }
}
