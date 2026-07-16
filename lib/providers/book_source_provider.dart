import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../models/chapter.dart';
import '../models/content_progress.dart';
import '../models/novel.dart';
import '../services/book_source_service.dart';
import '../services/ai_creation_service.dart';
import '../services/novel_offline_cache_service.dart';
import '../services/storage_service.dart';

class BookSourceProvider extends ChangeNotifier {
  static const String _selectedSourceKey = 'selected_novel_source_id';

  BookSourceProvider({
    StorageService? storage,
    BookSourceService? sourceService,
    AiCreationService? aiCreationService,
  }) : _storage = storage ?? StorageService(),
       _sourceService = sourceService ?? BookSourceService(),
       _aiCreationService = aiCreationService ?? AiCreationService();

  @visibleForTesting
  BookSourceProvider.forTesting({
    required List<BookSource> sources,
    required String selectedSourceId,
    required BookSourceService sourceService,
  }) : _storage = StorageService(),
       // Public test seam keeps the private field out of the named API.
       // ignore: prefer_initializing_formals
       _sourceService = sourceService,
       _aiCreationService = AiCreationService() {
    _sources = List<BookSource>.of(sources);
    _selectedSourceId = selectedSourceId;
  }

  final StorageService _storage;
  final BookSourceService _sourceService;
  final AiCreationService _aiCreationService;

  List<BookSource> _sources = [];
  List<Novel> _searchResults = [];
  String _selectedSourceId = '';
  static const int _chapterCacheMaxEntries = 24;
  final LinkedHashMap<String, List<Chapter>> _chapterCache =
      LinkedHashMap<String, List<Chapter>>();
  final Map<String, Future<List<Chapter>>> _chapterInflight = {};
  final Map<String, Future<void>> _chapterRefreshInflight = {};
  final Map<String, DateTime> _chapterLastRefreshAttempt = {};
  final Map<String, Set<String>> _cacheIdentitiesByNovelId = {};
  bool _isSearching = false;
  int _searchRequestId = 0;

  List<BookSource> get sources => _sources;
  List<Novel> get searchResults => _searchResults;
  bool get isSearching => _isSearching;
  String get selectedSourceId => _selectedSourceId;
  BookSource? get selectedSource {
    for (final source in _sources) {
      if (source.id == _selectedSourceId) return source;
    }
    return null;
  }

  Future<void> loadSources() async {
    await _storage.init();
    _sources = await _sourceService.ensureBuiltinSources();
    _selectedSourceId = _storage.getString(_selectedSourceKey) ?? '';
    await _ensureSelectedSource();
    notifyListeners();
  }

  Future<void> addSource(BookSource source) async {
    await _sourceService.addSource(source);
    _sources = await _sourceService.ensureBuiltinSources();
    await _ensureSelectedSource();
    notifyListeners();
  }

  Future<void> updateSource(BookSource source) async {
    await _sourceService.updateSource(source);
    _sources = await _sourceService.ensureBuiltinSources();
    await _ensureSelectedSource();
    notifyListeners();
  }

  Future<void> deleteSource(String sourceId) async {
    await _sourceService.deleteSource(sourceId);
    _sources = await _sourceService.ensureBuiltinSources();
    await _ensureSelectedSource();
    notifyListeners();
  }

  Future<void> toggleSource(String sourceId, bool enabled) async {
    await _sourceService.toggleSource(sourceId, enabled);
    _sources = await _sourceService.ensureBuiltinSources();
    await _ensureSelectedSource();
    notifyListeners();
  }

  Future<void> addDefaultSources() async {
    _sources = await _sourceService.ensureBuiltinSources();
    await _ensureSelectedSource();
    notifyListeners();
  }

  Future<void> selectSource(String sourceId) async {
    final selectable = _sources.any(
      (source) => source.id == sourceId && source.enabled,
    );
    if (!selectable || sourceId == _selectedSourceId) return;
    _selectedSourceId = sourceId;
    notifyListeners();
    await _storage.setString(_selectedSourceKey, sourceId);
  }

  Future<void> _ensureSelectedSource() async {
    final selectedIsEnabled = _sources.any(
      (source) => source.id == _selectedSourceId && source.enabled,
    );
    if (selectedIsEnabled) return;

    _selectedSourceId = '';
    for (final source in _sources) {
      if (source.enabled) {
        _selectedSourceId = source.id;
        break;
      }
    }
    if (_selectedSourceId.isEmpty) {
      await _storage.remove(_selectedSourceKey);
    } else {
      await _storage.setString(_selectedSourceKey, _selectedSourceId);
    }
  }

  Future<void> searchBooks(
    String keyword, {
    bool allSources = false,
    ValueChanged<List<Novel>>? onResults,
  }) async {
    if (keyword.trim().isEmpty) return;
    final requestId = ++_searchRequestId;

    _isSearching = true;
    _searchResults = [];
    notifyListeners();

    try {
      final seen = <String>{};
      void merge(List<Novel> results) {
        if (requestId != _searchRequestId) return;
        for (final novel in results) {
          final key = '${novel.sourceId}|${novel.title}|${novel.author}';
          if (seen.add(key)) _searchResults.add(novel);
        }
        onResults?.call(List<Novel>.unmodifiable(_searchResults));
        notifyListeners();
      }

      Future<List<Novel>> searchSource(String sourceId) {
        if (sourceId.isEmpty) return Future.value(const <Novel>[]);
        return _sourceService
            .searchBooks(keyword, sourceId: sourceId)
            .timeout(const Duration(seconds: 6), onTimeout: () => const []);
      }

      if (!allSources) {
        merge(await searchSource(_selectedSourceId));
        return;
      }

      final otherSourceIds = _sources
          .where((source) => source.enabled && source.id != _selectedSourceId)
          .map((source) => source.id)
          .toList();
      await Future.wait(<Future<void>>[
        searchSource(_selectedSourceId).then(merge),
        ...otherSourceIds.map((sourceId) => searchSource(sourceId).then(merge)),
      ]);
    } finally {
      if (requestId == _searchRequestId) {
        _isSearching = false;
        notifyListeners();
      }
    }
  }

  Future<Novel> getBookDetail(Novel novel) async {
    if (AiCreationService.isAiNovel(novel)) {
      return _aiCreationService.fetchNovel(novel);
    }
    final detail = await _sourceService.fetchBookDetail(novel);
    return detail;
  }

  Future<List<Chapter>> getChapterList(Novel novel) async {
    final cacheKey = _cacheKey(novel);
    final memoryCached = _chapterCache.remove(cacheKey);
    if (memoryCached != null) {
      _chapterCache[cacheKey] = memoryCached;
      _scheduleChapterRefresh(novel);
      return memoryCached;
    }

    final inflight = _chapterInflight[cacheKey];
    if (inflight != null) return inflight;
    final future = _loadChapterList(novel);
    _chapterInflight[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_chapterInflight[cacheKey], future)) {
        _chapterInflight.remove(cacheKey);
      }
    }
  }

  Future<List<Chapter>> _loadChapterList(Novel novel) async {
    final cacheKey = _cacheKey(novel);
    final cached = await _storage.getNovelChapterList(novel);
    if (cached != null && cached.isNotEmpty) {
      final chapters = cached.map((d) => Chapter.fromJson(d)).toList();
      if (!_cacheLooksWrong(chapters)) {
        _putChapterCache(cacheKey, chapters);
        _scheduleChapterRefresh(novel);
        return chapters;
      }
    }

    final chapters = await _fetchChapterList(novel);
    if (chapters.isNotEmpty) {
      _putChapterCache(cacheKey, chapters);
      await _storage.saveNovelChapterList(
        novel,
        chapters.map((c) => c.toJson()).toList(),
      );
    }
    return chapters;
  }

  List<Chapter> buildProvisionalChapterList(
    Novel novel, {
    int throughIndex = 0,
  }) {
    return _sourceService.buildProvisionalChapterList(
      novel,
      throughIndex: throughIndex,
    );
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

  void _putChapterCache(String cacheKey, List<Chapter> chapters) {
    _chapterCache.remove(cacheKey);
    _chapterCache[cacheKey] = chapters;
    while (_chapterCache.length > _chapterCacheMaxEntries) {
      final evictedKey = _chapterCache.keys.first;
      _chapterCache.remove(evictedKey);
      _chapterLastRefreshAttempt.remove(evictedKey);
    }
  }

  void _scheduleChapterRefresh(Novel novel) {
    final cacheKey = _cacheKey(novel);
    final lastAttempt = _chapterLastRefreshAttempt[cacheKey];
    if (lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(minutes: 15)) {
      return;
    }
    if (_chapterRefreshInflight.containsKey(cacheKey)) return;

    _chapterLastRefreshAttempt[cacheKey] = DateTime.now();
    late final Future<void> task;
    task = _refreshChapterList(novel).whenComplete(() {
      if (identical(_chapterRefreshInflight[cacheKey], task)) {
        _chapterRefreshInflight.remove(cacheKey);
      }
    });
    _chapterRefreshInflight[cacheKey] = task;
    unawaited(task);
  }

  Future<void> _refreshChapterList(Novel novel) async {
    final cacheKey = _cacheKey(novel);
    try {
      final chapters = await _fetchChapterList(novel, forceRefresh: true);
      if (chapters.isEmpty || _cacheLooksWrong(chapters)) return;
      final previous = _chapterCache[cacheKey];
      if (_sameChapterList(previous, chapters)) return;
      _putChapterCache(cacheKey, chapters);
      await _storage.saveNovelChapterList(
        novel,
        chapters.map((chapter) => chapter.toJson()).toList(),
      );
      notifyListeners();
    } catch (_) {
      _chapterLastRefreshAttempt.remove(cacheKey);
    }
  }

  bool _sameChapterList(List<Chapter>? first, List<Chapter> second) {
    if (first == null || first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index].id != second[index].id ||
          first[index].title != second[index].title ||
          first[index].url != second[index].url) {
        return false;
      }
    }
    return true;
  }

  Future<String> getChapterContent(Novel novel, Chapter chapter) async {
    if (novel.isLocal) return chapter.content;

    final content = await _storage.resolveNovelChapterContent(
      novel: novel,
      chapter: chapter,
      isValidContent: (value) => !_isFailedContent(value),
      loadFromNetwork: () async {
        if (AiCreationService.isAiNovel(novel)) {
          return _aiCreationService.fetchChapterContent(novel, chapter);
        }
        final source = _sources.firstWhere(
          (candidate) => candidate.id == novel.sourceId,
          orElse: () => _sources.isNotEmpty
              ? _sources.first
              : novel.sourceId == BookSourceService.wenku8Source.id
              ? BookSourceService.wenku8Source
              : BookSourceService.bqg995Source,
        );
        return _sourceService.getChapterContent(chapter, source);
      },
    );
    if (content.isNotEmpty && !_isFailedContent(content)) {
      final chapters = _chapterCache[_cacheKey(novel)];
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

  Future<void> pinCurrentChapter(Novel novel, Chapter chapter) async {
    final content = await getChapterContent(novel, chapter);
    if (content.isEmpty || _isFailedContent(content)) return;
    await _storage.pinNovelChapter(novel, chapter, content);
  }

  Future<void> clearPinnedChapter(Novel novel) {
    return _storage.clearPinnedNovelChapter(novel);
  }

  Future<NovelOfflineStatus> getOfflineStatus(Novel novel) {
    return _storage.getNovelOfflineStatus(novel);
  }

  Future<void> removeDownloadedChapter(Novel novel, String chapterId) {
    return _storage.removeDownloadedNovelChapter(novel, chapterId);
  }

  Future<void> clearDownloadedChapters(Novel novel) {
    return _storage.clearDownloadedNovelChapters(novel);
  }

  Future<NovelCacheBatchResult> cacheChapters(
    Novel novel,
    List<Chapter> chapters, {
    required NovelCacheBatchRange range,
    int startIndex = 0,
    NovelCacheProgressCallback? onProgress,
  }) {
    final indices = range.chapterIndices(
      chapterCount: chapters.length,
      startIndex: startIndex,
    );
    return _storage.cacheNovelChapterBatch(
      novel: novel,
      chapters: chapters,
      chapterIndices: indices,
      loadContent: (chapter) => getChapterContent(novel, chapter),
      onProgress: onProgress,
    );
  }

  Future<List<Chapter>> _fetchChapterList(
    Novel novel, {
    bool forceRefresh = false,
  }) {
    if (AiCreationService.isAiNovel(novel)) {
      return _aiCreationService.fetchChapters(novel);
    }
    return _sourceService.getChapterList(novel, forceRefresh: forceRefresh);
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

  void clearNovelChapterCache(Novel novel) {
    final cacheKey = _cacheKey(novel);
    _chapterCache.remove(cacheKey);
    _chapterLastRefreshAttempt.remove(cacheKey);
    final identities = _cacheIdentitiesByNovelId[novel.id];
    identities?.remove(cacheKey);
    if (identities?.isEmpty ?? false) {
      _cacheIdentitiesByNovelId.remove(novel.id);
    }
    _sourceService.invalidateChapterList(novel);
  }

  void clearChapterCache(String novelId) {
    final cacheKeys =
        _cacheIdentitiesByNovelId.remove(novelId) ?? const <String>{};
    for (final cacheKey in cacheKeys) {
      _chapterCache.remove(cacheKey);
      _chapterLastRefreshAttempt.remove(cacheKey);
    }
    _sourceService.invalidateChapterListsForNovelId(novelId);
  }

  String _cacheKey(Novel novel) {
    final key = ContentIdentity.novel(novel).contentKey;
    _cacheIdentitiesByNovelId.putIfAbsent(novel.id, () => <String>{}).add(key);
    return key;
  }
}
