import 'package:flutter/foundation.dart';
import '../models/reading_settings.dart';
import '../models/reading_progress.dart';
import '../models/novel.dart';
import '../models/chapter.dart';
import '../services/storage_service.dart';

class ReadingProvider extends ChangeNotifier {
  final StorageService _storage = StorageService();

  ReadingSettings _settings = ReadingSettings();
  ReadingProgress? _currentProgress;
  Novel? _currentNovel;
  Chapter? _currentChapter;
  List<Chapter> _chapters = [];
  String _currentContent = '';
  bool _isLoadingContent = false;
  bool _showSettings = false;

  ReadingSettings get settings => _settings;
  ReadingProgress? get currentProgress => _currentProgress;
  Novel? get currentNovel => _currentNovel;
  Chapter? get currentChapter => _currentChapter;
  List<Chapter> get chapters => _chapters;
  String get currentContent => _currentContent;
  bool get isLoadingContent => _isLoadingContent;
  bool get showSettings => _showSettings;

  Future<void> loadSettings() async {
    final saved = await _storage.getReadingSettings();
    if (saved != null) {
      _settings = ReadingSettings.fromJson(saved);
      notifyListeners();
    }
  }

  Future<void> saveSettings(ReadingSettings newSettings) async {
    _settings = newSettings;
    await _storage.saveReadingSettings(_settings.toJson());
    notifyListeners();
  }

  Future<void> updateFontSize(double size) async {
    _settings.fontSize = size;
    await _storage.saveReadingSettings(_settings.toJson());
    notifyListeners();
  }

  Future<void> updateFontFamily(String family) async {
    _settings.fontFamily = family;
    await _storage.saveReadingSettings(_settings.toJson());
    notifyListeners();
  }

  Future<void> updateBackgroundColor(String color) async {
    _settings.backgroundColor = color;
    _settings.nightMode = color == '#1A1A1A' || color == '#2B2B2B';
    await _storage.saveReadingSettings(_settings.toJson());
    notifyListeners();
  }

  Future<void> updatePageTurnMode(String mode) async {
    _settings.pageTurnMode = ReadingSettings.pageTurnModes.contains(mode)
        ? mode
        : ReadingSettings.defaultPageTurnMode;
    await _storage.saveReadingSettings(_settings.toJson());
    notifyListeners();
  }

  Future<void> toggleNightMode() async {
    await setNightMode(!_settings.nightMode);
  }

  Future<void> setNightMode(bool enabled) async {
    _settings.nightMode = enabled;
    if (_settings.nightMode) {
      _settings.backgroundColor = '#1A1A1A';
    } else {
      _settings.backgroundColor = '#FFF8ED';
    }
    await _storage.saveReadingSettings(_settings.toJson());
    notifyListeners();
  }

  void toggleSettings() {
    _showSettings = !_showSettings;
    notifyListeners();
  }

  void hideSettings() {
    _showSettings = false;
    notifyListeners();
  }

  Future<ReadingProgress?> loadProgress(String novelId) async {
    final progressData = await _storage.getReadingProgress(novelId);
    if (progressData != null) {
      _currentProgress = ReadingProgress.fromJson(progressData);
      notifyListeners();
    } else {
      _currentProgress = null;
    }
    return _currentProgress;
  }

  Future<void> saveProgress(String novelId, ReadingProgress progress) async {
    _currentProgress = progress;
    await _storage.saveReadingProgress(novelId, progress.toJson());
  }

  void setCurrentNovel(Novel novel) {
    _currentNovel = novel;
    notifyListeners();
  }

  void setChapters(List<Chapter> chapters) {
    _chapters = chapters;
    notifyListeners();
  }

  void setCurrentChapter(Chapter chapter) {
    _currentChapter = chapter;
    notifyListeners();
  }

  void setCurrentContent(String content) {
    _currentContent = content;
    _isLoadingContent = false;
    notifyListeners();
  }

  void setLoadingContent(bool loading) {
    _isLoadingContent = loading;
    notifyListeners();
  }
}
