import 'package:flutter/material.dart';

import '../models/novel.dart';
import '../models/reading_progress.dart';
import '../services/storage_service.dart';

class BookshelfProvider extends ChangeNotifier {
  final StorageService _storage = StorageService();
  List<Novel> _books = [];
  final Map<String, ReadingProgress> _progressByNovelId = {};
  bool _isLoading = false;

  List<Novel> get books => _books;
  bool get isLoading => _isLoading;
  ReadingProgress? progressFor(String novelId) => _progressByNovelId[novelId];

  Future<void> loadBookshelf() async {
    _isLoading = true;
    notifyListeners();

    final booksData = await _storage.getBookshelf();
    _books = booksData.map((d) => Novel.fromJson(d)).toList();
    _progressByNovelId.clear();
    for (final book in _books) {
      final progressData = await _storage.getReadingProgress(book.id);
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
      final progressData = await _storage.getReadingProgress(novel.id);
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
      await _storage.saveChapterList(
        novel.id,
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
