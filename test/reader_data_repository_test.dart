import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/content_progress.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/models/novel_bookmark.dart';
import 'package:novel_app/services/progress_database.dart';
import 'package:novel_app/services/reader_data_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  test('explicit content keys support owner-scoped prefix CRUD', () async {
    const identity = ContentIdentity(
      contentType: ContentType.novel,
      sourceKey: 'reader_settings',
      itemId: 'v1',
    );
    await database.saveLocal(
      ownerUserId: 'user-a',
      identity: identity,
      contentKey: 'reader_settings:v1',
      subItemId: 'settings',
      payload: const {'fontSize': 20},
      metadata: const {},
      deviceId: 'device-a',
      clientUpdatedAtMs: 10,
    );
    await database.saveLocal(
      ownerUserId: 'user-b',
      identity: identity,
      contentKey: 'reader_settings:v1',
      subItemId: 'settings',
      payload: const {'fontSize': 16},
      metadata: const {},
      deviceId: 'device-b',
      clientUpdatedAtMs: 11,
    );

    expect(
      (await database.getByContentKey(
        'reader_settings:v1',
        ownerUserId: 'user-a',
      ))?.payload['fontSize'],
      20,
    );
    expect(
      await database.listByPrefix('reader_settings:', ownerUserId: 'user-a'),
      hasLength(1),
    );

    await database.deleteLocal(
      identity,
      contentKey: 'reader_settings:v1',
      ownerUserId: 'user-a',
      deviceId: 'device-a',
      clientUpdatedAtMs: 12,
    );

    expect(
      await database.listByPrefix('reader_settings:', ownerUserId: 'user-a'),
      isEmpty,
    );
    expect(
      await database.getByContentKey(
        'reader_settings:v1',
        ownerUserId: 'user-b',
      ),
      isNotNull,
    );
  });

  test(
    'legacy reader settings migrate once and stay isolated by owner',
    () async {
      SharedPreferences.setMockInitialValues({
        ReaderSettingsRepository.legacyPreferencesKey: jsonEncode({
          'fontSize': 21.0,
          'fontFamily': 'legacy-serif',
          'brightness': 0.65,
          'useSystemBrightness': false,
        }),
      });
      final preferences = await SharedPreferences.getInstance();
      final repository = ReaderSettingsRepository(
        database: database,
        preferences: preferences,
        deviceIdProvider: () async => 'device-a',
        now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );

      expect(await repository.migrateLegacyIfNeeded(), isTrue);
      expect(await repository.migrateLegacyIfNeeded(), isFalse);
      expect(
        await repository.load(ownerUserId: ProgressOwner.guest),
        containsPair('fontSize', 21.0),
      );
      expect(
        (await repository.load(
          ownerUserId: ProgressOwner.guest,
        ))?['brightness'],
        0.65,
      );
      final guestRecord = await database.getByContentKey(
        ReaderSettingsRepository.contentKey,
        ownerUserId: ProgressOwner.guest,
      );
      expect(guestRecord?.payload.containsKey('brightness'), isFalse);
      expect(guestRecord?.payload.containsKey('useSystemBrightness'), isFalse);

      await database.adoptGuestProgress('user-a');
      expect(
        (await repository.load(ownerUserId: 'user-a'))?['fontFamily'],
        'legacy-serif',
      );
      expect(
        (await repository.load(ownerUserId: 'user-b'))?.containsKey('fontSize'),
        isFalse,
      );

      await repository.save(
        const {
          'fontSize': 17.0,
          'fontFamily': 'account-b-font',
          'brightness': 0.8,
          'useSystemBrightness': true,
        },
        ownerUserId: 'user-b',
        updatedAtMs: 2000,
      );
      expect(await repository.migrateLegacyIfNeeded(), isFalse);
      expect(
        (await repository.load(ownerUserId: 'user-a'))?['fontFamily'],
        'legacy-serif',
      );
      expect(
        (await repository.load(ownerUserId: 'user-b'))?['fontFamily'],
        'account-b-font',
      );
      expect(
        (await repository.load(ownerUserId: 'user-a'))?['brightness'],
        0.8,
        reason: 'brightness is device-local rather than account-synced',
      );
      expect(
        (await repository.load(ownerUserId: 'user-a'))?['useSystemBrightness'],
        isTrue,
        reason: 'the system-brightness toggle is device-local too',
      );
    },
  );

  test(
    'novel bookmarks use stable namespaces and local books stay clean',
    () async {
      final repository = NovelBookmarkRepository(
        database: database,
        deviceIdProvider: () async => 'device-a',
        now: () => DateTime.fromMillisecondsSinceEpoch(3000),
      );
      final online = Novel(
        id: 'book-1',
        title: 'Online book',
        sourceId: 'source-a',
      );
      final onlineIdentity = ContentIdentity.novel(online);
      final bookmark = NovelBookmark(
        id: 'bookmark-1',
        novelContentKey: onlineIdentity.contentKey,
        chapterIndex: 4,
        chapterId: 'chapter-id-4',
        chapterTitle: 'Chapter 4',
        charPosition: 321,
        contextText: 'stable context anchor',
        contentDigest: 'digest-4',
        createdAtMs: 2500,
        updatedAtMs: 3000,
      );
      await repository.save(online, bookmark, ownerUserId: 'user-a');

      final saved = (await repository.list(
        online,
        ownerUserId: 'user-a',
      )).single;
      expect(saved.charPosition, 321);
      expect(saved.contextText, 'stable context anchor');
      expect(
        (await database.claimDirty('user-a')).single.contentKey,
        'novel_bookmark:v1:${onlineIdentity.contentKey}:bookmark-1',
      );
      expect(await repository.list(online, ownerUserId: 'user-b'), isEmpty);

      await repository.delete(
        online,
        bookmark.id,
        ownerUserId: 'user-a',
        updatedAtMs: 4000,
      );
      expect(await repository.list(online, ownerUserId: 'user-a'), isEmpty);

      final local = Novel(id: 'local-book', title: 'Local book', isLocal: true);
      final localIdentity = ContentIdentity.novel(local);
      await repository.save(
        local,
        bookmark.copyWith(
          id: 'local-bookmark',
          novelContentKey: localIdentity.contentKey,
          updatedAtMs: 5000,
        ),
        ownerUserId: 'user-a',
      );
      expect(
        (await repository.list(local, ownerUserId: 'user-a')).single.id,
        'local-bookmark',
      );
      expect(
        (await database.claimDirty(
          'user-a',
        )).where((record) => record.contentKey.contains('local-bookmark')),
        isEmpty,
      );
    },
  );
}
