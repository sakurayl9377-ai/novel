import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/anime_watch_history.dart';
import '../models/chapter.dart';
import '../models/content_progress.dart';
import '../models/local_library.dart';
import '../models/manga_read_history.dart';
import '../models/novel.dart';
import '../models/novel_bookmark.dart';
import '../models/reading_progress.dart';
import 'legacy_local_library_migrator.dart';
import 'legacy_progress_migrator.dart';
import 'novel_offline_cache_service.dart';
import 'progress_sync_service.dart';
import 'reader_data_repository.dart';

class StorageService {
  static const String _bookSourcesKey = 'book_sources';
  static const String _ttsSettingsKey = 'tts_settings';
  static const Duration _animeWatchHistoryRetention = Duration(days: 30);
  static const Duration _mangaReadHistoryRetention = Duration(days: 30);

  late SharedPreferences _prefs;
  String? _dataDirPath;
  Future<void>? _initFuture;
  bool _didMigrateLegacyProgress = false;
  bool _didMigrateLegacyLocalLibrary = false;
  int _lastChapterCachePruneAtMs = 0;
  int _downloadWritesSincePrune = 0;
  late ReaderSettingsRepository _readerSettingsRepository;
  late NovelBookmarkRepository _novelBookmarkRepository;
  late NovelOfflineCacheService _novelOfflineCacheService;
  static const int _chapterCacheMaxFiles = 3000;
  static const int _chapterCacheMaxBytes = 300 * 1024 * 1024;
  static const Duration _chapterCacheMaxAge = Duration(days: 90);
  static const Duration _chapterCachePruneInterval = Duration(hours: 6);

  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  bool get didMigrateLegacyProgress => _didMigrateLegacyProgress;
  bool get didMigrateLegacyLocalLibrary => _didMigrateLegacyLocalLibrary;

  Future<void> init() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    _prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    _dataDirPath = '${dir.path}/novel_app';
    final dataDir = Directory(_dataDirPath!);
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    _novelOfflineCacheService = NovelOfflineCacheService(dataDir);
    await appProgressDatabase.init();
    final deviceId = await ProgressSyncService.instance.getDeviceId();
    _readerSettingsRepository = ReaderSettingsRepository(
      database: appProgressDatabase,
      preferences: _prefs,
      deviceIdProvider: ProgressSyncService.instance.getDeviceId,
    );
    _novelBookmarkRepository = NovelBookmarkRepository(
      database: appProgressDatabase,
      deviceIdProvider: ProgressSyncService.instance.getDeviceId,
    );
    await _readerSettingsRepository.migrateLegacyIfNeeded();
    _didMigrateLegacyProgress = await LegacyProgressMigrator(
      database: appProgressDatabase,
      preferences: _prefs,
      deviceId: deviceId,
    ).migrate();
    _didMigrateLegacyLocalLibrary = await LegacyLocalLibraryMigrator(
      database: appProgressDatabase,
      preferences: _prefs,
    ).migrate();
  }

  // ============ 书架存储 ============

  String? getString(String key) => _prefs.getString(key);

  Future<bool> setString(String key, String value) {
    return _prefs.setString(key, value);
  }

  Future<bool> remove(String key) {
    return _prefs.remove(key);
  }

  Future<List<Map<String, dynamic>>> getBookshelf() async {
    await init();
    return appProgressDatabase.listBookshelf();
  }

  Future<void> saveBookToShelf(Map<String, dynamic> bookData) async {
    await init();
    await appProgressDatabase.saveBookshelfItem(Novel.fromJson(bookData));
  }

  Future<void> removeBookFromShelf(String bookId) async {
    await init();
    await appProgressDatabase.deleteBookshelfItem(bookId);
  }

  Future<bool> isBookOnShelf(String bookId) async {
    await init();
    return appProgressDatabase.hasBookshelfItem(bookId);
  }

  Future<List<FavoriteFolder>> getFavoriteFolders() async {
    await init();
    var folders = await appProgressDatabase.listFavoriteFolders();
    if (folders.every((item) => item.id != defaultFavoriteFolderId)) {
      await appProgressDatabase.saveFavoriteFolder(
        FavoriteFolder(
          id: defaultFavoriteFolderId,
          name: '默认收藏',
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        sortOrder: -1,
      );
      folders = await appProgressDatabase.listFavoriteFolders();
    }
    return folders;
  }

  Future<FavoriteFolder> createFavoriteFolder(String name) async {
    await init();
    final trimmed = name.trim();
    final folder = FavoriteFolder(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: trimmed.isEmpty ? '新收藏夹' : trimmed,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await appProgressDatabase.saveFavoriteFolder(folder);
    return folder;
  }

  Future<void> renameFavoriteFolder(String folderId, String name) async {
    if (folderId == defaultFavoriteFolderId) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await init();
    await appProgressDatabase.renameFavoriteFolder(folderId, trimmed);
  }

  Future<void> deleteFavoriteFolder(String folderId) async {
    if (folderId == defaultFavoriteFolderId) return;
    await init();
    await appProgressDatabase.deleteFavoriteFolder(folderId);
  }

  Future<List<FavoriteItem>> getFavoriteItems({String? folderId}) async {
    await init();
    return appProgressDatabase.listFavoriteItems(folderId: folderId);
  }

  Future<bool> isFavorite(LibraryItemType type, String itemId) async {
    await init();
    return appProgressDatabase.hasFavoriteItem(type, itemId);
  }

  Future<void> saveFavoriteItem(FavoriteItem item) async {
    await init();
    final folderExists = (await appProgressDatabase.listFavoriteFolders()).any(
      (folder) => folder.id == item.folderId,
    );
    final normalized = folderExists
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
    await appProgressDatabase.saveFavoriteItem(normalized);
  }

  Future<void> removeFavoriteItem(LibraryItemType type, String itemId) async {
    await init();
    await appProgressDatabase.deleteFavoriteItem(type, itemId);
  }

  Future<List<DownloadItem>> getDownloadItems() async {
    await init();
    return appProgressDatabase.listDownloadItems();
  }

  Future<List<DownloadItem>> recoverDownloadItems() async {
    await init();
    return appProgressDatabase.recoverInterruptedDownloads();
  }

  Future<void> saveDownloadItem(DownloadItem item) async {
    await init();
    await appProgressDatabase.saveDownloadItem(item);
    _downloadWritesSincePrune += 1;
    if (_downloadWritesSincePrune >= 100) {
      _downloadWritesSincePrune = 0;
      unawaited(appProgressDatabase.pruneDownloadHistory());
    }
  }

  Future<void> deleteDownloadItem(String id) async {
    await init();
    await appProgressDatabase.deleteDownloadItem(id);
  }

  Future<void> clearDownloadItems() async {
    await init();
    await appProgressDatabase.clearDownloadItems();
  }

  // ============ 书源存储 ============

  Future<List<Map<String, dynamic>>> getBookSources() async {
    final jsonStr = _prefs.getString(_bookSourcesKey);
    if (jsonStr == null) return [];
    final list = jsonDecode(jsonStr) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> saveBookSource(Map<String, dynamic> sourceData) async {
    final sources = await getBookSources();
    final index = sources.indexWhere((s) => s['id'] == sourceData['id']);
    if (index >= 0) {
      sources[index] = sourceData;
    } else {
      sources.add(sourceData);
    }
    await _prefs.setString(_bookSourcesKey, jsonEncode(sources));
  }

  Future<void> deleteBookSource(String sourceId) async {
    final sources = await getBookSources();
    sources.removeWhere((s) => s['id'] == sourceId);
    await _prefs.setString(_bookSourcesKey, jsonEncode(sources));
  }

  // ============ 阅读设置 ============

  Future<Map<String, dynamic>?> getReadingSettings() async {
    await init();
    return _readerSettingsRepository.load(
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
    );
  }

  Future<void> saveReadingSettings(Map<String, dynamic> settings) async {
    await init();
    await _readerSettingsRepository.save(
      settings,
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  Future<List<NovelBookmark>> getNovelBookmarks(Novel novel) async {
    await init();
    return _novelBookmarkRepository.list(
      novel,
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
    );
  }

  Future<NovelBookmark> createNovelBookmark({
    required Novel novel,
    required int chapterIndex,
    required String chapterId,
    required String chapterTitle,
    required int charPosition,
    required String contextText,
    required String contentDigest,
  }) async {
    await init();
    final bookmark = await _novelBookmarkRepository.create(
      novel: novel,
      chapterIndex: chapterIndex,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      charPosition: charPosition,
      contextText: contextText,
      contentDigest: contentDigest,
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
    );
    ProgressSyncService.instance.notifyLocalMutation();
    return bookmark;
  }

  Future<void> saveNovelBookmark(Novel novel, NovelBookmark bookmark) async {
    await init();
    await _novelBookmarkRepository.save(
      novel,
      bookmark,
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  Future<void> deleteNovelBookmark(Novel novel, String bookmarkId) async {
    await init();
    await _novelBookmarkRepository.delete(
      novel,
      bookmarkId,
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  // ============ 语音朗读设置 ============

  Future<Map<String, dynamic>?> getTtsSettings() async {
    final jsonStr = _prefs.getString(_ttsSettingsKey);
    if (jsonStr == null) return null;
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  Future<void> saveTtsSettings(Map<String, dynamic> settings) async {
    await _prefs.setString(_ttsSettingsKey, jsonEncode(settings));
  }

  // ============ 阅读进度 ============

  Future<Map<String, dynamic>?> getReadingProgress(String novelId) async {
    return _getNovelProgress(ContentIdentity.legacyNovel(novelId));
  }

  Future<Map<String, dynamic>?> getNovelReadingProgress(Novel novel) {
    return _getNovelProgress(ContentIdentity.novel(novel));
  }

  Future<List<NovelReadingHistory>> getNovelReadingHistory() async {
    await init();
    final rows = await appProgressDatabase.list(
      ContentType.novel,
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
    );
    final historiesByContentKey = <String, NovelReadingHistory>{};
    for (final row in rows) {
      try {
        final payload = ReadingProgress.fromJson(row.payload);
        final title = row.metadata['title']?.toString() ?? '';
        if (payload.novelId.isEmpty || title.isEmpty) continue;
        final sourceId = row.metadata['sourceId']?.toString() ?? '';
        final canonicalKey = ContentIdentity.novel(
          Novel(
            id: payload.novelId,
            title: title,
            sourceId: sourceId,
            chapterUrl: payload.chapterUrl,
          ),
        ).contentKey;
        final candidate = NovelReadingHistory(
          novelId: payload.novelId,
          title: title,
          author: row.metadata['author']?.toString() ?? '',
          coverUrl: row.metadata['coverUrl']?.toString() ?? '',
          sourceId: sourceId,
          sourceName: row.metadata['sourceName']?.toString() ?? '',
          chapterIndex: payload.chapterIndex,
          chapterTitle: payload.chapterTitle,
          chapterUrl: payload.chapterUrl,
          charPosition: payload.charPosition,
          scrollPosition: payload.scrollPosition,
          lastReadAt: payload.lastReadAt,
        );
        final existing = historiesByContentKey[canonicalKey];
        final candidateIsAhead =
            existing == null ||
            candidate.chapterIndex > existing.chapterIndex ||
            (candidate.chapterIndex == existing.chapterIndex &&
                candidate.charPosition > existing.charPosition) ||
            (candidate.chapterIndex == existing.chapterIndex &&
                candidate.charPosition == existing.charPosition &&
                candidate.lastReadAt.isAfter(existing.lastReadAt));
        if (candidateIsAhead) {
          historiesByContentKey[canonicalKey] = candidate;
        }
      } catch (_) {
        continue;
      }
    }
    final histories = historiesByContentKey.values.toList(growable: false);
    histories.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    return histories;
  }

  Future<Map<String, dynamic>?> _getNovelProgress(
    ContentIdentity identity,
  ) async {
    await init();
    final owner = ProgressSyncService.instance.activeOwnerUserId;
    final exact = await appProgressDatabase.get(identity, ownerUserId: owner);
    final canonicalToken = ContentIdentity.canonicalOnlineNovelToken(identity);
    if (canonicalToken != null) {
      final rows = await appProgressDatabase.list(
        ContentType.novel,
        ownerUserId: owner,
      );
      final candidates =
          <({ContentProgressRecord row, ReadingProgress progress})>[];
      for (final row in rows) {
        var matches = row.contentKey == identity.contentKey;
        final payloadNovelId = row.payload['novelId']?.toString() ?? '';
        matches =
            matches ||
            ContentIdentity.canonicalOnlineNovelTokenFromLegacyId(
                  payloadNovelId,
                ) ==
                canonicalToken;
        if (!matches) continue;
        try {
          candidates.add((
            row: row,
            progress: ReadingProgress.fromJson(row.payload),
          ));
        } catch (_) {
          continue;
        }
      }
      if (candidates.isNotEmpty) {
        final winner = candidates.reduce((best, candidate) {
          return candidate.row.clientUpdatedAtMs > best.row.clientUpdatedAtMs
              ? candidate
              : best;
        });
        if (exact?.contentKey != winner.row.contentKey ||
            exact?.payload.toString() != winner.row.payload.toString()) {
          await appProgressDatabase.saveLocal(
            ownerUserId: owner,
            identity: identity,
            subItemId: winner.row.subItemId,
            payload: winner.row.payload,
            metadata: winner.row.metadata,
            deviceId: await ProgressSyncService.instance.getDeviceId(),
            clientUpdatedAtMs: winner.row.clientUpdatedAtMs,
          );
          ProgressSyncService.instance.notifyLocalMutation();
        }
        return winner.row.payload;
      }
    }
    if (exact != null) return exact.payload;
    final fallback = await appProgressDatabase.promoteLegacyNovel(
      identity,
      ownerUserId: owner,
    );
    if (fallback != null) return fallback.payload;
    return null;
  }

  Future<void> saveReadingProgress(
    String novelId,
    Map<String, dynamic> progress,
  ) async {
    await _saveNovelProgress(
      ContentIdentity.legacyNovel(novelId),
      progress,
      metadata: const {},
    );
  }

  Future<void> saveNovelReadingProgress(
    Novel novel,
    Map<String, dynamic> progress,
  ) {
    return _saveNovelProgress(
      ContentIdentity.novel(novel),
      progress,
      metadata: {
        'title': novel.title,
        'author': novel.author,
        'coverUrl': novel.coverUrl,
        'sourceId': novel.sourceId,
        'sourceName': novel.sourceName,
      },
    );
  }

  Future<void> _saveNovelProgress(
    ContentIdentity identity,
    Map<String, dynamic> progress, {
    required Map<String, dynamic> metadata,
  }) async {
    await init();
    final effectiveProgress = Map<String, dynamic>.of(progress);
    final updatedAtMs =
        DateTime.tryParse(
          effectiveProgress['lastReadAt']?.toString() ?? '',
        )?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    await appProgressDatabase.saveLocal(
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
      identity: identity,
      subItemId: 'chapter:${_asInt(effectiveProgress['chapterIndex'])}',
      payload: effectiveProgress,
      metadata: metadata,
      deviceId: await ProgressSyncService.instance.getDeviceId(),
      clientUpdatedAtMs: updatedAtMs,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  // ============ 动漫播放历史 ============

  Future<List<AnimeWatchHistory>> getAnimeWatchHistory() async {
    await init();
    final cutoff = DateTime.now()
        .subtract(_animeWatchHistoryRetention)
        .millisecondsSinceEpoch;
    final owner = ProgressSyncService.instance.activeOwnerUserId;
    await appProgressDatabase.pruneVisibleBefore(
      ContentType.anime,
      cutoff,
      ownerUserId: owner,
    );
    final rows = await appProgressDatabase.list(
      ContentType.anime,
      ownerUserId: owner,
      updatedAfterMs: cutoff,
    );
    return rows
        .map((row) {
          try {
            return AnimeWatchHistory.fromJson(row.payload);
          } catch (_) {
            return null;
          }
        })
        .whereType<AnimeWatchHistory>()
        .where(_isRecentAnimeHistory)
        .toList(growable: false);
  }

  Future<void> saveAnimeWatchHistory(AnimeWatchHistory history) async {
    if (history.animeId <= 0 ||
        history.title.isEmpty ||
        history.episodeUrl.isEmpty) {
      return;
    }
    await init();
    await appProgressDatabase.saveLocal(
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
      identity: ContentIdentity.anime(history.animeId),
      subItemId: history.episodeTitle,
      payload: history.toJson(),
      metadata: {'title': history.title, 'coverUrl': history.coverUrl},
      deviceId: await ProgressSyncService.instance.getDeviceId(),
      clientUpdatedAtMs: history.updatedAtMs,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  Future<void> clearAnimeWatchHistory() async {
    await init();
    await appProgressDatabase.deleteAllLocal(
      ContentType.anime,
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
      deviceId: await ProgressSyncService.instance.getDeviceId(),
      clientUpdatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  Future<void> deleteAnimeWatchHistory(int animeId) async {
    await init();
    await appProgressDatabase.deleteLocal(
      ContentIdentity.anime(animeId),
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
      deviceId: await ProgressSyncService.instance.getDeviceId(),
      clientUpdatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  bool _isRecentAnimeHistory(AnimeWatchHistory history) {
    final cutoff = DateTime.now()
        .subtract(_animeWatchHistoryRetention)
        .millisecondsSinceEpoch;
    return history.updatedAtMs >= cutoff;
  }

  // ============ 漫画阅读历史 ============

  Future<List<MangaReadHistory>> getMangaReadHistory() async {
    await init();
    final cutoff = DateTime.now()
        .subtract(_mangaReadHistoryRetention)
        .millisecondsSinceEpoch;
    final owner = ProgressSyncService.instance.activeOwnerUserId;
    await appProgressDatabase.pruneVisibleBefore(
      ContentType.manga,
      cutoff,
      ownerUserId: owner,
    );
    final rows = await appProgressDatabase.list(
      ContentType.manga,
      ownerUserId: owner,
      updatedAfterMs: cutoff,
    );
    return rows
        .map((row) {
          try {
            return MangaReadHistory.fromJson(row.payload);
          } catch (_) {
            return null;
          }
        })
        .whereType<MangaReadHistory>()
        .where(_isRecentMangaHistory)
        .toList(growable: false);
  }

  Future<void> saveMangaReadHistory(MangaReadHistory history) async {
    if (history.mangaId.isEmpty ||
        history.title.isEmpty ||
        history.chapterUrl.isEmpty) {
      return;
    }
    await init();
    await appProgressDatabase.saveLocal(
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
      identity: ContentIdentity.manga(history.mangaId),
      subItemId: history.chapterTitle,
      payload: history.toJson(),
      metadata: {'title': history.title, 'coverUrl': history.coverUrl},
      deviceId: await ProgressSyncService.instance.getDeviceId(),
      clientUpdatedAtMs: history.updatedAtMs,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  Future<void> clearMangaReadHistory() async {
    await init();
    await appProgressDatabase.deleteAllLocal(
      ContentType.manga,
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
      deviceId: await ProgressSyncService.instance.getDeviceId(),
      clientUpdatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  Future<void> deleteMangaReadHistory(String mangaId) async {
    await init();
    await appProgressDatabase.deleteLocal(
      ContentIdentity.manga(mangaId),
      ownerUserId: ProgressSyncService.instance.activeOwnerUserId,
      deviceId: await ProgressSyncService.instance.getDeviceId(),
      clientUpdatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    ProgressSyncService.instance.notifyLocalMutation();
  }

  bool _isRecentMangaHistory(MangaReadHistory history) {
    final cutoff = DateTime.now()
        .subtract(_mangaReadHistoryRetention)
        .millisecondsSinceEpoch;
    return history.updatedAtMs >= cutoff;
  }

  // ============ 章节目录缓存 ============

  Future<void> saveNovelChapterList(
    Novel novel,
    List<Map<String, dynamic>> chapters,
  ) async {
    await init();
    await _novelOfflineCacheService.saveTemporaryChapterList(novel, chapters);
    unawaited(_pruneChapterCacheIfNeeded());
  }

  Future<List<Map<String, dynamic>>?> getNovelChapterList(Novel novel) async {
    await init();
    return _novelOfflineCacheService.getTemporaryChapterList(novel);
  }

  Future<void> saveTemporaryNovelChapterContent(
    Novel novel,
    Chapter chapter,
    String content,
  ) async {
    await init();
    await _novelOfflineCacheService.saveTemporaryChapterContent(
      novel,
      chapter,
      content,
    );
    unawaited(_pruneChapterCacheIfNeeded());
  }

  Future<String?> getTemporaryNovelChapterContent(
    Novel novel,
    Chapter chapter,
  ) async {
    await init();
    return _novelOfflineCacheService.getTemporaryChapterContent(novel, chapter);
  }

  Future<void> deleteTemporaryNovelChapterContent(
    Novel novel,
    Chapter chapter,
  ) async {
    await init();
    await _novelOfflineCacheService.deleteTemporaryChapterContent(
      novel,
      chapter,
    );
  }

  Future<String?> getPersistentNovelChapterContent(
    Novel novel,
    Chapter chapter,
  ) async {
    await init();
    return _novelOfflineCacheService.getPersistentChapterContent(
      novel,
      chapter,
    );
  }

  Future<String> resolveNovelChapterContent({
    required Novel novel,
    required Chapter chapter,
    required Future<String> Function() loadFromNetwork,
    NovelChapterContentValidator? isValidContent,
  }) async {
    await init();
    final content = await _novelOfflineCacheService.resolveChapterContent(
      novel: novel,
      chapter: chapter,
      loadFromNetwork: loadFromNetwork,
      isValidContent: isValidContent,
    );
    unawaited(_pruneChapterCacheIfNeeded());
    return content;
  }

  Future<void> pinNovelChapter(
    Novel novel,
    Chapter chapter,
    String content,
  ) async {
    await init();
    await _novelOfflineCacheService.pinChapter(novel, chapter, content);
  }

  Future<void> clearPinnedNovelChapter(Novel novel) async {
    await init();
    await _novelOfflineCacheService.clearPinnedChapter(novel);
  }

  Future<void> saveDownloadedNovelChapter(
    Novel novel,
    Chapter chapter,
    String content,
  ) async {
    await init();
    await _novelOfflineCacheService.saveDownloadedChapter(
      novel,
      chapter,
      content,
    );
  }

  Future<void> removeDownloadedNovelChapter(
    Novel novel,
    String chapterId,
  ) async {
    await init();
    await _novelOfflineCacheService.removeDownloadedChapter(novel, chapterId);
  }

  Future<void> clearDownloadedNovelChapters(Novel novel) async {
    await init();
    await _novelOfflineCacheService.clearDownloadedChapters(novel);
  }

  Future<NovelOfflineStatus> getNovelOfflineStatus(Novel novel) async {
    await init();
    return _novelOfflineCacheService.getStatus(novel);
  }

  Future<NovelCacheBatchResult> cacheNovelChapterBatch({
    required Novel novel,
    required List<Chapter> chapters,
    required Iterable<int> chapterIndices,
    required NovelChapterContentLoader loadContent,
    NovelCacheProgressCallback? onProgress,
  }) async {
    await init();
    return _novelOfflineCacheService.cacheBatch(
      novel: novel,
      chapters: chapters,
      chapterIndices: chapterIndices,
      loadContent: loadContent,
      onProgress: onProgress,
    );
  }

  String _chapterListPath(String novelId) =>
      '$_dataDirPath/chapters_${_cacheFileKey(novelId)}.json';

  String _chapterContentPath(String novelId, String chapterId) =>
      '$_dataDirPath/content_${_cacheFileKey('$novelId::$chapterId')}.txt';

  String _cacheFileKey(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  Future<void> saveChapterList(
    String novelId,
    List<Map<String, dynamic>> chapters,
  ) async {
    final file = File(_chapterListPath(novelId));
    await file.writeAsString(jsonEncode(chapters));
    unawaited(_pruneChapterCacheIfNeeded());
  }

  Future<List<Map<String, dynamic>>?> getChapterList(String novelId) async {
    final file = File(_chapterListPath(novelId));
    if (await file.exists()) {
      final jsonStr = await file.readAsString();
      unawaited(file.setLastModified(DateTime.now()));
      final list = jsonDecode(jsonStr) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return null;
  }

  Future<void> saveChapterContent(
    String novelId,
    String chapterId,
    String content,
  ) async {
    final file = File(_chapterContentPath(novelId, chapterId));
    await file.writeAsString(content, flush: true);
    unawaited(_pruneChapterCacheIfNeeded());
  }

  Future<String?> getChapterContent(String novelId, String chapterId) async {
    final file = File(_chapterContentPath(novelId, chapterId));
    if (await file.exists()) {
      final content = await file.readAsString();
      unawaited(file.setLastModified(DateTime.now()));
      return content;
    }
    return null;
  }

  Future<void> deleteChapterContent(String novelId, String chapterId) async {
    final file = File(_chapterContentPath(novelId, chapterId));
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _pruneChapterCacheIfNeeded() async {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    if (nowMs - _lastChapterCachePruneAtMs <
        _chapterCachePruneInterval.inMilliseconds) {
      return;
    }
    _lastChapterCachePruneAtMs = nowMs;
    final dataPath = _dataDirPath;
    if (dataPath == null) return;
    final directory = Directory(dataPath);
    if (!await directory.exists()) return;
    final entries = <({File file, FileStat stat})>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('content_') && !name.startsWith('chapters_')) {
        continue;
      }
      try {
        entries.add((file: entity, stat: await entity.stat()));
      } catch (_) {
        // A concurrently removed cache file can be ignored.
      }
    }
    entries.sort(
      (left, right) => left.stat.modified.compareTo(right.stat.modified),
    );
    var totalBytes = entries.fold<int>(0, (sum, item) => sum + item.stat.size);
    var remainingFiles = entries.length;
    final oldestAllowed = now.subtract(_chapterCacheMaxAge);
    for (final entry in entries) {
      final expired = entry.stat.modified.isBefore(oldestAllowed);
      final overLimit =
          remainingFiles > _chapterCacheMaxFiles ||
          totalBytes > _chapterCacheMaxBytes;
      if (!expired && !overLimit) break;
      try {
        await entry.file.delete();
        totalBytes -= entry.stat.size;
        remainingFiles -= 1;
      } catch (_) {
        // Cache pruning must never interrupt reading.
      }
    }
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
