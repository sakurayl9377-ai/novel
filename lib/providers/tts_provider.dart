import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/tts_settings.dart';
import '../services/storage_service.dart';
import '../services/tts_media_control_service.dart';
import '../services/tts_service.dart';

class TtsProvider extends ChangeNotifier {
  TtsProvider({TtsMediaControlService? mediaControlService})
    : _mediaControlService =
          mediaControlService ?? TtsMediaControlService.disabled() {
    _ttsService.onStart = () {
      _isSpeaking = true;
      _isPaused = false;
      unawaited(_setWakelockEnabled(true));
      notifyListeners();
    };
    _ttsService.onComplete = () {
      if (_handlingServiceComplete) return;
      _handlingServiceComplete = true;
      unawaited(_handleSpeakingComplete());
    };
    _ttsService.onError = () {
      _isSpeaking = false;
      _isPaused = false;
      _lastErrorMessage = _ttsService.lastErrorMessage;
      _clearSleepTimer(notify: false);
      unawaited(_setWakelockEnabled(false));
      unawaited(_mediaControlService.stop());
      notifyListeners();
    };
    _ttsService.onProgress = (startOffset, endOffset, word) {
      _currentStartOffset = _textStartOffset + startOffset;
      _currentEndOffset = _textStartOffset + endOffset;
      _currentWord = word;
      notifyListeners();
    };
    loadSettings();
  }

  final TtsService _ttsService = TtsService();
  final TtsMediaControlService _mediaControlService;
  final StorageService _storage = StorageService();
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
  Object? _sleepTimerOwner;
  Future<void> Function()? _onSleepTimerElapsed;
  Object? _completionOwner;
  Future<bool> Function()? _onSpeakingComplete;
  bool _handlingServiceComplete = false;

  bool get isSpeaking => _isSpeaking;
  bool get isPaused => _isPaused;
  bool get isStarting => _isStarting;
  double get speed => _speed;
  int get textStartOffset => _textStartOffset;
  int get currentStartOffset => _currentStartOffset;
  int get currentEndOffset => _currentEndOffset;
  String get currentWord => _currentWord;
  String get lastErrorMessage => _lastErrorMessage;
  TtsSettings get settings => _settings;
  TtsMediaControlService get mediaControlService => _mediaControlService;
  bool get hasSleepTimer => _sleepTimerEndsAt != null;
  DateTime? get sleepTimerEndsAt => _sleepTimerEndsAt;
  Duration get sleepTimerRemaining {
    final endsAt = _sleepTimerEndsAt;
    if (endsAt == null) return Duration.zero;
    final remaining = endsAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void bindSleepTimer({
    required Object owner,
    required Future<void> Function() onElapsed,
  }) {
    _sleepTimerOwner = owner;
    _onSleepTimerElapsed = onElapsed;
  }

  void unbindSleepTimer(Object owner) {
    if (_sleepTimerOwner != owner) return;
    _sleepTimerOwner = null;
    _onSleepTimerElapsed = null;
  }

  void bindCompletion({
    required Object owner,
    required Future<bool> Function() onComplete,
  }) {
    _completionOwner = owner;
    _onSpeakingComplete = onComplete;
  }

  void unbindCompletion(Object owner) {
    if (_completionOwner != owner) return;
    _completionOwner = null;
    _onSpeakingComplete = null;
  }

  Future<void> loadSettings() async {
    final saved = await _storage.getTtsSettings();
    if (saved != null) {
      _settings = TtsSettings.fromJson(saved);
      _ttsService.settings = _settings;
      notifyListeners();
    }
  }

  Future<void> updateSettings(TtsSettings settings) async {
    final engineChanged = _settings.engine != settings.engine;
    if (engineChanged || _isSpeaking || _isStarting) {
      await _ttsService.stop();
      _isStarting = false;
      _isSpeaking = false;
      _isPaused = false;
      _currentStartOffset = -1;
      _currentEndOffset = -1;
      _currentWord = '';
      _clearSleepTimer(notify: false);
      await _setWakelockEnabled(false);
      await _mediaControlService.stop();
    }
    _settings = settings;
    _ttsService.settings = settings;
    await _storage.saveTtsSettings(settings.toJson());
    notifyListeners();
  }

  Future<bool> startSpeaking(String text, {int startOffset = 0}) async {
    if (_isStarting) return false;
    _isStarting = true;
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
      _isPaused = false;
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
    await _ttsService.stop();
    _isStarting = false;
    _isSpeaking = false;
    _isPaused = false;
    _currentStartOffset = -1;
    _currentEndOffset = -1;
    _currentWord = '';
    _lastErrorMessage = '';
    if (clearSleepTimer) {
      _clearSleepTimer(notify: false);
    }
    await _setWakelockEnabled(false);
    await _mediaControlService.stop();
    notifyListeners();
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
    final onElapsed = _onSleepTimerElapsed;
    if (onElapsed != null) {
      await onElapsed();
    }
    if (_isSpeaking || _isPaused || _isStarting) {
      await stopSpeaking(clearSleepTimer: false);
    } else {
      notifyListeners();
    }
  }

  Future<void> _handleSpeakingComplete() async {
    try {
      _isSpeaking = false;
      _isPaused = false;
      final onComplete = _onSpeakingComplete;
      if (onComplete != null) {
        final continued = await onComplete();
        if (continued) return;
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
    final paused = await _ttsService.pause();
    if (!paused) return false;
    _isPaused = true;
    await _setWakelockEnabled(false);
    await _mediaControlService.setPlaying(false);
    notifyListeners();
    return true;
  }

  Future<bool> resumeSpeaking() async {
    final resumed = await _ttsService.resume();
    if (!resumed) return false;
    _isSpeaking = true;
    _isPaused = false;
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
    unawaited(_setWakelockEnabled(false));
    _ttsService.dispose();
    super.dispose();
  }
}
