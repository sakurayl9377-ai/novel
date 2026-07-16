import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/reading_settings.dart';
import '../models/reading_progress.dart';
import '../models/novel.dart';
import '../models/chapter.dart';
import '../services/storage_service.dart';
import '../services/progress_sync_service.dart';

class ReadingProvider extends ChangeNotifier {
  ReadingProvider() {
    ProgressSyncService.instance.revision.addListener(_handleRemoteRevision);
  }

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
      if (ReadingSettings.needsLayoutPresetMigration(saved)) {
        await _storage.saveReadingSettings(_settings.toJson());
      }
      notifyListeners();
    }
  }

  Future<void> saveSettings(ReadingSettings newSettings) async {
    _settings = newSettings;
    await _storage.saveReadingSettings(_settings.toJson());
    notifyListeners();
  }

  /// Applies settings to the live reader without generating a database write
  /// for every slider tick. The settings sheet persists the final snapshot
  /// when it closes.
  void previewSettings(ReadingSettings newSettings) {
    _settings = newSettings;
    notifyListeners();
  }

  Future<void> updateFontSize(double size) async {
    await saveSettings(_settings.copyWith(fontSize: size));
  }

  Future<void> updateFontFamily(String family) async {
    await saveSettings(_settings.copyWith(fontFamily: family));
  }

  Future<void> updateBackgroundColor(String color) async {
    await saveSettings(
      _settings.copyWith(
        backgroundColor: color,
        nightMode: color == '#1A1A1A' || color == '#2B2B2B',
      ),
    );
  }

  Future<void> updatePageTurnMode(String mode) async {
    final next = _settings.copyWith();
    next.pageTurnMode = mode;
    await saveSettings(next);
  }

  Future<void> toggleNightMode() async {
    await setNightMode(!_settings.nightMode);
  }

  Future<void> setNightMode(bool enabled) async {
    await saveSettings(
      _settings.copyWith(
        nightMode: enabled,
        backgroundColor: enabled
            ? '#1A1A1A'
            : ReadingSettings.defaultPaperColor,
      ),
    );
  }

  void toggleSettings() {
    _showSettings = !_showSettings;
    notifyListeners();
  }

  void hideSettings() {
    _showSettings = false;
    notifyListeners();
  }

  Future<ReadingProgress?> loadProgress(Novel novel) async {
    final progressData = await _storage.getNovelReadingProgress(novel);
    if (progressData != null) {
      _currentProgress = ReadingProgress.fromJson(progressData);
      notifyListeners();
    } else {
      _currentProgress = null;
    }
    return _currentProgress;
  }

  Future<void> saveProgress(Novel novel, ReadingProgress progress) async {
    _currentProgress = progress;
    await _storage.saveNovelReadingProgress(novel, progress.toJson());
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

  void _handleRemoteRevision() {
    unawaited(_reloadSyncedReaderState());
  }

  Future<void> _reloadSyncedReaderState() async {
    final owner = ProgressSyncService.instance.activeOwnerUserId;
    final savedSettings = await _storage.getReadingSettings();
    final novel = _currentNovel;
    final progressData = novel == null
        ? null
        : await _storage.getNovelReadingProgress(novel);
    if (owner != ProgressSyncService.instance.activeOwnerUserId) return;
    _settings = savedSettings == null
        ? ReadingSettings()
        : ReadingSettings.fromJson(savedSettings);
    _currentProgress = progressData == null
        ? null
        : ReadingProgress.fromJson(progressData);
    notifyListeners();
  }

  @override
  void dispose() {
    ProgressSyncService.instance.revision.removeListener(_handleRemoteRevision);
    super.dispose();
  }
}
