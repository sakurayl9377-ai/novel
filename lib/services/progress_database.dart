import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/content_progress.dart';
import '../models/local_library.dart';
import '../models/novel.dart';

class ProgressDatabase {
  ProgressDatabase({DatabaseFactory? factory, String? path})
    // Keep the public injection argument readable for tests.
    // ignore: prefer_initializing_formals
    : _factory = factory,
      _pathOverride = path;

  static const int schemaVersion = 2;
  static const String migrationStateKey = 'legacy_progress_migrated_v1';
  static const String localLibraryMigrationStateKey =
      'legacy_local_library_migrated_v2';

  final DatabaseFactory? _factory;
  final String? _pathOverride;
  Database? _database;
  Future<void>? _initFuture;

  Future<void> init() => _initFuture ??= _open();

  Future<void> _open() async {
    final factory = _factory ?? databaseFactory;
    final path =
        _pathOverride ?? p.join(await factory.getDatabasesPath(), 'app.db');
    _database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
          // Android's sqflite driver treats journal_mode as a query because it
          // returns the selected mode. Calling execute() here aborts startup
          // before Flutter can render its first frame.
          await database.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (database, version) => _createSchema(database),
        onUpgrade: _upgradeSchema,
      ),
    );
  }

  static Future<void> _createSchema(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE content_progress (
        owner_user_id TEXT NOT NULL DEFAULT 'guest',
        content_key TEXT NOT NULL,
        content_type TEXT NOT NULL,
        source_key TEXT NOT NULL,
        item_id TEXT NOT NULL,
        sub_item_id TEXT NOT NULL DEFAULT '',
        payload_json TEXT NOT NULL DEFAULT '{}',
        metadata_json TEXT NOT NULL DEFAULT '{}',
        device_id TEXT NOT NULL DEFAULT '',
        client_updated_at_ms INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(owner_user_id, content_key)
      )
    ''');
    await database.execute('''
      CREATE INDEX content_progress_type_updated_idx
      ON content_progress(
        owner_user_id, content_type, deleted, client_updated_at_ms DESC
      )
    ''');
    await database.execute('''
      CREATE INDEX content_progress_dirty_idx
      ON content_progress(owner_user_id, dirty, client_updated_at_ms)
    ''');
    await database.execute('''
      CREATE INDEX content_progress_item_idx
      ON content_progress(owner_user_id, content_type, item_id, deleted)
    ''');
    await database.execute('''
      CREATE TABLE sync_state (
        state_key TEXT PRIMARY KEY,
        state_value TEXT NOT NULL
      )
    ''');
    await _createLocalLibrarySchema(database);
  }

  static Future<void> _upgradeSchema(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createLocalLibrarySchema(database);
    }
  }

  static Future<void> _createLocalLibrarySchema(
    DatabaseExecutor database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS bookshelf_items (
        book_id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        source_id TEXT NOT NULL DEFAULT '',
        source_name TEXT NOT NULL DEFAULT '',
        local_path TEXT NOT NULL DEFAULT '',
        chapter_url TEXT NOT NULL DEFAULT '',
        is_local INTEGER NOT NULL DEFAULT 0,
        rating REAL NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT '',
        chapter_count INTEGER NOT NULL DEFAULT 0,
        added_at_ms INTEGER NOT NULL,
        last_read_at_ms INTEGER NOT NULL,
        current_chapter_index INTEGER NOT NULL DEFAULT 0,
        total_chapters INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS bookshelf_last_read_idx
      ON bookshelf_items(last_read_at_ms DESC, added_at_ms DESC)
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS favorite_folders (
        folder_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS favorite_folders_order_idx
      ON favorite_folders(sort_order, created_at_ms, folder_id)
    ''');
    await database.insert('favorite_folders', {
      'folder_id': defaultFavoriteFolderId,
      'name': '默认收藏',
      'created_at_ms': 0,
      'sort_order': -1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await database.execute('''
      CREATE TABLE IF NOT EXISTS favorite_items (
        favorite_id TEXT PRIMARY KEY,
        item_type TEXT NOT NULL,
        item_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        subtitle TEXT NOT NULL DEFAULT '',
        folder_id TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        UNIQUE(item_type, item_id),
        FOREIGN KEY(folder_id) REFERENCES favorite_folders(folder_id)
          ON UPDATE CASCADE ON DELETE RESTRICT
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS favorite_items_folder_order_idx
      ON favorite_items(folder_id, sort_order, created_at_ms DESC)
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS download_items (
        download_id TEXT PRIMARY KEY,
        item_type TEXT NOT NULL,
        item_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        subtitle TEXT NOT NULL DEFAULT '',
        source_name TEXT NOT NULL DEFAULT '',
        episode_title TEXT NOT NULL DEFAULT '',
        episode_url TEXT NOT NULL DEFAULT '',
        chapter_title TEXT NOT NULL DEFAULT '',
        chapter_url TEXT NOT NULL DEFAULT '',
        chapter_index INTEGER NOT NULL DEFAULT 0,
        total_count INTEGER NOT NULL DEFAULT 0,
        cached_count INTEGER NOT NULL DEFAULT 0,
        local_path TEXT NOT NULL DEFAULT '',
        downloaded_bytes INTEGER NOT NULL DEFAULT 0,
        total_bytes INTEGER NOT NULL DEFAULT 0,
        error_message TEXT NOT NULL DEFAULT '',
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        status TEXT NOT NULL,
        queue_index INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS download_items_updated_idx
      ON download_items(updated_at_ms DESC, queue_index, download_id)
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS download_items_queue_idx
      ON download_items(status, queue_index, updated_at_ms)
    ''');
  }

  Database get _db {
    final database = _database;
    if (database == null) {
      throw StateError('ProgressDatabase.init must complete first');
    }
    return database;
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    _initFuture = null;
    await database?.close();
  }

  Future<String?> getState(String key) async {
    await init();
    final rows = await _db.query(
      'sync_state',
      columns: const ['state_value'],
      where: 'state_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['state_value'] as String?;
  }

  Future<void> setState(String key, String value) async {
    await init();
    await _db.insert('sync_state', {
      'state_key': key,
      'state_value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> migrateOnce(
    String marker,
    Future<void> Function(DatabaseExecutor transaction) migration,
  ) async {
    await init();
    return _db.transaction((transaction) async {
      final state = await transaction.query(
        'sync_state',
        columns: const ['state_value'],
        where: 'state_key = ?',
        whereArgs: [marker],
        limit: 1,
      );
      if (state.isNotEmpty) return false;
      await migration(transaction);
      await transaction.insert('sync_state', {
        'state_key': marker,
        'state_value': '1',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  Future<void> insertMigrated(
    DatabaseExecutor transaction,
    ContentProgressRecord record,
  ) {
    return _upsert(
      transaction,
      record.copyWith(ownerUserId: ProgressOwner.guest),
    );
  }

  Future<void> saveLocal({
    required String ownerUserId,
    required ContentIdentity identity,
    String? contentKey,
    required String subItemId,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> metadata,
    required String deviceId,
    required int clientUpdatedAtMs,
    bool ensureNewerTimestamp = false,
  }) async {
    await init();
    final resolvedContentKey = _resolveContentKey(identity, contentKey);

    Future<void> save(DatabaseExecutor executor) async {
      var effectiveUpdatedAtMs = clientUpdatedAtMs;
      if (ensureNewerTimestamp) {
        final rows = await executor.query(
          'content_progress',
          columns: const ['client_updated_at_ms'],
          where: 'owner_user_id = ? AND content_key = ?',
          whereArgs: [ownerUserId, resolvedContentKey],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          final existingUpdatedAtMs =
              (rows.first['client_updated_at_ms'] as num).toInt();
          if (effectiveUpdatedAtMs <= existingUpdatedAtMs) {
            effectiveUpdatedAtMs = existingUpdatedAtMs + 1;
          }
        }
      }
      await _upsert(
        executor,
        ContentProgressRecord(
          identity: identity,
          contentKey: resolvedContentKey,
          subItemId: ContentIdentity.normalizeSubItemId(subItemId),
          payload: payload,
          metadata: metadata,
          deviceId: deviceId,
          clientUpdatedAtMs: effectiveUpdatedAtMs,
          deleted: false,
          dirty: identity.syncEligible,
          ownerUserId: ownerUserId,
        ),
      );
    }

    if (ensureNewerTimestamp) {
      await _db.transaction(save);
    } else {
      await save(_db);
    }
  }

  Future<ContentProgressRecord?> get(
    ContentIdentity identity, {
    required String ownerUserId,
  }) async {
    return getByContentKey(identity.contentKey, ownerUserId: ownerUserId);
  }

  Future<ContentProgressRecord?> getByContentKey(
    String contentKey, {
    required String ownerUserId,
  }) async {
    await init();
    final normalizedContentKey = _normalizeContentKey(contentKey);
    final rows = await _db.query(
      'content_progress',
      where: 'owner_user_id = ? AND content_key = ? AND deleted = 0',
      whereArgs: [ownerUserId, normalizedContentKey],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<ContentProgressRecord?> promoteLegacyNovel(
    ContentIdentity target, {
    required String ownerUserId,
  }) async {
    if (target.contentType != ContentType.novel ||
        target.sourceKey == ContentIdentity.legacyNovelSourceKey) {
      return get(target, ownerUserId: ownerUserId);
    }
    await init();
    return _db.transaction((transaction) async {
      final legacyIdentity = ContentIdentity.legacyNovel(target.itemId);
      final legacyRows = await transaction.query(
        'content_progress',
        where:
            'owner_user_id = ? AND content_key = ? AND source_key = ? AND deleted = 0',
        whereArgs: [
          ownerUserId,
          legacyIdentity.contentKey,
          ContentIdentity.legacyNovelSourceKey,
        ],
        limit: 1,
      );
      if (legacyRows.isEmpty) return null;
      final legacy = _fromRow(legacyRows.first);
      await _upsert(
        transaction,
        ContentProgressRecord(
          identity: target,
          contentKey: target.contentKey,
          subItemId: legacy.subItemId,
          payload: legacy.payload,
          metadata: legacy.metadata,
          deviceId: legacy.deviceId,
          clientUpdatedAtMs: legacy.clientUpdatedAtMs,
          deleted: false,
          dirty: target.syncEligible && legacy.dirty,
          ownerUserId: ownerUserId,
        ),
      );
      await transaction.delete(
        'content_progress',
        where: 'owner_user_id = ? AND content_key = ?',
        whereArgs: [ownerUserId, legacyIdentity.contentKey],
      );
      final promotedRows = await transaction.query(
        'content_progress',
        where: 'owner_user_id = ? AND content_key = ? AND deleted = 0',
        whereArgs: [ownerUserId, target.contentKey],
        limit: 1,
      );
      return promotedRows.isEmpty ? null : _fromRow(promotedRows.first);
    });
  }

  Future<List<ContentProgressRecord>> list(
    ContentType type, {
    required String ownerUserId,
    int? updatedAfterMs,
  }) async {
    await init();
    final rows = await _db.query(
      'content_progress',
      where: updatedAfterMs == null
          ? 'owner_user_id = ? AND content_type = ? AND deleted = 0'
          : 'owner_user_id = ? AND content_type = ? AND deleted = 0 AND client_updated_at_ms >= ?',
      whereArgs: updatedAfterMs == null
          ? [ownerUserId, type.wireName]
          : [ownerUserId, type.wireName, updatedAfterMs],
      orderBy: 'client_updated_at_ms DESC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<List<ContentProgressRecord>> listByPrefix(
    String contentKeyPrefix, {
    required String ownerUserId,
    ContentType? type,
  }) async {
    await init();
    final normalizedPrefix = _normalizeContentKey(contentKeyPrefix);
    final escapedPrefix = normalizedPrefix
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final clauses = <String>[
      'owner_user_id = ?',
      r"content_key LIKE ? ESCAPE '\'",
      'deleted = 0',
    ];
    final whereArgs = <Object?>[ownerUserId, '$escapedPrefix%'];
    if (type != null) {
      clauses.add('content_type = ?');
      whereArgs.add(type.wireName);
    }
    final rows = await _db.query(
      'content_progress',
      where: clauses.join(' AND '),
      whereArgs: whereArgs,
      orderBy: 'client_updated_at_ms DESC, content_key ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<void> deleteLocal(
    ContentIdentity identity, {
    String? contentKey,
    required String ownerUserId,
    required String deviceId,
    required int clientUpdatedAtMs,
  }) async {
    await init();
    final resolvedContentKey = _resolveContentKey(identity, contentKey);
    final existing = await getByContentKey(
      resolvedContentKey,
      ownerUserId: ownerUserId,
    );
    await _upsert(
      _db,
      ContentProgressRecord(
        identity: identity,
        contentKey: resolvedContentKey,
        subItemId: existing?.subItemId ?? '',
        payload: existing?.payload ?? const {},
        metadata: existing?.metadata ?? const {},
        deviceId: deviceId,
        clientUpdatedAtMs: clientUpdatedAtMs,
        deleted: true,
        dirty: identity.syncEligible,
        ownerUserId: ownerUserId,
      ),
    );
  }

  Future<void> deleteAllLocal(
    ContentType type, {
    required String ownerUserId,
    required String deviceId,
    required int clientUpdatedAtMs,
  }) async {
    await init();
    await _db.update(
      'content_progress',
      {
        'device_id': deviceId,
        'client_updated_at_ms': clientUpdatedAtMs,
        'deleted': 1,
        'dirty': 1,
      },
      where: 'owner_user_id = ? AND content_type = ? AND deleted = 0',
      whereArgs: [ownerUserId, type.wireName],
    );
  }

  Future<void> pruneVisibleBefore(
    ContentType type,
    int cutoffMs, {
    required String ownerUserId,
  }) async {
    await init();
    await _db.delete(
      'content_progress',
      where:
          'owner_user_id = ? AND content_type = ? AND deleted = 0 AND dirty = 0 AND client_updated_at_ms < ?',
      whereArgs: [ownerUserId, type.wireName, cutoffMs],
    );
  }

  Future<bool> adoptGuestProgress(
    String userId, {
    bool Function()? isSessionActive,
  }) async {
    if (userId.isEmpty || userId == ProgressOwner.guest) return false;
    await init();
    void ensureSessionActive() {
      if (isSessionActive?.call() == false) {
        throw const _GuestProgressAdoptionCancelled();
      }
    }

    try {
      ensureSessionActive();
      return await _db.transaction((transaction) async {
        ensureSessionActive();
        final rows = await transaction.query(
          'content_progress',
          where: 'owner_user_id = ?',
          whereArgs: [ProgressOwner.guest],
          orderBy: 'client_updated_at_ms ASC',
        );
        ensureSessionActive();
        if (rows.isEmpty) return false;
        for (final row in rows) {
          ensureSessionActive();
          await _upsert(
            transaction,
            _fromRow(row).copyWith(ownerUserId: userId),
          );
          ensureSessionActive();
        }
        await transaction.delete(
          'content_progress',
          where: 'owner_user_id = ?',
          whereArgs: [ProgressOwner.guest],
        );
        ensureSessionActive();
        return true;
      });
    } on _GuestProgressAdoptionCancelled {
      return false;
    }
  }

  Future<List<ContentProgressRecord>> claimDirty(
    String userId, {
    int limit = 100,
  }) async {
    await init();
    final rows = await _db.query(
      'content_progress',
      where: 'owner_user_id = ? AND dirty = 1',
      whereArgs: [userId],
      orderBy: 'client_updated_at_ms ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<void> markClean(
    String userId,
    Iterable<ContentProgressRecord> records,
  ) async {
    await init();
    await _db.transaction((transaction) async {
      for (final record in records) {
        await transaction.update(
          'content_progress',
          {'dirty': 0},
          where:
              'owner_user_id = ? AND content_key = ? AND client_updated_at_ms = ?',
          whereArgs: [userId, record.contentKey, record.clientUpdatedAtMs],
        );
      }
    });
  }

  Future<bool> reconcilePushedWinner({
    required String userId,
    required ContentProgressRecord pushed,
    required ContentProgressRecord winner,
  }) async {
    await init();
    return _db.transaction((transaction) async {
      final rows = await transaction.query(
        'content_progress',
        where: 'owner_user_id = ? AND content_key = ?',
        whereArgs: [userId, pushed.contentKey],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final current = _fromRow(rows.first);
      if (!_sameStoredRecord(current, pushed)) return false;
      final changed = !_sameSyncedValue(current, winner);
      await _replace(
        transaction,
        winner.copyWith(ownerUserId: userId, dirty: false),
      );
      return changed;
    });
  }

  Future<bool> applyRemote(
    ContentProgressRecord remote, {
    required String userId,
  }) async {
    await init();
    return _db.transaction((transaction) async {
      final rows = await transaction.query(
        'content_progress',
        where: 'owner_user_id = ? AND content_key = ?',
        whereArgs: [userId, remote.contentKey],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final local = _fromRow(rows.first);
        if (local.clientUpdatedAtMs > remote.clientUpdatedAtMs) return false;
        if (local.clientUpdatedAtMs == remote.clientUpdatedAtMs &&
            local.deviceId.compareTo(remote.deviceId) > 0) {
          return false;
        }
      }
      await _upsert(
        transaction,
        remote.copyWith(dirty: false, ownerUserId: userId),
      );
      return true;
    });
  }

  Future<bool> migrateLegacyLocalLibrary({
    required List<Novel> bookshelf,
    required List<FavoriteFolder> favoriteFolders,
    required List<FavoriteItem> favoriteItems,
    required List<DownloadItem> downloadItems,
  }) async {
    await init();
    return migrateOnce(localLibraryMigrationStateKey, (transaction) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _upsertFavoriteFolder(
        transaction,
        FavoriteFolder(
          id: defaultFavoriteFolderId,
          name: '默认收藏',
          createdAtMs: now,
        ),
        sortOrder: 0,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      for (var index = 0; index < bookshelf.length; index++) {
        await _upsertBookshelfItem(
          transaction,
          bookshelf[index],
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (var index = 0; index < favoriteFolders.length; index++) {
        final folder = favoriteFolders[index];
        if (folder.id.isEmpty) continue;
        await _upsertFavoriteFolder(
          transaction,
          folder,
          sortOrder: index + 1,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      final folderRows = await transaction.query(
        'favorite_folders',
        columns: const ['folder_id'],
      );
      final folderIds = folderRows
          .map((row) => row['folder_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      for (var index = 0; index < favoriteItems.length; index++) {
        final item = favoriteItems[index];
        if (item.id.isEmpty || item.itemId.isEmpty) continue;
        final normalized = folderIds.contains(item.folderId)
            ? item
            : FavoriteItem(
                id: item.id,
                type: item.type,
                itemId: item.itemId,
                title: item.title,
                coverUrl: item.coverUrl,
                subtitle: item.subtitle,
                folderId: defaultFavoriteFolderId,
                createdAtMs: item.createdAtMs,
              );
        await _upsertFavoriteItem(
          transaction,
          normalized,
          sortOrder: index,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (var index = 0; index < downloadItems.length; index++) {
        final item = downloadItems[index];
        if (item.id.isEmpty || item.itemId.isEmpty) continue;
        await _upsertDownloadItem(
          transaction,
          item,
          queueIndex: index,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> listBookshelf() async {
    await init();
    final rows = await _db.query(
      'bookshelf_items',
      orderBy: 'last_read_at_ms DESC, added_at_ms DESC, book_id',
    );
    return rows.map(_bookshelfFromRow).toList(growable: false);
  }

  Future<void> saveBookshelfItem(Novel novel) async {
    await init();
    await _upsertBookshelfItem(_db, novel);
  }

  Future<void> deleteBookshelfItem(String bookId) async {
    await init();
    await _db.delete(
      'bookshelf_items',
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
  }

  Future<bool> hasBookshelfItem(String bookId) async {
    await init();
    final rows = await _db.query(
      'bookshelf_items',
      columns: const ['book_id'],
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<FavoriteFolder>> listFavoriteFolders() async {
    await init();
    final rows = await _db.query(
      'favorite_folders',
      orderBy: 'sort_order, created_at_ms, folder_id',
    );
    return rows
        .map(
          (row) => FavoriteFolder(
            id: row['folder_id'] as String? ?? '',
            name: row['name'] as String? ?? '',
            createdAtMs: row['created_at_ms'] as int? ?? 0,
          ),
        )
        .toList(growable: false);
  }

  Future<void> saveFavoriteFolder(
    FavoriteFolder folder, {
    int? sortOrder,
  }) async {
    await init();
    final order = sortOrder ?? await _nextSortOrder('favorite_folders');
    await _upsertFavoriteFolder(_db, folder, sortOrder: order);
  }

  Future<void> renameFavoriteFolder(String folderId, String name) async {
    await init();
    await _db.update(
      'favorite_folders',
      {'name': name},
      where: 'folder_id = ?',
      whereArgs: [folderId],
    );
  }

  Future<void> deleteFavoriteFolder(String folderId) async {
    if (folderId == defaultFavoriteFolderId) return;
    await init();
    await _db.transaction((transaction) async {
      await transaction.update(
        'favorite_items',
        {'folder_id': defaultFavoriteFolderId},
        where: 'folder_id = ?',
        whereArgs: [folderId],
      );
      await transaction.delete(
        'favorite_folders',
        where: 'folder_id = ?',
        whereArgs: [folderId],
      );
    });
  }

  Future<List<FavoriteItem>> listFavoriteItems({String? folderId}) async {
    await init();
    final rows = await _db.query(
      'favorite_items',
      where: folderId == null ? null : 'folder_id = ?',
      whereArgs: folderId == null ? null : [folderId],
      orderBy: 'sort_order, created_at_ms DESC, favorite_id',
    );
    return rows.map(_favoriteItemFromRow).toList(growable: false);
  }

  Future<bool> hasFavoriteItem(LibraryItemType type, String itemId) async {
    await init();
    final rows = await _db.query(
      'favorite_items',
      columns: const ['favorite_id'],
      where: 'item_type = ? AND item_id = ?',
      whereArgs: [type.value, itemId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> saveFavoriteItem(FavoriteItem item) async {
    await init();
    await _db.transaction((transaction) async {
      await transaction.delete(
        'favorite_items',
        where: 'item_type = ? AND item_id = ? AND favorite_id != ?',
        whereArgs: [item.type.value, item.itemId, item.id],
      );
      final maxResult = await transaction.rawQuery(
        'SELECT MIN(sort_order) AS min_order FROM favorite_items WHERE folder_id = ?',
        [item.folderId],
      );
      final currentMin = Sqflite.firstIntValue(maxResult) ?? 0;
      await _upsertFavoriteItem(transaction, item, sortOrder: currentMin - 1);
    });
  }

  Future<void> deleteFavoriteItem(LibraryItemType type, String itemId) async {
    await init();
    await _db.delete(
      'favorite_items',
      where: 'item_type = ? AND item_id = ?',
      whereArgs: [type.value, itemId],
    );
  }

  Future<List<DownloadItem>> listDownloadItems() async {
    await init();
    final rows = await _db.query(
      'download_items',
      orderBy: 'updated_at_ms DESC, queue_index, download_id',
    );
    return rows.map(_downloadItemFromRow).toList(growable: false);
  }

  Future<void> saveDownloadItem(DownloadItem item, {int? queueIndex}) async {
    await init();
    await _db.transaction((transaction) async {
      final existing = await transaction.query(
        'download_items',
        columns: const ['queue_index'],
        where: 'download_id = ?',
        whereArgs: [item.id],
        limit: 1,
      );
      final maxResult = existing.isEmpty && queueIndex == null
          ? await transaction.rawQuery(
              'SELECT MAX(queue_index) AS max_order FROM download_items',
            )
          : const <Map<String, Object?>>[];
      final index =
          queueIndex ??
          (existing.isEmpty
              ? (Sqflite.firstIntValue(maxResult) ?? -1) + 1
              : existing.first['queue_index'] as int? ?? 0);
      await _upsertDownloadItem(transaction, item, queueIndex: index);
    });
  }

  Future<void> deleteDownloadItem(String id) async {
    await init();
    await _db.delete(
      'download_items',
      where: 'download_id = ?',
      whereArgs: [id],
    );
  }

  Future<void> clearDownloadItems() async {
    await init();
    await _db.delete('download_items');
  }

  Future<List<DownloadItem>> recoverInterruptedDownloads() async {
    await init();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((transaction) async {
      await transaction.update(
        'download_items',
        {'status': 'queued', 'error_message': '', 'updated_at_ms': now},
        where:
            "status = 'downloading' OR (status = 'saved' AND local_path = '')",
      );
    });
    return listDownloadItems();
  }

  Future<int> pruneDownloadHistory({int maxTerminalItems = 1000}) async {
    await init();
    if (maxTerminalItems < 0) maxTerminalItems = 0;
    return _db.rawDelete(
      '''
      DELETE FROM download_items
      WHERE download_id IN (
        SELECT download_id FROM download_items
        WHERE status IN ('failed', 'cancelled')
          AND local_path = '' AND downloaded_bytes = 0 AND cached_count = 0
        ORDER BY updated_at_ms DESC, queue_index, download_id
        LIMIT -1 OFFSET ?
      )
      ''',
      [maxTerminalItems],
    );
  }

  Future<int> _nextSortOrder(
    String table, {
    String column = 'sort_order',
  }) async {
    final result = await _db.rawQuery(
      'SELECT MAX($column) AS max_order FROM $table',
    );
    return (Sqflite.firstIntValue(result) ?? -1) + 1;
  }

  Future<int> countRows({ContentType? type, String? ownerUserId}) async {
    await init();
    final clauses = <String>[];
    final args = <Object?>[];
    if (type != null) {
      clauses.add('content_type = ?');
      args.add(type.wireName);
    }
    if (ownerUserId != null) {
      clauses.add('owner_user_id = ?');
      args.add(ownerUserId);
    }
    final result = await _db.rawQuery(
      'SELECT COUNT(*) AS count FROM content_progress${clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}'}',
      args,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> _upsert(
    DatabaseExecutor executor,
    ContentProgressRecord record,
  ) async {
    await executor.rawInsert(
      '''
      INSERT INTO content_progress (
        owner_user_id, content_key, content_type, source_key, item_id,
        sub_item_id, payload_json, metadata_json, device_id,
        client_updated_at_ms, deleted, dirty
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(owner_user_id, content_key) DO UPDATE SET
        content_type = excluded.content_type,
        source_key = excluded.source_key,
        item_id = excluded.item_id,
        sub_item_id = excluded.sub_item_id,
        payload_json = excluded.payload_json,
        metadata_json = excluded.metadata_json,
        device_id = excluded.device_id,
        client_updated_at_ms = excluded.client_updated_at_ms,
        deleted = excluded.deleted,
        dirty = excluded.dirty
      WHERE excluded.client_updated_at_ms >= content_progress.client_updated_at_ms
      ''',
      [
        record.ownerUserId,
        record.contentKey,
        record.identity.contentType.wireName,
        record.identity.sourceKey,
        record.identity.itemId,
        record.subItemId,
        jsonEncode(record.payload),
        jsonEncode(record.metadata),
        record.deviceId,
        record.clientUpdatedAtMs,
        record.deleted ? 1 : 0,
        record.dirty ? 1 : 0,
      ],
    );
  }

  Future<void> _replace(
    DatabaseExecutor executor,
    ContentProgressRecord record,
  ) async {
    await executor.rawInsert(
      '''
      INSERT INTO content_progress (
        owner_user_id, content_key, content_type, source_key, item_id,
        sub_item_id, payload_json, metadata_json, device_id,
        client_updated_at_ms, deleted, dirty
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(owner_user_id, content_key) DO UPDATE SET
        content_type = excluded.content_type,
        source_key = excluded.source_key,
        item_id = excluded.item_id,
        sub_item_id = excluded.sub_item_id,
        payload_json = excluded.payload_json,
        metadata_json = excluded.metadata_json,
        device_id = excluded.device_id,
        client_updated_at_ms = excluded.client_updated_at_ms,
        deleted = excluded.deleted,
        dirty = excluded.dirty
      ''',
      [
        record.ownerUserId,
        record.contentKey,
        record.identity.contentType.wireName,
        record.identity.sourceKey,
        record.identity.itemId,
        record.subItemId,
        jsonEncode(record.payload),
        jsonEncode(record.metadata),
        record.deviceId,
        record.clientUpdatedAtMs,
        record.deleted ? 1 : 0,
        record.dirty ? 1 : 0,
      ],
    );
  }

  static String _resolveContentKey(
    ContentIdentity identity,
    String? contentKey,
  ) => _normalizeContentKey(contentKey ?? identity.contentKey);

  static String _normalizeContentKey(String contentKey) {
    final normalized = contentKey.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(contentKey, 'contentKey', 'must not be empty');
    }
    return normalized;
  }

  static bool _sameStoredRecord(
    ContentProgressRecord left,
    ContentProgressRecord right,
  ) {
    return left.contentKey == right.contentKey &&
        left.identity.contentType == right.identity.contentType &&
        left.identity.sourceKey == right.identity.sourceKey &&
        left.identity.itemId == right.identity.itemId &&
        left.subItemId == right.subItemId &&
        jsonEncode(left.payload) == jsonEncode(right.payload) &&
        jsonEncode(left.metadata) == jsonEncode(right.metadata) &&
        left.deviceId == right.deviceId &&
        left.clientUpdatedAtMs == right.clientUpdatedAtMs &&
        left.deleted == right.deleted;
  }

  static bool _sameSyncedValue(
    ContentProgressRecord left,
    ContentProgressRecord right,
  ) {
    return _sameStoredRecord(left, right);
  }

  static Future<void> _upsertBookshelfItem(
    DatabaseExecutor executor,
    Novel novel, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
  }) async {
    final values = <String, Object?>{
      'book_id': novel.id,
      'title': novel.title,
      'author': novel.author,
      'cover_url': novel.coverUrl,
      'description': novel.description,
      'source_id': novel.sourceId,
      'source_name': novel.sourceName,
      'local_path': novel.localPath,
      'chapter_url': novel.chapterUrl,
      'is_local': novel.isLocal ? 1 : 0,
      'rating': novel.rating,
      'status': novel.status,
      'chapter_count': novel.chapterCount,
      'added_at_ms': novel.addedAt.millisecondsSinceEpoch,
      'last_read_at_ms': novel.lastReadAt.millisecondsSinceEpoch,
      'current_chapter_index': novel.currentChapterIndex,
      'total_chapters': novel.totalChapters,
    };
    await executor.insert(
      'bookshelf_items',
      values,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  static Future<void> _upsertFavoriteFolder(
    DatabaseExecutor executor,
    FavoriteFolder folder, {
    required int sortOrder,
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
  }) async {
    if (conflictAlgorithm == ConflictAlgorithm.ignore) {
      await executor.insert('favorite_folders', {
        'folder_id': folder.id,
        'name': folder.name,
        'created_at_ms': folder.createdAtMs,
        'sort_order': sortOrder,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      return;
    }
    await executor.rawInsert(
      '''
      INSERT INTO favorite_folders (
        folder_id, name, created_at_ms, sort_order
      ) VALUES (?, ?, ?, ?)
      ON CONFLICT(folder_id) DO UPDATE SET
        name = excluded.name,
        created_at_ms = excluded.created_at_ms,
        sort_order = excluded.sort_order
      ''',
      [folder.id, folder.name, folder.createdAtMs, sortOrder],
    );
  }

  static Future<void> _upsertFavoriteItem(
    DatabaseExecutor executor,
    FavoriteItem item, {
    required int sortOrder,
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
  }) async {
    await executor.insert('favorite_items', {
      'favorite_id': item.id,
      'item_type': item.type.value,
      'item_id': item.itemId,
      'title': item.title,
      'cover_url': item.coverUrl,
      'subtitle': item.subtitle,
      'folder_id': item.folderId,
      'created_at_ms': item.createdAtMs,
      'sort_order': sortOrder,
    }, conflictAlgorithm: conflictAlgorithm);
  }

  static Future<void> _upsertDownloadItem(
    DatabaseExecutor executor,
    DownloadItem item, {
    required int queueIndex,
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
  }) async {
    final values = _downloadItemToRow(item, queueIndex: queueIndex);
    if (conflictAlgorithm == ConflictAlgorithm.ignore) {
      await executor.insert(
        'download_items',
        values,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return;
    }
    await executor.rawInsert(
      '''
      INSERT INTO download_items (
        download_id, item_type, item_id, title, cover_url, subtitle,
        source_name, episode_title, episode_url, chapter_title, chapter_url,
        chapter_index, total_count, cached_count, local_path,
        downloaded_bytes, total_bytes, error_message, created_at_ms,
        updated_at_ms, status, queue_index
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(download_id) DO UPDATE SET
        item_type = excluded.item_type,
        item_id = excluded.item_id,
        title = excluded.title,
        cover_url = excluded.cover_url,
        subtitle = excluded.subtitle,
        source_name = excluded.source_name,
        episode_title = excluded.episode_title,
        episode_url = excluded.episode_url,
        chapter_title = excluded.chapter_title,
        chapter_url = excluded.chapter_url,
        chapter_index = excluded.chapter_index,
        total_count = excluded.total_count,
        cached_count = excluded.cached_count,
        local_path = excluded.local_path,
        downloaded_bytes = excluded.downloaded_bytes,
        total_bytes = excluded.total_bytes,
        error_message = excluded.error_message,
        created_at_ms = excluded.created_at_ms,
        updated_at_ms = excluded.updated_at_ms,
        status = excluded.status,
        queue_index = excluded.queue_index
      WHERE excluded.updated_at_ms >= download_items.updated_at_ms
      ''',
      [
        values['download_id'],
        values['item_type'],
        values['item_id'],
        values['title'],
        values['cover_url'],
        values['subtitle'],
        values['source_name'],
        values['episode_title'],
        values['episode_url'],
        values['chapter_title'],
        values['chapter_url'],
        values['chapter_index'],
        values['total_count'],
        values['cached_count'],
        values['local_path'],
        values['downloaded_bytes'],
        values['total_bytes'],
        values['error_message'],
        values['created_at_ms'],
        values['updated_at_ms'],
        values['status'],
        values['queue_index'],
      ],
    );
  }

  static Map<String, Object?> _downloadItemToRow(
    DownloadItem item, {
    required int queueIndex,
  }) {
    return {
      'download_id': item.id,
      'item_type': item.type.value,
      'item_id': item.itemId,
      'title': item.title,
      'cover_url': item.coverUrl,
      'subtitle': item.subtitle,
      'source_name': item.sourceName,
      'episode_title': item.episodeTitle,
      'episode_url': item.episodeUrl,
      'chapter_title': item.chapterTitle,
      'chapter_url': item.chapterUrl,
      'chapter_index': item.chapterIndex,
      'total_count': item.totalCount,
      'cached_count': item.cachedCount,
      'local_path': item.localPath,
      'downloaded_bytes': item.downloadedBytes,
      'total_bytes': item.totalBytes,
      'error_message': item.errorMessage,
      'created_at_ms': item.createdAtMs,
      'updated_at_ms': item.updatedAtMs,
      'status': item.status,
      'queue_index': queueIndex,
    };
  }

  static Map<String, dynamic> _bookshelfFromRow(Map<String, Object?> row) {
    return {
      'id': row['book_id'] as String? ?? '',
      'title': row['title'] as String? ?? '',
      'author': row['author'] as String? ?? '',
      'coverUrl': row['cover_url'] as String? ?? '',
      'description': row['description'] as String? ?? '',
      'sourceId': row['source_id'] as String? ?? '',
      'sourceName': row['source_name'] as String? ?? '',
      'localPath': row['local_path'] as String? ?? '',
      'chapterUrl': row['chapter_url'] as String? ?? '',
      'isLocal': row['is_local'] == 1,
      'rating': (row['rating'] as num?)?.toDouble() ?? 0.0,
      'status': row['status'] as String? ?? '',
      'chapterCount': row['chapter_count'] as int? ?? 0,
      'addedAt': DateTime.fromMillisecondsSinceEpoch(
        row['added_at_ms'] as int? ?? 0,
      ).toIso8601String(),
      'lastReadAt': DateTime.fromMillisecondsSinceEpoch(
        row['last_read_at_ms'] as int? ?? 0,
      ).toIso8601String(),
      'currentChapterIndex': row['current_chapter_index'] as int? ?? 0,
      'totalChapters': row['total_chapters'] as int? ?? 0,
    };
  }

  static FavoriteItem _favoriteItemFromRow(Map<String, Object?> row) {
    return FavoriteItem(
      id: row['favorite_id'] as String? ?? '',
      type: LibraryItemType.fromValue(row['item_type'] as String? ?? ''),
      itemId: row['item_id'] as String? ?? '',
      title: row['title'] as String? ?? '',
      coverUrl: row['cover_url'] as String? ?? '',
      subtitle: row['subtitle'] as String? ?? '',
      folderId: row['folder_id'] as String? ?? defaultFavoriteFolderId,
      createdAtMs: row['created_at_ms'] as int? ?? 0,
    );
  }

  static DownloadItem _downloadItemFromRow(Map<String, Object?> row) {
    return DownloadItem(
      id: row['download_id'] as String? ?? '',
      type: LibraryItemType.fromValue(row['item_type'] as String? ?? ''),
      itemId: row['item_id'] as String? ?? '',
      title: row['title'] as String? ?? '',
      coverUrl: row['cover_url'] as String? ?? '',
      subtitle: row['subtitle'] as String? ?? '',
      sourceName: row['source_name'] as String? ?? '',
      episodeTitle: row['episode_title'] as String? ?? '',
      episodeUrl: row['episode_url'] as String? ?? '',
      chapterTitle: row['chapter_title'] as String? ?? '',
      chapterUrl: row['chapter_url'] as String? ?? '',
      chapterIndex: row['chapter_index'] as int? ?? 0,
      totalCount: row['total_count'] as int? ?? 0,
      cachedCount: row['cached_count'] as int? ?? 0,
      localPath: row['local_path'] as String? ?? '',
      downloadedBytes: row['downloaded_bytes'] as int? ?? 0,
      totalBytes: row['total_bytes'] as int? ?? 0,
      errorMessage: row['error_message'] as String? ?? '',
      createdAtMs: row['created_at_ms'] as int? ?? 0,
      updatedAtMs: row['updated_at_ms'] as int? ?? 0,
      status: row['status'] as String? ?? '',
    );
  }

  static ContentProgressRecord _fromRow(Map<String, Object?> row) {
    final type = ContentType.fromWireName(row['content_type'] as String? ?? '');
    if (type == null) throw const FormatException('Invalid content type in DB');
    return ContentProgressRecord(
      identity: ContentIdentity(
        contentType: type,
        sourceKey: row['source_key'] as String? ?? '',
        itemId: row['item_id'] as String? ?? '',
        syncEligible:
            !(type == ContentType.novel &&
                row['source_key'] == ContentIdentity.localNovelSourceKey),
      ),
      contentKey: row['content_key'] as String? ?? '',
      subItemId: row['sub_item_id'] as String? ?? '',
      payload: _decodeMap(row['payload_json']),
      metadata: _decodeMap(row['metadata_json']),
      deviceId: row['device_id'] as String? ?? '',
      clientUpdatedAtMs: row['client_updated_at_ms'] as int? ?? 0,
      deleted: row['deleted'] == 1,
      dirty: row['dirty'] == 1,
      ownerUserId: row['owner_user_id'] as String? ?? ProgressOwner.guest,
    );
  }

  static Map<String, dynamic> _decodeMap(Object? value) {
    if (value is! String || value.isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? decoded.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }
}

class _GuestProgressAdoptionCancelled implements Exception {
  const _GuestProgressAdoptionCancelled();
}
