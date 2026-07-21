import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/reading_settings.dart';
import '../models/reading_progress.dart';
import '../models/novel.dart';
import '../models/chapter.dart';
import '../services/storage_service.dart';
import '../services/progress_sync_service.dart';

typedef ReadingSettingsLoader =
    Future<Map<String, dynamic>?> Function(String ownerUserId);
typedef ReadingSettingsSaver =
    Future<void> Function(Map<String, dynamic> settings, String ownerUserId);

class ReadingProvider extends ChangeNotifier {
  ReadingProvider({
    StorageService? storage,
    Duration settingsSaveDebounce = const Duration(milliseconds: 250),
    ReadingSettingsLoader? settingsLoader,
    ReadingSettingsSaver? settingsSaver,
    String Function()? ownerUserIdProvider,
    ValueListenable<int>? syncRevision,
  }) : _storage = storage ?? StorageService(),
       _debounceDuration = settingsSaveDebounce,
       _loadSettingsOverride = settingsLoader,
       _saveSettingsOverride = settingsSaver {
    _ownerUserIdProvider =
        ownerUserIdProvider ??
        () => ProgressSyncService.instance.activeOwnerUserId;
    _syncRevision = syncRevision ?? ProgressSyncService.instance.revision;
    _syncRevision.addListener(_handleRemoteRevision);
  }

  final StorageService _storage;
  final Duration _debounceDuration;
  final ReadingSettingsLoader? _loadSettingsOverride;
  final ReadingSettingsSaver? _saveSettingsOverride;
  late final String Function() _ownerUserIdProvider;
  late final ValueListenable<int> _syncRevision;

  ReadingSettings _settings = ReadingSettings();
  ReadingProgress? _currentProgress;
  Novel? _currentNovel;
  Chapter? _currentChapter;
  List<Chapter> _chapters = [];
  String _currentContent = '';
  bool _isLoadingContent = false;
  bool _showSettings = false;
  Timer? _settingsSaveTimer;
  _PendingSettingsWrite? _pendingSettingsWrite;
  Future<void> _settingsWriteChain = Future<void>.value();
  int _settingsMutationGeneration = 0;
  bool _isDisposed = false;

  ReadingSettings get settings => _settings;
  ReadingProgress? get currentProgress => _currentProgress;
  Novel? get currentNovel => _currentNovel;
  Chapter? get currentChapter => _currentChapter;
  List<Chapter> get chapters => _chapters;
  String get currentContent => _currentContent;
  bool get isLoadingContent => _isLoadingContent;
  bool get showSettings => _showSettings;

  Future<void> loadSettings() async {
    final owner = _ownerUserIdProvider();
    final revision = _syncRevision.value;
    final mutationGeneration = _settingsMutationGeneration;
    final saved = await _loadSettingsForOwner(owner);
    if (!_isSettingsReadCurrent(owner, revision, mutationGeneration)) return;
    if (saved != null) {
      final hasReaderSettings = ReadingSettings.containsReaderSettings(saved);
      final loaded = hasReaderSettings
          ? ReadingSettings.fromJson(saved)
          : _applyDevicePreferences(_settings, saved);
      _settings = loaded;
      _settingsMutationGeneration += 1;
      notifyListeners();
      if (hasReaderSettings &&
          ReadingSettings.needsLayoutPresetMigration(saved)) {
        await _enqueueSettingsWrite(
          _PendingSettingsWrite(
            owner,
            loaded.toJson(),
            _settingsMutationGeneration,
          ),
        );
      }
    }
  }

  Future<void> saveSettings(ReadingSettings newSettings) async {
    _settings = newSettings;
    _settingsMutationGeneration += 1;
    _scheduleSettingsSave(newSettings);
    notifyListeners();
    await flushPendingSettings();
  }

  /// Applies settings immediately and persists the last preview after a short
  /// quiet period so a backgrounded settings sheet cannot lose its changes.
  void previewSettings(ReadingSettings newSettings) {
    _settings = newSettings;
    _settingsMutationGeneration += 1;
    _scheduleSettingsSave(newSettings);
    notifyListeners();
  }

  Future<void> flushPendingSettings() async {
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = null;
    final pending = _pendingSettingsWrite;
    _pendingSettingsWrite = null;
    if (pending == null) {
      await _settingsWriteChain;
      return;
    }
    try {
      await _enqueueSettingsWrite(pending);
    } catch (error, stackTrace) {
      if (!_isDisposed &&
          pending.mutationGeneration == _settingsMutationGeneration &&
          _pendingSettingsWrite == null) {
        _pendingSettingsWrite = pending;
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
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
    final loadedProgress = progressData == null
        ? null
        : ReadingProgress.fromJson(progressData);
    if (_isDisposed) return loadedProgress;
    if (progressData != null) {
      _currentProgress = loadedProgress;
      notifyListeners();
      return loadedProgress;
    } else {
      _currentProgress = null;
    }
    return null;
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
    if (_isDisposed) return;
    unawaited(
      _reloadSyncedReaderState().catchError((Object error, StackTrace stack) {
        debugPrint('Reader state refresh failed: $error\n$stack');
      }),
    );
  }

  Future<void> _reloadSyncedReaderState() async {
    final owner = _ownerUserIdProvider();
    final revision = _syncRevision.value;
    final mutationGeneration = _settingsMutationGeneration;
    try {
      await flushPendingSettings();
    } catch (_) {
      // Preserve the in-memory settings when their local write did not finish.
      return;
    }
    if (!_isSettingsReadCurrent(owner, revision, mutationGeneration)) return;
    final savedSettings = await _loadSettingsForOwner(owner);
    final novel = _currentNovel;
    final progressData = novel == null
        ? null
        : await _storage.getNovelReadingProgress(novel);
    if (!_isSettingsReadCurrent(owner, revision, mutationGeneration)) return;
    final defaultSettings = ReadingSettings();
    _settings = savedSettings == null
        ? defaultSettings
        : ReadingSettings.containsReaderSettings(savedSettings)
        ? ReadingSettings.fromJson(savedSettings)
        : _applyDevicePreferences(defaultSettings, savedSettings);
    _settingsMutationGeneration += 1;
    _currentProgress = progressData == null
        ? null
        : ReadingProgress.fromJson(progressData);
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _loadSettingsForOwner(String ownerUserId) {
    final loader = _loadSettingsOverride;
    if (loader != null) return loader(ownerUserId);
    return _storage.getReadingSettings(ownerUserId: ownerUserId);
  }

  Future<void> _saveSettingsForOwner(
    Map<String, dynamic> settings,
    String ownerUserId,
  ) {
    final saver = _saveSettingsOverride;
    if (saver != null) return saver(settings, ownerUserId);
    return _storage.saveReadingSettings(settings, ownerUserId: ownerUserId);
  }

  bool _isSettingsReadCurrent(
    String ownerUserId,
    int revision,
    int mutationGeneration,
  ) {
    return !_isDisposed &&
        ownerUserId == _ownerUserIdProvider() &&
        revision == _syncRevision.value &&
        mutationGeneration == _settingsMutationGeneration;
  }

  void _scheduleSettingsSave(ReadingSettings settings) {
    _pendingSettingsWrite = _PendingSettingsWrite(
      _ownerUserIdProvider(),
      settings.toJson(),
      _settingsMutationGeneration,
    );
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = Timer(_debounceDuration, () {
      _settingsSaveTimer = null;
      unawaited(flushPendingSettings().catchError((Object _, StackTrace _) {}));
    });
  }

  Future<void> _enqueueSettingsWrite(_PendingSettingsWrite pending) {
    final operation = _settingsWriteChain.then(
      (_) => _saveSettingsForOwner(pending.settings, pending.ownerUserId),
    );
    _settingsWriteChain = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  ReadingSettings _applyDevicePreferences(
    ReadingSettings base,
    Map<String, dynamic> payload,
  ) {
    final brightness = payload['brightness'];
    final useSystemBrightness = payload['useSystemBrightness'];
    return ReadingSettings.fromJson({
      ...base.toJson(),
      if (brightness is num) 'brightness': brightness.toDouble(),
      if (useSystemBrightness is bool)
        'useSystemBrightness': useSystemBrightness,
    });
  }

  @override
  void dispose() {
    _settingsSaveTimer?.cancel();
    _settingsSaveTimer = null;
    final pending = _pendingSettingsWrite;
    _pendingSettingsWrite = null;
    if (pending != null) {
      unawaited(
        _enqueueSettingsWrite(
          _PendingSettingsWrite(
            pending.ownerUserId,
            Map<String, dynamic>.from(pending.settings),
            pending.mutationGeneration,
          ),
        ).catchError((Object _, StackTrace _) {}),
      );
    }
    _isDisposed = true;
    _syncRevision.removeListener(_handleRemoteRevision);
    super.dispose();
  }
}

class _PendingSettingsWrite {
  const _PendingSettingsWrite(
    this.ownerUserId,
    this.settings,
    this.mutationGeneration,
  );

  final String ownerUserId;
  final Map<String, dynamic> settings;
  final int mutationGeneration;
}
