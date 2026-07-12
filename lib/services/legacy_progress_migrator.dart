import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/anime_watch_history.dart';
import '../models/content_progress.dart';
import '../models/manga_read_history.dart';
import '../models/novel.dart';
import 'progress_database.dart';

class LegacyProgressMigrator {
  const LegacyProgressMigrator({
    required this.database,
    required this.preferences,
    required this.deviceId,
  });

  static const String animeHistoryKey = 'anime_watch_history';
  static const String mangaHistoryKey = 'manga_read_history';
  static const String bookshelfKey = 'bookshelf';
  static const String readingProgressPrefix = 'progress_';

  final ProgressDatabase database;
  final SharedPreferences preferences;
  final String deviceId;

  Future<bool> migrate() {
    return database.migrateOnce(ProgressDatabase.migrationStateKey, (
      transaction,
    ) async {
      final novels = _readBookshelfNovels();
      for (final key in preferences.getKeys()) {
        if (!key.startsWith(readingProgressPrefix)) continue;
        final novelId = key.substring(readingProgressPrefix.length).trim();
        if (novelId.isEmpty) continue;
        final payload = _decodeMap(preferences.getString(key));
        if (payload == null) continue;
        final novel = novels[novelId];
        final identity = novel == null
            ? ContentIdentity.legacyNovel(novelId)
            : ContentIdentity.novel(novel);
        final updatedAtMs = _readingUpdatedAt(payload);
        await database.insertMigrated(
          transaction,
          ContentProgressRecord(
            identity: identity,
            contentKey: identity.contentKey,
            subItemId: 'chapter:${_asInt(payload['chapterIndex'])}',
            payload: payload,
            metadata: novel == null
                ? const {}
                : {
                    'title': novel.title,
                    'author': novel.author,
                    'coverUrl': novel.coverUrl,
                  },
            deviceId: deviceId,
            clientUpdatedAtMs: updatedAtMs,
            deleted: false,
            dirty: identity.syncEligible,
          ),
        );
      }

      for (final history in _readAnimeHistory()) {
        final identity = ContentIdentity.anime(history.animeId);
        await database.insertMigrated(
          transaction,
          ContentProgressRecord(
            identity: identity,
            contentKey: identity.contentKey,
            subItemId: ContentIdentity.normalizeSubItemId(history.episodeTitle),
            payload: history.toJson(),
            metadata: {'title': history.title, 'coverUrl': history.coverUrl},
            deviceId: deviceId,
            clientUpdatedAtMs: history.updatedAtMs,
            deleted: false,
            dirty: true,
          ),
        );
      }

      for (final history in _readMangaHistory()) {
        final identity = ContentIdentity.manga(history.mangaId);
        await database.insertMigrated(
          transaction,
          ContentProgressRecord(
            identity: identity,
            contentKey: identity.contentKey,
            subItemId: ContentIdentity.normalizeSubItemId(history.chapterTitle),
            payload: history.toJson(),
            metadata: {'title': history.title, 'coverUrl': history.coverUrl},
            deviceId: deviceId,
            clientUpdatedAtMs: history.updatedAtMs,
            deleted: false,
            dirty: true,
          ),
        );
      }
    });
  }

  Map<String, Novel> _readBookshelfNovels() {
    final raw = preferences.getString(bookshelfKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const {};
      final result = <String, Novel>{};
      for (final value in decoded.whereType<Map>()) {
        final novel = _safeNovel(value.cast<String, dynamic>());
        if (novel != null) result[novel.id] = novel;
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  Novel? _safeNovel(Map<String, dynamic> json) {
    try {
      return Novel.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  List<AnimeWatchHistory> _readAnimeHistory() {
    final decoded = _decodeList(preferences.getString(animeHistoryKey));
    return decoded
        .whereType<Map>()
        .map((item) {
          try {
            return AnimeWatchHistory.fromJson(item.cast<String, dynamic>());
          } catch (_) {
            return null;
          }
        })
        .whereType<AnimeWatchHistory>()
        .where((item) => item.animeId > 0)
        .toList(growable: false);
  }

  List<MangaReadHistory> _readMangaHistory() {
    final decoded = _decodeList(preferences.getString(mangaHistoryKey));
    return decoded
        .whereType<Map>()
        .map((item) {
          try {
            return MangaReadHistory.fromJson(item.cast<String, dynamic>());
          } catch (_) {
            return null;
          }
        })
        .whereType<MangaReadHistory>()
        .where((item) => item.mangaId.isNotEmpty)
        .toList(growable: false);
  }

  int _readingUpdatedAt(Map<String, dynamic> payload) {
    final raw = payload['lastReadAt']?.toString() ?? '';
    return DateTime.tryParse(raw)?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
  }

  static Map<String, dynamic>? _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  static List<dynamic> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
