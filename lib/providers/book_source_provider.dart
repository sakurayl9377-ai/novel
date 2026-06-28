import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../models/chapter.dart';
import '../models/novel.dart';
import '../services/book_source_service.dart';
import '../services/storage_service.dart';

class BookSourceProvider extends ChangeNotifier {
  final StorageService _storage = StorageService();
  final BookSourceService _sourceService = BookSourceService();

  List<BookSource> _sources = [];
  List<Novel> _searchResults = [];
  final Map<String, List<Chapter>> _chapterCache = {};
  bool _isSearching = false;

  List<BookSource> get sources => _sources;
  List<Novel> get searchResults => _searchResults;
  bool get isSearching => _isSearching;

  Future<void> loadSources() async {
    _sources = await _sourceService.ensureOnlyBqg995Source();
    notifyListeners();
  }

  Future<void> addSource(BookSource source) async {
    _sources = await _sourceService.ensureOnlyBqg995Source();
    notifyListeners();
  }

  Future<void> updateSource(BookSource source) async {
    if (_sourceService.isBqg995Source(source)) {
      await _sourceService.updateSource(source);
    }
    _sources = await _sourceService.ensureOnlyBqg995Source();
    notifyListeners();
  }

  Future<void> deleteSource(String sourceId) async {
    _sources = await _sourceService.ensureOnlyBqg995Source();
    notifyListeners();
  }

  Future<void> toggleSource(String sourceId, bool enabled) async {
    _sources = await _sourceService.ensureOnlyBqg995Source();
    notifyListeners();
  }

  Future<void> addDefaultSources() async {
    _sources = await _sourceService.ensureOnlyBqg995Source();
    notifyListeners();
  }

  Future<void> searchBooks(String keyword) async {
    if (keyword.trim().isEmpty) return;

    _isSearching = true;
    _searchResults = [];
    notifyListeners();

    try {
      final results = await _sourceService.searchBooks(keyword);

      final seen = <String>{};
      for (final novel in results) {
        final key = '${novel.title}|${novel.author}';
        if (seen.add(key)) _searchResults.add(novel);
      }
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  Future<Novel> getBookDetail(Novel novel) async {
    final detail = await _sourceService.fetchBookDetail(novel);
    return detail;
  }

  Future<List<Chapter>> getChapterList(Novel novel) async {
    if (_chapterCache.containsKey(novel.id)) {
      return _chapterCache[novel.id]!;
    }

    final cached = await _storage.getChapterList(novel.id);
    if (cached != null && cached.isNotEmpty) {
      final chapters = cached.map((d) => Chapter.fromJson(d)).toList();
      if (!_cacheLooksWrong(chapters)) {
        _chapterCache[novel.id] = chapters;
        return chapters;
      }
    }

    final chapters = await _sourceService.getChapterList(novel);
    if (chapters.isNotEmpty) {
      _chapterCache[novel.id] = chapters;
      await _storage.saveChapterList(
        novel.id,
        chapters.map((c) => c.toJson()).toList(),
      );
    }

    return chapters;
  }

  bool _cacheLooksWrong(List<Chapter> chapters) {
    return chapters.length <= 1 &&
        chapters.any(
          (c) =>
              c.url.toLowerCase().contains('javascript:') ||
              RegExp(
                r'(expand|all chapters|\u5c55\u5f00|\u5168\u90e8\u7ae0\u8282)',
                caseSensitive: false,
              ).hasMatch(c.title),
        );
  }

  Future<String> getChapterContent(Novel novel, Chapter chapter) async {
    final cached = await _storage.getChapterContent(novel.id, chapter.id);
    if (cached != null && cached.isNotEmpty) {
      if (!_isFailedContent(cached)) return cached;
      await _storage.deleteChapterContent(novel.id, chapter.id);
    }

    final source = _sources.firstWhere(
      (s) => s.id == novel.sourceId,
      orElse: () =>
          _sources.isNotEmpty ? _sources.first : BookSourceService.bqg995Source,
    );

    final content = await _sourceService.getChapterContent(chapter, source);
    if (content.isNotEmpty) {
      await _storage.saveChapterContent(novel.id, chapter.id, content);

      final chapters = _chapterCache[novel.id];
      if (chapters != null) {
        final chIndex = chapters.indexWhere((c) => c.id == chapter.id);
        if (chIndex >= 0) {
          chapters[chIndex] = chapters[chIndex].copyWith(
            content: content,
            isLoaded: true,
          );
          notifyListeners();
        }
      }
    }

    return content;
  }

  bool _isFailedContent(String content) {
    final normalized = content.trim().replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty) return true;
    return normalized.contains('api.ranmeng.icu') ||
        RegExp(
          r'(site maintenance|network connection|failed to get chapter|\u7b14\u8da3\u9601\u6211\u7684\u4e66\u67b6\u8054\u7cfb\u6211\u4eec|\u7ad9\u70b9\u7ef4\u62a4|\u68c0\u67e5\u7f51\u7edc|\u83b7\u53d6\u7ae0\u8282\u5185\u5bb9\u5931\u8d25)',
          caseSensitive: false,
        ).hasMatch(normalized);
  }

  void clearSearch() {
    _searchResults = [];
    notifyListeners();
  }

  void clearChapterCache(String novelId) {
    _chapterCache.remove(novelId);
  }
}
