import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/content_progress.dart';
import '../models/novel.dart';
import '../models/novel_bookmark.dart';
import 'progress_database.dart';

class ReaderSettingsRepository {
  ReaderSettingsRepository({
    required ProgressDatabase database,
    required SharedPreferences preferences,
    required Future<String> Function() deviceIdProvider,
    DateTime Function()? now,
  }) : // Keep the public injection arguments readable for tests.
       // ignore: prefer_initializing_formals
       _database = database,
       // ignore: prefer_initializing_formals
       _preferences = preferences,
       // ignore: prefer_initializing_formals
       _deviceIdProvider = deviceIdProvider,
       _now = now ?? DateTime.now;

  static const String contentKey = 'reader_settings:v1';
  static const String legacyPreferencesKey = 'reading_settings';
  static const String brightnessPreferencesKey = 'reader_brightness:v1';
  static const String systemBrightnessPreferencesKey =
      'reader_use_system_brightness:v1';
  static const String _legacyMigrationStateKey =
      'legacy_reader_settings_migrated_v1';
  static const ContentIdentity _identity = ContentIdentity(
    contentType: ContentType.novel,
    sourceKey: 'reader_settings',
    itemId: 'v1',
  );

  final ProgressDatabase _database;
  final SharedPreferences _preferences;
  final Future<String> Function() _deviceIdProvider;
  final DateTime Function() _now;

  Future<Map<String, dynamic>?> load({required String ownerUserId}) async {
    final record = await _database.getByContentKey(
      contentKey,
      ownerUserId: ownerUserId,
    );
    final brightness = _preferences.getDouble(brightnessPreferencesKey);
    final useSystemBrightness = _preferences.getBool(
      systemBrightnessPreferencesKey,
    );
    if (record == null && brightness == null && useSystemBrightness == null) {
      return null;
    }
    return <String, dynamic>{
      ...?record?.payload,
      // ignore: use_null_aware_elements
      if (brightness != null) 'brightness': brightness,
      // ignore: use_null_aware_elements
      if (useSystemBrightness != null)
        'useSystemBrightness': useSystemBrightness,
    };
  }

  Future<void> save(
    Map<String, dynamic> settings, {
    required String ownerUserId,
    int? updatedAtMs,
  }) async {
    final payload = Map<String, dynamic>.from(settings);
    final brightness = payload.remove('brightness');
    final useSystemBrightness = payload.remove('useSystemBrightness');
    if (brightness is num) {
      await _preferences.setDouble(
        brightnessPreferencesKey,
        brightness.toDouble(),
      );
    }
    if (useSystemBrightness is bool) {
      await _preferences.setBool(
        systemBrightnessPreferencesKey,
        useSystemBrightness,
      );
    }
    await _database.saveLocal(
      ownerUserId: ownerUserId,
      identity: _identity,
      contentKey: contentKey,
      subItemId: 'settings',
      payload: payload,
      metadata: const {'namespace': 'reader_settings', 'version': 1},
      deviceId: await _deviceIdProvider(),
      clientUpdatedAtMs: updatedAtMs ?? _now().millisecondsSinceEpoch,
    );
  }

  Future<bool> migrateLegacyIfNeeded() async {
    return _database.migrateOnce(_legacyMigrationStateKey, (transaction) async {
      final legacyJson = _preferences.getString(legacyPreferencesKey);
      Map<String, dynamic>? legacy;
      if (legacyJson != null && legacyJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(legacyJson);
          if (decoded is Map) legacy = decoded.cast<String, dynamic>();
        } catch (_) {
          // A malformed legacy preference must not block database startup.
        }
      }
      final brightness = legacy?['brightness'];
      final useSystemBrightness = legacy?['useSystemBrightness'];
      if (brightness is num) {
        await _preferences.setDouble(
          brightnessPreferencesKey,
          brightness.toDouble(),
        );
      }
      if (useSystemBrightness is bool) {
        await _preferences.setBool(
          systemBrightnessPreferencesKey,
          useSystemBrightness,
        );
      }
      if (legacy == null) return;
      final payload = Map<String, dynamic>.from(legacy)
        ..remove('brightness')
        ..remove('useSystemBrightness');
      await _database.insertMigrated(
        transaction,
        ContentProgressRecord(
          identity: _identity,
          contentKey: contentKey,
          subItemId: 'settings',
          payload: payload,
          metadata: const {'namespace': 'reader_settings', 'version': 1},
          deviceId: await _deviceIdProvider(),
          clientUpdatedAtMs: _now().millisecondsSinceEpoch,
          deleted: false,
          dirty: true,
        ),
      );
    });
  }
}

class NovelBookmarkRepository {
  NovelBookmarkRepository({
    required ProgressDatabase database,
    required Future<String> Function() deviceIdProvider,
    Uuid? uuid,
    DateTime Function()? now,
  }) : // Keep the public injection arguments readable for tests.
       // ignore: prefer_initializing_formals
       _database = database,
       // ignore: prefer_initializing_formals
       _deviceIdProvider = deviceIdProvider,
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  static const String namespacePrefix = 'novel_bookmark:v1:';

  final ProgressDatabase _database;
  final Future<String> Function() _deviceIdProvider;
  final Uuid _uuid;
  final DateTime Function() _now;

  String prefixFor(ContentIdentity identity) =>
      '$namespacePrefix${identity.contentKey}:';

  String contentKeyFor(ContentIdentity identity, String bookmarkId) {
    final normalizedId = bookmarkId.trim();
    if (normalizedId.isEmpty || normalizedId.contains(':')) {
      throw ArgumentError.value(
        bookmarkId,
        'bookmarkId',
        'must be non-empty and must not contain a colon',
      );
    }
    return '${prefixFor(identity)}$normalizedId';
  }

  Future<List<NovelBookmark>> list(
    Novel novel, {
    required String ownerUserId,
  }) async {
    final identity = ContentIdentity.novel(novel);
    final rows = await _database.listByPrefix(
      prefixFor(identity),
      ownerUserId: ownerUserId,
      type: ContentType.novel,
    );
    return rows
        .map((row) {
          try {
            final bookmark = NovelBookmark.fromJson(row.payload);
            if (bookmark.id.isEmpty ||
                bookmark.novelContentKey != identity.contentKey) {
              return null;
            }
            return bookmark;
          } catch (_) {
            return null;
          }
        })
        .whereType<NovelBookmark>()
        .toList(growable: false);
  }

  Future<NovelBookmark> create({
    required Novel novel,
    required int chapterIndex,
    required String chapterId,
    required String chapterTitle,
    required int charPosition,
    required String contextText,
    required String contentDigest,
    required String ownerUserId,
  }) async {
    final nowMs = _now().millisecondsSinceEpoch;
    final bookmark = NovelBookmark(
      id: _uuid.v4(),
      novelContentKey: ContentIdentity.novel(novel).contentKey,
      chapterIndex: chapterIndex,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      charPosition: charPosition,
      contextText: contextText,
      contentDigest: contentDigest,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
    );
    await save(novel, bookmark, ownerUserId: ownerUserId);
    return bookmark;
  }

  Future<void> save(
    Novel novel,
    NovelBookmark bookmark, {
    required String ownerUserId,
  }) async {
    final identity = ContentIdentity.novel(novel);
    if (bookmark.novelContentKey != identity.contentKey) {
      throw ArgumentError(
        'Bookmark belongs to a different novel content identity',
      );
    }
    await _database.saveLocal(
      ownerUserId: ownerUserId,
      identity: identity,
      contentKey: contentKeyFor(identity, bookmark.id),
      subItemId: 'chapter:${bookmark.chapterIndex}',
      payload: bookmark.toJson(),
      metadata: {
        'title': novel.title,
        'author': novel.author,
        'coverUrl': novel.coverUrl,
        'namespace': 'novel_bookmark',
        'version': 1,
      },
      deviceId: await _deviceIdProvider(),
      clientUpdatedAtMs: bookmark.updatedAtMs,
    );
  }

  Future<void> delete(
    Novel novel,
    String bookmarkId, {
    required String ownerUserId,
    int? updatedAtMs,
  }) async {
    final identity = ContentIdentity.novel(novel);
    await _database.deleteLocal(
      identity,
      contentKey: contentKeyFor(identity, bookmarkId),
      ownerUserId: ownerUserId,
      deviceId: await _deviceIdProvider(),
      clientUpdatedAtMs: updatedAtMs ?? _now().millisecondsSinceEpoch,
    );
  }
}
