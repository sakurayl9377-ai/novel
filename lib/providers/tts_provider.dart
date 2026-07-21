import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/chapter.dart';
import '../models/novel.dart';
import '../models/reading_progress.dart';
import '../models/tts_settings.dart';
import '../services/storage_service.dart';
import '../services/tts_media_control_service.dart';
import '../services/tts_service.dart';

typedef TtsChapterContentLoader = Future<String> Function(Chapter chapter);
typedef TtsProgressSaver = Future<void> Function(ReadingProgress progress);
typedef TtsChapterAccessCheck = bool Function(int chapterIndex);

class TtsProvider extends ChangeNotifier {
  TtsProvider({
    TtsMediaControlService? mediaControlService,
    TtsService? ttsService,
  }) : _ttsService = ttsService ?? TtsService(),
       _mediaControlService =
           mediaControlService ?? TtsMediaControlService.disabled() {
    _ttsService.onStart = () {
      _isSpeaking = true;
      _isPaused = false;
      unawaited(_setWakelockEnabled(true));
      unawaited(_syncReadingMediaControls());
      notifyListeners();
    };
    _ttsService.onComplete = () {
      if (_handlingServiceComplete) return;
      _handlingServiceComplete = true;
      unawaited(_handleSpeakingComplete());
    };
    _ttsService.onError = () {
      final readingSession = _readingSession;
      if (readingSession != null) {
        unawaited(_persistReadingProgress(readingSession));
      }
      _isSpeaking = false;
      _lastErrorMessage = _ttsService.lastErrorMessage;
      if (readingSession != null && _ttsService.lastErrorIsRecoverable) {
        _isPaused = true;
        _speechOwnerKey = readingSession.ownerKey;
        _restartReadingOnPlay = true;
        unawaited(_setWakelockEnabled(false));
        unawaited(_mediaControlService.setPlaying(false));
        notifyListeners();
        return;
      }
      _isPaused = false;
      _readingSession = null;
      _speechOwnerKey = '';
      _restartReadingOnPlay = false;
      _clearSleepTimer(notify: false);
      unawaited(_setWakelockEnabled(false));
      unawaited(_mediaControlService.stop());
      notifyListeners();
    };
    _ttsService.onInterrupted = () {
      unawaited(_handleServiceInterruption());
    };
    _ttsService.onProgress = (startOffset, endOffset, word) {
      _currentStartOffset = _textStartOffset + startOffset;
      _currentEndOffset = _textStartOffset + endOffset;
      _currentWord = word;
      notifyListeners();
    };
    _mediaControlService.bindControls(
      owner: this,
      onPrevious: () async {
        await skipReadingChapter(-1);
      },
      onPlay: () async {
        await playReadingSession();
      },
      onPause: () async {
        await pauseSpeaking();
      },
      onNext: () async {
        await skipReadingChapter(1);
      },
      onStop: stopSpeaking,
    );
    _settingsLoadFuture = loadSettings();
  }

  final TtsService _ttsService;
  final TtsMediaControlService _mediaControlService;
  final StorageService _storage = StorageService();
  late final Future<void> _settingsLoadFuture;
  TtsSettings _settings = const TtsSettings();
  bool _isSpeaking = false;
  bool _isPaused = false;
  bool _isStarting = false;
  double _speed = 0.5;
  int _textStartOffset = 0;
  int _currentStartOffset = -1;
  int _currentEndOffset = -1;
  String _currentWord = '';
  String _lastErrorMessage = '';
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndsAt;
  bool _handlingServiceComplete = false;
  bool _handlingServiceInterruption = false;
  String _speechOwnerKey = '';
  _TtsReadingSession? _readingSession;
  bool _changingReadingChapter = false;
  bool _isUpdatingSettings = false;
  bool _restartReadingOnPlay = false;

  bool get isSpeaking => _isSpeaking;
  bool get isPaused => _isPaused;
  bool get isStarting => _isStarting;
  bool get isUpdatingSettings => _isUpdatingSettings;
  double get speed => _speed;
  int get textStartOffset => _textStartOffset;
  int get currentStartOffset => _currentStartOffset;
  int get currentEndOffset => _currentEndOffset;
  String get currentWord => _currentWord;
  String get lastErrorMessage => _lastErrorMessage;
  TtsSettings get settings => _settings;
  Future<void> get settingsLoaded => _settingsLoadFuture;
  TtsMediaControlService get mediaControlService => _mediaControlService;
  bool get hasActiveReadingSession => _readingSession != null;
  Novel? get activeNovel => _readingSession?.novel;
  List<Chapter> get activeChapters =>
      _readingSession?.chapters ?? const <Chapter>[];
  int get activeChapterIndex => _readingSession?.chapterIndex ?? -1;
  String get activeChapterTitle => _readingSession?.chapter.title ?? '';
  String get activeChapterContent => _readingSession?.content ?? '';
  bool get canSkipToPreviousChapter {
    final session = _readingSession;
    if (session == null || session.chapterIndex <= 0) return false;
    return session.canOpenChapter(session.chapterIndex - 1);
  }

  bool get canSkipToNextChapter {
    final session = _readingSession;
    if (session == null ||
        session.chapterIndex >= session.chapters.length - 1) {
      return false;
    }
    return session.canOpenChapter(session.chapterIndex + 1);
  }

  double get activeChapterProgress {
    final session = _readingSession;
    if (session == null || session.content.isEmpty) return 0;
    final position = _currentStartOffset.clamp(0, session.content.length);
    return position / session.content.length;
  }

  bool isOwnedBy(String ownerKey) =>
      ownerKey.isNotEmpty && _speechOwnerKey == ownerKey;
  bool get hasSleepTimer => _sleepTimerEndsAt != null;
  DateTime? get sleepTimerEndsAt => _sleepTimerEndsAt;
  Duration get sleepTimerRemaining {
    final endsAt = _sleepTimerEndsAt;
    if (endsAt == null) return Duration.zero;
    final remaining = endsAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void updateAuthToken(String token) {
    _ttsService.authToken = token;
  }

  Future<void> loadSettings() async {
    final saved = await _storage.getTtsSettings();
    if (saved != null) {
      _settings = TtsSettings.fromJson(saved);
      _ttsService.settings = _settings;
      notifyListeners();
    }
  }

  Future<bool> updateSettings(TtsSettings settings) async {
    await _settingsLoadFuture;
    if (_settings.engine == settings.engine &&
        _settings.systemVoiceName == settings.systemVoiceName &&
        _settings.systemVoiceLocale == settings.systemVoiceLocale &&
        _settings.iflytekVoiceName == settings.iflytekVoiceName &&
        _settings.iflytekVoiceLabel == settings.iflytekVoiceLabel) {
      return true;
    }
    if (_isUpdatingSettings || _changingReadingChapter) {
      _lastErrorMessage = '正在切换朗读状态，请稍候';
      notifyListeners();
      return false;
    }

    _isUpdatingSettings = true;
    notifyListeners();
    final previousSettings = _settings;
    final readingSession = _readingSession;
    final wasPaused = _isPaused;
    final readingPosition = readingSession == null
        ? 0
        : (_currentStartOffset >= 0 ? _currentStartOffset : _textStartOffset)
              .clamp(0, readingSession.content.length)
              .toInt();

    try {
      if (readingSession == null) {
        if (_isSpeaking || _isPaused || _isStarting) {
          await stopSpeaking();
        }
        _settings = settings;
        _ttsService.settings = settings;
        _lastErrorMessage = '';
        await persistTtsSettings(settings);
        return true;
      }

      await _persistReadingProgress(readingSession, position: readingPosition);
      await _stopSpeechForChapterTransition();
      _settings = settings;
      _ttsService.settings = settings;

      if (_readingSession != readingSession) {
        await persistTtsSettings(settings);
        return true;
      }

      _restoreReadingSessionPosition(
        readingSession,
        readingPosition,
        paused: wasPaused,
      );
      if (wasPaused) {
        _restartReadingOnPlay = true;
        _lastErrorMessage = '';
        await persistTtsSettings(settings);
        await _syncReadingMediaControls();
        return true;
      }

      final started = await _startSpeakingCore(
        readingSession.content.substring(readingPosition),
        startOffset: readingPosition,
        ownerKey: readingSession.ownerKey,
      );
      if (started) {
        await persistTtsSettings(settings);
        await _syncReadingMediaControls();
        return true;
      }
      if (_readingSession != readingSession) {
        await persistTtsSettings(settings);
        return true;
      }

      final switchError = _lastErrorMessage.isNotEmpty
          ? _lastErrorMessage
          : '新朗读引擎启动失败';
      _settings = previousSettings;
      _ttsService.settings = previousSettings;
      _restoreReadingSessionPosition(
        readingSession,
        readingPosition,
        paused: false,
      );
      final restored = await _startSpeakingCore(
        readingSession.content.substring(readingPosition),
        startOffset: readingPosition,
        ownerKey: readingSession.ownerKey,
      );
      if (!restored) {
        _restoreReadingSessionPosition(
          readingSession,
          readingPosition,
          paused: true,
        );
        _restartReadingOnPlay = true;
      }
      await _syncReadingMediaControls();
      _lastErrorMessage = switchError;
      return false;
    } catch (_) {
      _lastErrorMessage = '朗读引擎切换失败，请稍后重试';
      return false;
    } finally {
      _isUpdatingSettings = false;
      notifyListeners();
    }
  }

  @protected
  Future<void> persistTtsSettings(TtsSettings settings) {
    return _storage.saveTtsSettings(settings.toJson());
  }

  Future<List<TtsSystemVoice>> loadSystemVoices() async {
    await _settingsLoadFuture;
    final rawVoices = await _ttsService.voices;
    final voices = <TtsSystemVoice>[];
    final seen = <String>{};
    for (final raw in rawVoices) {
      if (raw is! Map) continue;
      final name = raw['name']?.toString().trim() ?? '';
      final locale = raw['locale']?.toString().trim() ?? '';
      if (name.isEmpty || locale.isEmpty) continue;
      if (!locale.toLowerCase().startsWith('zh')) continue;
      if (!seen.add('$name|$locale')) continue;
      voices.add(TtsSystemVoice(name: name, locale: locale));
    }
    voices.sort((a, b) => a.label.compareTo(b.label));
    return voices;
  }

  Future<bool> startReadingSession({
    required Novel novel,
    required List<Chapter> chapters,
    required int chapterIndex,
    required String content,
    required int startOffset,
    required TtsChapterContentLoader loadChapterContent,
    required TtsProgressSaver saveProgress,
    required TtsChapterAccessCheck canOpenChapter,
  }) async {
    if (chapters.isEmpty || content.isEmpty) return false;
    final safeChapterIndex = chapterIndex.clamp(0, chapters.length - 1).toInt();
    if (_isSpeaking || _isPaused || _isStarting || _readingSession != null) {
      await stopSpeaking();
    }

    final session = _TtsReadingSession(
      novel: novel,
      chapters: List<Chapter>.unmodifiable(chapters),
      chapterIndex: safeChapterIndex,
      content: content,
      loadChapterContent: loadChapterContent,
      saveProgress: saveProgress,
      canOpenChapter: canOpenChapter,
    );
    _readingSession = session;
    final started = await _startSpeakingCore(
      content.substring(startOffset.clamp(0, content.length)),
      startOffset: startOffset.clamp(0, content.length),
      ownerKey: session.ownerKey,
    );
    if (!started) {
      if (_readingSession == session && _ttsService.lastErrorIsRecoverable) {
        _isPaused = true;
        _speechOwnerKey = session.ownerKey;
        _restartReadingOnPlay = true;
        await _syncReadingMediaControls();
        notifyListeners();
        return false;
      }
      _readingSession = null;
      _speechOwnerKey = '';
      await _mediaControlService.stop();
      notifyListeners();
      return false;
    }
    await _syncReadingMediaControls();
    return true;
  }

  Future<bool> playReadingSession() async {
    final session = _readingSession;
    if (session == null || _isStarting || _isUpdatingSettings) return false;
    if (_isSpeaking && !_isPaused) {
      await _syncReadingMediaControls();
      return true;
    }
    if (_isPaused && !_restartReadingOnPlay && await resumeSpeaking()) {
      return true;
    }

    final position = _currentStartOffset >= 0
        ? _currentStartOffset.clamp(0, session.content.length).toInt()
        : 0;
    await _stopSpeechForChapterTransition();
    final started = await _startSpeakingCore(
      session.content.substring(position),
      startOffset: position,
      ownerKey: session.ownerKey,
    );
    if (started) await _syncReadingMediaControls();
    return started;
  }

  Future<bool> skipReadingChapter(int delta) async {
    final session = _readingSession;
    if (session == null ||
        delta == 0 ||
        _changingReadingChapter ||
        _isUpdatingSettings) {
      return false;
    }
    final targetIndex = session.chapterIndex + delta;
    if (targetIndex < 0 || targetIndex >= session.chapters.length) {
      await _syncReadingMediaControls();
      return false;
    }
    if (!session.canOpenChapter(targetIndex)) {
      await _syncReadingMediaControls();
      return false;
    }

    _changingReadingChapter = true;
    try {
      final targetChapter = session.chapters[targetIndex];
      final targetContent = await session.loadChapterContent(targetChapter);
      if (targetContent.trim().isEmpty || _readingSession != session) {
        return false;
      }

      await _persistReadingProgress(session);
      await _stopSpeechForChapterTransition();
      if (_readingSession != session) return false;

      session
        ..chapterIndex = targetIndex
        ..content = targetContent;
      _textStartOffset = 0;
      _currentStartOffset = 0;
      _currentEndOffset = 0;
      _currentWord = '';
      notifyListeners();
      await _persistReadingProgress(session, position: 0);

      final started = await _startSpeakingCore(
        targetContent,
        startOffset: 0,
        ownerKey: session.ownerKey,
      );
      if (started) await _syncReadingMediaControls();
      return started;
    } catch (_) {
      _lastErrorMessage = '章节切换失败，请稍后重试';
      notifyListeners();
      return false;
    } finally {
      _changingReadingChapter = false;
    }
  }

  Future<bool> startSpeaking(
    String text, {
    int startOffset = 0,
    String ownerKey = '',
  }) async {
    if (_readingSession != null) {
      await stopSpeaking();
    }
    return _startSpeakingCore(
      text,
      startOffset: startOffset,
      ownerKey: ownerKey,
    );
  }

  Future<bool> _startSpeakingCore(
    String text, {
    required int startOffset,
    required String ownerKey,
  }) async {
    await _settingsLoadFuture;
    if (_isStarting || text.trim().isEmpty) return false;
    _isStarting = true;
    _speechOwnerKey = ownerKey;
    _textStartOffset = startOffset;
    _currentStartOffset = startOffset;
    _currentEndOffset = startOffset;
    _currentWord = '';
    _lastErrorMessage = '';
    notifyListeners();
    var started = false;
    try {
      await _setWakelockEnabled(true);
      _ttsService.settings = _settings;
      final result = await _ttsService.speak(text);
      started = result;
      _lastErrorMessage = result ? '' : _ttsService.lastErrorMessage;
      _isSpeaking = result;
      _isPaused =
          !result &&
          _readingSession != null &&
          _ttsService.lastErrorIsRecoverable;
      if (result) _restartReadingOnPlay = false;
      if (_isPaused) _restartReadingOnPlay = true;
      if (!result) {
        await _setWakelockEnabled(false);
      }
    } finally {
      _isStarting = false;
    }
    notifyListeners();
    return started;
  }

  Future<void> stopSpeaking({bool clearSleepTimer = true}) async {
    final session = _readingSession;
    if (session != null) {
      await _persistReadingProgress(session);
    }
    _readingSession = null;
    _restartReadingOnPlay = false;
    await _stopSpeechForChapterTransition();
    _lastErrorMessage = '';
    if (clearSleepTimer) {
      _clearSleepTimer(notify: false);
    }
    await _mediaControlService.stop();
    notifyListeners();
  }

  Future<void> _stopSpeechForChapterTransition() async {
    await _ttsService.stop();
    _isStarting = false;
    _isSpeaking = false;
    _isPaused = false;
    _currentStartOffset = -1;
    _currentEndOffset = -1;
    _currentWord = '';
    _speechOwnerKey = '';
    _restartReadingOnPlay = false;
    await _setWakelockEnabled(false);
  }

  void _restoreReadingSessionPosition(
    _TtsReadingSession session,
    int position, {
    required bool paused,
  }) {
    _textStartOffset = position;
    _currentStartOffset = position;
    _currentEndOffset = position;
    _currentWord = '';
    _speechOwnerKey = session.ownerKey;
    _isSpeaking = false;
    _isPaused = paused;
  }

  void setSleepTimer(Duration duration) {
    if (duration <= Duration.zero) {
      clearSleepTimer();
      return;
    }
    _sleepTimer?.cancel();
    _sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final endsAt = _sleepTimerEndsAt;
      if (endsAt == null) return;
      if (!DateTime.now().isBefore(endsAt)) {
        unawaited(_handleSleepTimerElapsed());
        return;
      }
      notifyListeners();
    });
    notifyListeners();
  }

  void clearSleepTimer() {
    _clearSleepTimer();
  }

  void _clearSleepTimer({bool notify = true}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndsAt = null;
    if (notify) notifyListeners();
  }

  Future<void> _handleSleepTimerElapsed() async {
    if (_sleepTimerEndsAt == null) return;
    _clearSleepTimer(notify: false);
    if (_isSpeaking || _isPaused || _isStarting || _readingSession != null) {
      await stopSpeaking(clearSleepTimer: false);
    } else {
      notifyListeners();
    }
  }

  Future<void> _handleSpeakingComplete() async {
    try {
      _isSpeaking = false;
      _isPaused = false;
      final readingSession = _readingSession;
      if (readingSession != null) {
        _currentStartOffset = readingSession.content.length;
        _currentEndOffset = readingSession.content.length;
        await _persistReadingProgress(
          readingSession,
          position: readingSession.content.length,
        );
        if (canSkipToNextChapter && await skipReadingChapter(1)) {
          return;
        }
        _readingSession = null;
        _speechOwnerKey = '';
        _restartReadingOnPlay = false;
      }

      _currentStartOffset = -1;
      _currentEndOffset = -1;
      _currentWord = '';
      _clearSleepTimer(notify: false);
      await _setWakelockEnabled(false);
      await _mediaControlService.stop();
      notifyListeners();
    } finally {
      _handlingServiceComplete = false;
    }
  }

  Future<bool> pauseSpeaking() async {
    if (_isUpdatingSettings) return false;
    final paused = await _ttsService.pause();
    if (!paused) return false;
    _isPaused = true;
    final readingSession = _readingSession;
    if (readingSession != null) {
      await _persistReadingProgress(readingSession);
    }
    await _setWakelockEnabled(false);
    await _mediaControlService.setPlaying(false);
    notifyListeners();
    return true;
  }

  Future<void> _handleServiceInterruption() async {
    if (_handlingServiceInterruption || _isPaused) return;
    final readingSession = _readingSession;
    if (readingSession == null || (!_isSpeaking && !_isStarting)) return;

    _handlingServiceInterruption = true;
    _isStarting = false;
    _isSpeaking = false;
    _isPaused = true;
    _speechOwnerKey = readingSession.ownerKey;
    _restartReadingOnPlay = true;
    notifyListeners();
    try {
      await checkpointActiveReadingProgress();
      await _setWakelockEnabled(false);
      await _mediaControlService.setPlaying(false);
    } finally {
      _handlingServiceInterruption = false;
    }
  }

  Future<void> checkpointActiveReadingProgress() async {
    final readingSession = _readingSession;
    if (readingSession == null) return;
    await _persistReadingProgress(readingSession);
  }

  Future<void> _persistReadingProgress(
    _TtsReadingSession session, {
    int? position,
  }) async {
    if (_readingSession != session || session.content.isEmpty) return;
    final safePosition = (position ?? _currentStartOffset)
        .clamp(0, session.content.length)
        .toInt();
    final chapter = session.chapter;
    final progress = ReadingProgress(
      novelId: session.novel.id,
      chapterIndex: session.chapterIndex,
      scrollPosition: safePosition / session.content.length,
      charPosition: safePosition,
      chapterTitle: chapter.title,
      chapterUrl: chapter.url,
    );
    try {
      await session.saveProgress(progress);
    } catch (_) {
      // Playback must remain responsive when a best-effort progress write fails.
    }
  }

  Future<void> _syncReadingMediaControls() async {
    final session = _readingSession;
    if (session == null) return;
    await _mediaControlService.show(
      novel: session.novel,
      chapterTitle: session.chapter.title,
      playing: _isSpeaking && !_isPaused,
    );
  }

  Future<bool> resumeSpeaking() async {
    final resumed = await _ttsService.resume();
    if (!resumed) return false;
    _isSpeaking = true;
    _isPaused = false;
    _restartReadingOnPlay = false;
    await _setWakelockEnabled(true);
    await _mediaControlService.setPlaying(true);
    notifyListeners();
    return true;
  }

  Future<void> _setWakelockEnabled(bool enabled) async {
    try {
      await WakelockPlus.toggle(enable: enabled);
    } catch (_) {}
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _ttsService.setRate(speed);
    notifyListeners();
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _mediaControlService.unbindControls(this);
    unawaited(_setWakelockEnabled(false));
    unawaited(_disposeTtsService());
    super.dispose();
  }

  Future<void> _disposeTtsService() async {
    try {
      await _ttsService.dispose();
    } catch (_) {}
  }
}

class _TtsReadingSession {
  _TtsReadingSession({
    required this.novel,
    required this.chapters,
    required this.chapterIndex,
    required this.content,
    required this.loadChapterContent,
    required this.saveProgress,
    required this.canOpenChapter,
  });

  final Novel novel;
  final List<Chapter> chapters;
  int chapterIndex;
  String content;
  final TtsChapterContentLoader loadChapterContent;
  final TtsProgressSaver saveProgress;
  final TtsChapterAccessCheck canOpenChapter;

  Chapter get chapter => chapters[chapterIndex];
  String get ownerKey => 'novel:${novel.id}';
}
