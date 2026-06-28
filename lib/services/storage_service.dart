import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/anime_watch_history.dart';
import '../models/manga_read_history.dart';

class StorageService {
  static const String _bookshelfKey = 'bookshelf';
  static const String _bookSourcesKey = 'book_sources';
  static const String _readingSettingsKey = 'reading_settings';
  static const String _ttsSettingsKey = 'tts_settings';
  static const String _animeWatchHistoryKey = 'anime_watch_history';
  static const String _mangaReadHistoryKey = 'manga_read_history';
  static const String _readingProgressPrefix = 'progress_';
  static const Duration _animeWatchHistoryRetention = Duration(days: 30);
  static const Duration _mangaReadHistoryRetention = Duration(days: 30);

  late SharedPreferences _prefs;
  String? _dataDirPath;

  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    _dataDirPath = '${dir.path}/novel_app';
    final dataDir = Directory(_dataDirPath!);
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
  }

  // ============ 书架存储 ============

  Future<List<Map<String, dynamic>>> getBookshelf() async {
    final jsonStr = _prefs.getString(_bookshelfKey);
    if (jsonStr == null) return [];
    final list = jsonDecode(jsonStr) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> saveBookToShelf(Map<String, dynamic> bookData) async {
    final books = await getBookshelf();
    final index = books.indexWhere((b) => b['id'] == bookData['id']);
    if (index >= 0) {
      books[index] = bookData;
    } else {
      books.add(bookData);
    }
    await _prefs.setString(_bookshelfKey, jsonEncode(books));
  }

  Future<void> removeBookFromShelf(String bookId) async {
    final books = await getBookshelf();
    books.removeWhere((b) => b['id'] == bookId);
    await _prefs.setString(_bookshelfKey, jsonEncode(books));
  }

  Future<bool> isBookOnShelf(String bookId) async {
    final books = await getBookshelf();
    return books.any((b) => b['id'] == bookId);
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
    final jsonStr = _prefs.getString(_readingSettingsKey);
    if (jsonStr == null) return null;
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  Future<void> saveReadingSettings(Map<String, dynamic> settings) async {
    await _prefs.setString(_readingSettingsKey, jsonEncode(settings));
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
    final jsonStr = _prefs.getString('$_readingProgressPrefix$novelId');
    if (jsonStr == null) return null;
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  Future<void> saveReadingProgress(
    String novelId,
    Map<String, dynamic> progress,
  ) async {
    await _prefs.setString(
      '$_readingProgressPrefix$novelId',
      jsonEncode(progress),
    );
  }

  // ============ 动漫播放历史 ============

  Future<List<AnimeWatchHistory>> getAnimeWatchHistory() async {
    final jsonStr = _prefs.getString(_animeWatchHistoryKey);
    if (jsonStr == null) return const [];
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      await _prefs.remove(_animeWatchHistoryKey);
      return const [];
    }
    if (decoded is! List) {
      await _prefs.remove(_animeWatchHistoryKey);
      return const [];
    }
    final histories =
        decoded
            .whereType<Map>()
            .map(
              (item) =>
                  AnimeWatchHistory.fromJson(item.cast<String, dynamic>()),
            )
            .where(_isRecentAnimeHistory)
            .toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    await _prefs.setString(
      _animeWatchHistoryKey,
      jsonEncode(histories.map((item) => item.toJson()).toList()),
    );
    return histories;
  }

  Future<void> saveAnimeWatchHistory(AnimeWatchHistory history) async {
    if (history.animeId <= 0 ||
        history.title.isEmpty ||
        history.episodeUrl.isEmpty) {
      return;
    }
    final histories = await getAnimeWatchHistory();
    final next =
        [
            history,
            ...histories.where((item) => item.animeId != history.animeId),
          ].where(_isRecentAnimeHistory).toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    await _prefs.setString(
      _animeWatchHistoryKey,
      jsonEncode(next.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> clearAnimeWatchHistory() async {
    await _prefs.remove(_animeWatchHistoryKey);
  }

  Future<void> deleteAnimeWatchHistory(int animeId) async {
    final histories = await getAnimeWatchHistory();
    final next = histories.where((item) => item.animeId != animeId).toList();
    await _prefs.setString(
      _animeWatchHistoryKey,
      jsonEncode(next.map((item) => item.toJson()).toList()),
    );
  }

  bool _isRecentAnimeHistory(AnimeWatchHistory history) {
    final cutoff = DateTime.now()
        .subtract(_animeWatchHistoryRetention)
        .millisecondsSinceEpoch;
    return history.updatedAtMs >= cutoff;
  }

  // ============ 漫画阅读历史 ============

  Future<List<MangaReadHistory>> getMangaReadHistory() async {
    final jsonStr = _prefs.getString(_mangaReadHistoryKey);
    if (jsonStr == null) return const [];
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      await _prefs.remove(_mangaReadHistoryKey);
      return const [];
    }
    if (decoded is! List) {
      await _prefs.remove(_mangaReadHistoryKey);
      return const [];
    }
    final histories =
        decoded
            .whereType<Map>()
            .map(
              (item) => MangaReadHistory.fromJson(item.cast<String, dynamic>()),
            )
            .where(_isRecentMangaHistory)
            .toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    await _prefs.setString(
      _mangaReadHistoryKey,
      jsonEncode(histories.map((item) => item.toJson()).toList()),
    );
    return histories;
  }

  Future<void> saveMangaReadHistory(MangaReadHistory history) async {
    if (history.mangaId.isEmpty ||
        history.title.isEmpty ||
        history.chapterUrl.isEmpty) {
      return;
    }
    final histories = await getMangaReadHistory();
    final next =
        [
            history,
            ...histories.where((item) => item.mangaId != history.mangaId),
          ].where(_isRecentMangaHistory).toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    await _prefs.setString(
      _mangaReadHistoryKey,
      jsonEncode(next.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> clearMangaReadHistory() async {
    await _prefs.remove(_mangaReadHistoryKey);
  }

  Future<void> deleteMangaReadHistory(String mangaId) async {
    final histories = await getMangaReadHistory();
    final next = histories.where((item) => item.mangaId != mangaId).toList();
    await _prefs.setString(
      _mangaReadHistoryKey,
      jsonEncode(next.map((item) => item.toJson()).toList()),
    );
  }

  bool _isRecentMangaHistory(MangaReadHistory history) {
    final cutoff = DateTime.now()
        .subtract(_mangaReadHistoryRetention)
        .millisecondsSinceEpoch;
    return history.updatedAtMs >= cutoff;
  }

  // ============ 章节目录缓存 ============

  String _chapterListPath(String novelId) =>
      '$_dataDirPath/chapters_$novelId.json';

  String _chapterContentPath(String novelId, String chapterId) =>
      '$_dataDirPath/content_${novelId}_$chapterId.txt';

  Future<void> saveChapterList(
    String novelId,
    List<Map<String, dynamic>> chapters,
  ) async {
    final file = File(_chapterListPath(novelId));
    await file.writeAsString(jsonEncode(chapters));
  }

  Future<List<Map<String, dynamic>>?> getChapterList(String novelId) async {
    final file = File(_chapterListPath(novelId));
    if (await file.exists()) {
      final jsonStr = await file.readAsString();
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
  }

  Future<String?> getChapterContent(String novelId, String chapterId) async {
    final file = File(_chapterContentPath(novelId, chapterId));
    if (await file.exists()) {
      return await file.readAsString();
    }
    return null;
  }

  Future<void> deleteChapterContent(String novelId, String chapterId) async {
    final file = File(_chapterContentPath(novelId, chapterId));
    if (await file.exists()) {
      await file.delete();
    }
  }
}
