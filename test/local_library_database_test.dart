import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/local_library.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/services/legacy_local_library_migrator.dart';
import 'package:novel_app/services/progress_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('structured local library database', () {
    late ProgressDatabase database;

    setUp(() async {
      database = ProgressDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      await database.init();
    });

    tearDown(() => database.close());

    test('migrates all legacy lists once and keeps original values', () async {
      final legacyBookshelf = jsonEncode([
        Novel(
          id: 'book-1',
          title: 'Book one',
          addedAt: DateTime.fromMillisecondsSinceEpoch(100),
          lastReadAt: DateTime.fromMillisecondsSinceEpoch(200),
        ).toJson(),
        {'id': 123, 'title': 'malformed sibling'},
      ]);
      final legacyFolders = jsonEncode([
        {'id': 'folder-1', 'name': 'Folder', 'createdAtMs': 100},
      ]);
      final legacyFavorites = jsonEncode([
        {
          'id': 'favorite-1',
          'type': 'anime',
          'itemId': 'anime-1',
          'title': 'Anime',
          'folderId': 'folder-1',
          'createdAtMs': 300,
        },
      ]);
      final legacyDownloads = jsonEncode([
        _download('download-1', updatedAtMs: 400).toJson(),
      ]);
      SharedPreferences.setMockInitialValues({
        LegacyLocalLibraryMigrator.bookshelfKey: legacyBookshelf,
        LegacyLocalLibraryMigrator.favoriteFoldersKey: legacyFolders,
        LegacyLocalLibraryMigrator.favoriteItemsKey: legacyFavorites,
        LegacyLocalLibraryMigrator.downloadItemsKey: legacyDownloads,
      });
      final preferences = await SharedPreferences.getInstance();
      final migrator = LegacyLocalLibraryMigrator(
        database: database,
        preferences: preferences,
      );

      expect(await migrator.migrate(), isTrue);
      expect(await migrator.migrate(), isFalse);

      expect(await database.listBookshelf(), hasLength(1));
      expect(await database.listFavoriteFolders(), hasLength(2));
      expect((await database.listFavoriteItems()).single.folderId, 'folder-1');
      expect(await database.listDownloadItems(), hasLength(1));
      expect(
        preferences.getString(LegacyLocalLibraryMigrator.bookshelfKey),
        legacyBookshelf,
      );
      expect(
        preferences.getString(LegacyLocalLibraryMigrator.favoriteFoldersKey),
        legacyFolders,
      );
      expect(
        preferences.getString(LegacyLocalLibraryMigrator.favoriteItemsKey),
        legacyFavorites,
      );
      expect(
        preferences.getString(LegacyLocalLibraryMigrator.downloadItemsKey),
        legacyDownloads,
      );
    });

    test('updates one bookshelf row and keeps last-read ordering', () async {
      final older = Novel(
        id: 'older',
        title: 'Older',
        addedAt: DateTime.fromMillisecondsSinceEpoch(10),
        lastReadAt: DateTime.fromMillisecondsSinceEpoch(20),
      );
      final newer = Novel(
        id: 'newer',
        title: 'Newer',
        addedAt: DateTime.fromMillisecondsSinceEpoch(30),
        lastReadAt: DateTime.fromMillisecondsSinceEpoch(40),
      );
      await database.saveBookshelfItem(older);
      await database.saveBookshelfItem(newer);
      await database.saveBookshelfItem(
        older.copyWith(
          title: 'Updated older',
          lastReadAt: DateTime.fromMillisecondsSinceEpoch(50),
        ),
      );

      final rows = await database.listBookshelf();
      expect(rows.map((item) => item['id']), ['older', 'newer']);
      expect(rows.first['title'], 'Updated older');
      expect(rows.last['title'], 'Newer');
    });

    test('concurrent download saves cannot overwrite newer rows', () async {
      final unrelated = _download('unrelated', updatedAtMs: 5);
      await database.saveDownloadItem(unrelated);
      await Future.wait([
        database.saveDownloadItem(
          _download('same', updatedAtMs: 30, downloadedBytes: 300),
        ),
        database.saveDownloadItem(
          _download('same', updatedAtMs: 10, downloadedBytes: 100),
        ),
        database.saveDownloadItem(
          _download('same', updatedAtMs: 20, downloadedBytes: 200),
        ),
      ]);

      final rows = await database.listDownloadItems();
      final same = rows.singleWhere((item) => item.id == 'same');
      expect(same.updatedAtMs, 30);
      expect(same.downloadedBytes, 300);
      final persistedUnrelated = rows.singleWhere(
        (item) => item.id == 'unrelated',
      );
      expect(persistedUnrelated.updatedAtMs, unrelated.updatedAtMs);
      expect(persistedUnrelated.itemId, unrelated.itemId);
    });

    test(
      'recovers interrupted downloads without resuming paused rows',
      () async {
        await database.saveDownloadItem(
          _download('running', updatedAtMs: 10, status: 'downloading'),
        );
        await database.saveDownloadItem(
          _download('paused', updatedAtMs: 20, status: 'paused'),
        );
        await database.saveDownloadItem(
          _download('done', updatedAtMs: 30, status: 'done'),
        );
        await database.saveDownloadItem(
          _download(
            'manga',
            updatedAtMs: 40,
            status: 'done',
            type: LibraryItemType.manga,
          ),
        );

        final recovered = await database.recoverInterruptedDownloads();

        expect(
          recovered.singleWhere((item) => item.id == 'running').status,
          'queued',
        );
        expect(
          recovered.singleWhere((item) => item.id == 'paused').status,
          'paused',
        );
        expect(
          recovered.singleWhere((item) => item.id == 'done').status,
          'done',
        );
        expect(
          recovered.singleWhere((item) => item.id == 'manga').status,
          'done',
        );
      },
    );

    test(
      'deleting a folder preserves favorites through the foreign key',
      () async {
        await database.saveFavoriteFolder(
          const FavoriteFolder(id: 'folder-1', name: 'Folder', createdAtMs: 10),
        );
        await database.saveFavoriteItem(
          const FavoriteItem(
            id: 'favorite-1',
            type: LibraryItemType.manga,
            itemId: 'manga-1',
            title: 'Manga',
            coverUrl: '',
            folderId: 'folder-1',
            createdAtMs: 20,
          ),
        );

        await database.deleteFavoriteFolder('folder-1');

        expect(
          (await database.listFavoriteItems()).single.folderId,
          defaultFavoriteFolderId,
        );
        expect(
          (await database.listFavoriteFolders()).map((item) => item.id),
          isNot(contains('folder-1')),
        );
      },
    );

    test('queries favorites by folder and explicit item order', () async {
      await database.saveFavoriteFolder(
        const FavoriteFolder(id: 'folder-1', name: 'Folder', createdAtMs: 10),
      );
      const first = FavoriteItem(
        id: 'favorite-1',
        type: LibraryItemType.novel,
        itemId: 'book-1',
        title: 'First',
        coverUrl: '',
        folderId: 'folder-1',
        createdAtMs: 20,
      );
      const second = FavoriteItem(
        id: 'favorite-2',
        type: LibraryItemType.anime,
        itemId: 'anime-2',
        title: 'Second',
        coverUrl: '',
        folderId: 'folder-1',
        createdAtMs: 30,
      );
      await database.saveFavoriteItem(first);
      await database.saveFavoriteItem(second);

      expect(
        (await database.listFavoriteItems(
          folderId: 'folder-1',
        )).map((item) => item.id),
        ['favorite-2', 'favorite-1'],
      );
      expect(
        await database.listFavoriteItems(folderId: defaultFavoriteFolderId),
        isEmpty,
      );
    });

    test('prunes only excess failed download history', () async {
      for (var index = 0; index < 5; index++) {
        await database.saveDownloadItem(
          _download('failed-$index', updatedAtMs: index, status: 'failed'),
        );
      }
      await database.saveDownloadItem(
        _download('active', updatedAtMs: 100, status: 'queued'),
      );

      expect(await database.pruneDownloadHistory(maxTerminalItems: 2), 3);
      final rows = await database.listDownloadItems();
      expect(rows.map((item) => item.id), contains('active'));
      expect(rows.where((item) => item.status == 'failed'), hasLength(2));
    });

    test('deletes one download row and clears the queue atomically', () async {
      await database.saveDownloadItem(_download('one', updatedAtMs: 1));
      await database.saveDownloadItem(_download('two', updatedAtMs: 2));

      await database.deleteDownloadItem('one');
      expect((await database.listDownloadItems()).single.id, 'two');

      await database.clearDownloadItems();
      expect(await database.listDownloadItems(), isEmpty);
    });
  });

  test('upgrades the existing app.db schema in place', () async {
    final directory = await Directory.systemTemp.createTemp(
      'novel-db-upgrade-',
    );
    final path = '${directory.path}${Platform.pathSeparator}app.db';
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE sync_state (
              state_key TEXT PRIMARY KEY,
              state_value TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacy.close();
    final upgraded = ProgressDatabase(factory: databaseFactoryFfi, path: path);
    try {
      await upgraded.init();
      expect(await upgraded.listBookshelf(), isEmpty);
      expect(
        (await upgraded.listFavoriteFolders()).single.id,
        defaultFavoriteFolderId,
      );
      expect(await upgraded.listDownloadItems(), isEmpty);
    } finally {
      await upgraded.close();
      await directory.delete(recursive: true);
    }
  });
}

DownloadItem _download(
  String id, {
  required int updatedAtMs,
  int downloadedBytes = 0,
  String status = 'queued',
  LibraryItemType type = LibraryItemType.anime,
}) {
  return DownloadItem(
    id: id,
    type: type,
    itemId: 'anime-$id',
    title: id,
    coverUrl: '',
    episodeUrl: 'https://example.com/$id.mp4',
    createdAtMs: 1,
    updatedAtMs: updatedAtMs,
    downloadedBytes: downloadedBytes,
    status: status,
  );
}
