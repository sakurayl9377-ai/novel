import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/local_library.dart';
import '../models/novel.dart';
import 'progress_database.dart';

class LegacyLocalLibraryMigrator {
  LegacyLocalLibraryMigrator({
    required ProgressDatabase database,
    required SharedPreferences preferences,
  }) : // Keep the public dependency names readable at call sites.
       // ignore: prefer_initializing_formals
       _database = database,
       // ignore: prefer_initializing_formals
       _preferences = preferences;

  static const String bookshelfKey = 'bookshelf';
  static const String favoriteFoldersKey = 'local_favorite_folders_v1';
  static const String favoriteItemsKey = 'local_favorite_items_v1';
  static const String downloadItemsKey = 'local_download_items_v1';

  final ProgressDatabase _database;
  final SharedPreferences _preferences;

  Future<bool> migrate() {
    return _database.migrateLegacyLocalLibrary(
      bookshelf: _decodeList(bookshelfKey, Novel.fromJson),
      favoriteFolders: _decodeList(favoriteFoldersKey, FavoriteFolder.fromJson),
      favoriteItems: _decodeList(favoriteItemsKey, FavoriteItem.fromJson),
      downloadItems: _decodeList(downloadItemsKey, DownloadItem.fromJson),
    );
  }

  List<T> _decodeList<T>(String key, T Function(Map<String, dynamic>) decode) {
    final raw = _preferences.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <T>[];
      for (final item in decoded.whereType<Map>()) {
        try {
          result.add(decode(item.cast<String, dynamic>()));
        } catch (_) {
          // Preserve the old value and continue migrating valid siblings.
        }
      }
      return result;
    } catch (_) {
      // Old values are intentionally kept for at least this release.
      return const [];
    }
  }
}
