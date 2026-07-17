import 'package:flutter/material.dart';

import '../models/content_progress.dart';
import '../models/novel.dart';
import '../models/reading_progress.dart';
import '../services/storage_service.dart';

ReadingProgress? findBookshelfProgressForNovel(
  Novel novel,
  Iterable<Novel> books,
  Map<String, ReadingProgress> progressByNovelId,
) {
  final direct = progressByNovelId[novel.id];
  if (direct != null) return direct;

  final targetIdentity = ContentIdentity.novel(novel);
  for (final book in books) {
    if (ContentIdentity.novel(book).contentKey == targetIdentity.contentKey) {
      final progress = progressByNovelId[book.id];
      if (progress != null) return progress;
    }
  }

  final normalizedTitle = _normalizeNovelTitle(novel.title);
  if (normalizedTitle.isEmpty) return null;
  for (final book in books) {
    final bookIdentity = ContentIdentity.novel(book);
    if (bookIdentity.sourceKey == targetIdentity.sourceKey &&
        _normalizeNovelTitle(book.title) == normalizedTitle) {
      final progress = progressByNovelId[book.id];
      if (progress != null) return progress;
    }
  }
  return null;
}

String _normalizeNovelTitle(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[\s\p{P}\p{S}]+', unicode: true),
  '',
);

class BookshelfProvider extends ChangeNotifier {
  final StorageService _storage = StorageService();
  List<Novel> _books = [];
  final Map<String, ReadingProgress> _progressByNovelId = {};
  bool _isLoading = false;

  List<Novel> get books => _books;
  bool get isLoading => _isLoading;
  ReadingProgress? progressFor(String novelId) => _progressByNovelId[novelId];

  ReadingProgress? progressForNovel(Novel novel) =>
      findBookshelfProgressForNovel(novel, _books, _progressByNovelId);

  Future<void> loadBookshelf() async {
    _isLoading = true;
    notifyListeners();

    final booksData = await _storage.getBookshelf();
    _books = booksData.map((d) => Novel.fromJson(d)).toList();
    _progressByNovelId.clear();
    for (final book in _books) {
      final progressData = await _storage.getNovelReadingProgress(book);
      if (progressData != null) {
        _progressByNovelId[book.id] = ReadingProgress.fromJson(progressData);
      }
    }
    _books.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));

    _isLoading = false;
    notifyListeners();
  }

  Future<void> addToBookshelf(Novel novel) async {
    final existing = _books.indexWhere((b) => b.id == novel.id);
    if (existing >= 0) {
      _books[existing] = novel;
    } else {
      _books.insert(0, novel);
    }
    await _storage.saveBookToShelf(novel.toJson());
    notifyListeners();
  }

  Future<void> removeFromBookshelf(String novelId) async {
    _books.removeWhere((b) => b.id == novelId);
    _progressByNovelId.remove(novelId);
    await _storage.removeBookFromShelf(novelId);
    notifyListeners();
  }

  Future<void> updateNovel(Novel novel) async {
    final index = _books.indexWhere((b) => b.id == novel.id);
    if (index >= 0) {
      _books[index] = novel;
      final progressData = await _storage.getNovelReadingProgress(novel);
      if (progressData != null) {
        _progressByNovelId[novel.id] = ReadingProgress.fromJson(progressData);
      }
      await _storage.saveBookToShelf(novel.toJson());
      notifyListeners();
    }
  }

  Future<void> importLocalNovel(Map<String, dynamic> importResult) async {
    if (importResult.containsKey('novel') &&
        importResult.containsKey('chapters')) {
      final novelData = importResult['novel'] as Map<String, dynamic>;
      final chapters = importResult['chapters'] as List;

      final novel = Novel.fromJson(novelData);
      await _storage.saveBookToShelf(novel.toJson());
      await _storage.saveNovelChapterList(
        novel,
        chapters.cast<Map<String, dynamic>>(),
      );

      _books.insert(0, novel);
      notifyListeners();
    }
  }

  bool isOnShelf(String novelId) {
    return _books.any((b) => b.id == novelId);
  }

  Novel? getNovel(String novelId) {
    try {
      return _books.firstWhere((b) => b.id == novelId);
    } catch (_) {
      return null;
    }
  }

  int get bookshelfCount => _books.length;
}
