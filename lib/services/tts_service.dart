import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/tts_settings.dart';
import 'iflytek_tts_service.dart';
import 'tts_audio_session.dart';

class TtsService {
  static const int _systemMaxChunkLength = 3500;
  static const int _iflytekMaxChunkLength = 180;

  late final FlutterTts _flutterTts;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final IflytekTtsService _iflytekTts = IflytekTtsService();
  final TtsAudioSessionPort _audioSession;
  TtsSettings settings = const TtsSettings();
  String authToken = '';
  VoidCallback? onStart;
  VoidCallback? onComplete;
  VoidCallback? onError;
  VoidCallback? onInterrupted;
  void Function(String message)? onErrorMessage;
  void Function(int startOffset, int endOffset, String word)? onProgress;
  bool _isInitialized = false;
  bool _isStarting = false;
  bool _isSpeaking = false;
  bool _isPaused = false;
  double _volume = 0.85;
  double _rate = 0.5;
  double _pitch = 1.0;
  String _currentText = '';
  int _currentPos = 0;
  List<_TtsChunk> _chunks = const [];
  int _chunkIndex = 0;
  int _speakToken = 0;
  bool _isStopping = false;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _playerPositionSubscription;
  StreamSubscription<Duration>? _playerDurationSubscription;
  StreamSubscription<TtsAudioInterruptionEvent>? _audioInterruptionSubscription;
  String _lastErrorMessage = '';
  Duration _currentAudioDuration = Duration.zero;
  Future<_IflytekPrefetchResult>? _prefetchedIflytekAudio;
  int _prefetchedIflytekIndex = -1;
  bool _systemEnginePrepared = false;
  _SystemUtterancePhase _systemUtterancePhase = _SystemUtterancePhase.idle;
  int _systemUtteranceToken = 0;
  int _systemUtteranceChunkIndex = -1;
  bool _currentSystemUtteranceStartedNatively = false;
  bool _handlingAudioInterruption = false;
  final List<DateTime> _expectedNativeInterruptionDeadlines = <DateTime>[];
  int _armedIntentionalSystemUtteranceToken = 0;
  int _armedIntentionalSystemUtteranceChunkIndex = -1;

  bool get isSpeaking => _isSpeaking;
  bool get isPaused => _isPaused;
  double get volume => _volume;
  double get rate => _rate;
  double get pitch => _pitch;
  String get currentText => _currentText;
  int get currentPos => _currentPos;
  String get lastErrorMessage => _lastErrorMessage;
  bool get lastErrorIsRecoverable => _lastErrorIsRecoverable;

  bool _lastErrorIsRecoverable = false;

  TtsService({TtsAudioSessionPort? audioSession})
    : _audioSession = audioSession ?? SystemTtsAudioSession() {
    _flutterTts = FlutterTts();
    _init();
    _audioInterruptionSubscription = _audioSession.events.listen((event) {
      if (event.begin) unawaited(_handleAudioInterruption());
    });
    _playerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((
      state,
    ) {
      if (_isStopping || settings.useIflytek == false) return;
      if (state == PlayerState.completed) {
        unawaited(_handleIflytekChunkComplete(_speakToken));
      }
    });
    _playerDurationSubscription = _audioPlayer.onDurationChanged.listen((
      duration,
    ) {
      _currentAudioDuration = duration;
    });
    _playerPositionSubscription = _audioPlayer.onPositionChanged.listen((
      position,
    ) {
      _updateIflytekProgress(position);
    });
  }

  Future<void> _init() async {
    try {
      Future<void> trySet(Future<dynamic> Function() action) async {
        try {
          await action().timeout(const Duration(seconds: 2));
        } catch (_) {
          // Keep TTS usable even when a device rejects one optional setting.
        }
      }

      await trySet(() => _flutterTts.setLanguage('zh-CN'));
      await trySet(() => _flutterTts.setSpeechRate(_rate));
      await trySet(() => _flutterTts.setVolume(_volume));
      await trySet(() => _flutterTts.setPitch(_pitch));
      await trySet(() => _flutterTts.awaitSpeakCompletion(false));
      await trySet(
        () => _audioPlayer.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              contentType: AndroidContentType.speech,
              usageType: AndroidUsageType.media,
              audioFocus: AndroidAudioFocus.none,
            ),
          ),
        ),
      );

      _flutterTts.setStartHandler(_handleNativeSystemStart);

      _flutterTts.setCompletionHandler(_handleSystemComplete);

      _flutterTts.setPauseHandler(_handleUnexpectedSystemInterruption);

      _flutterTts.setCancelHandler(_handleUnexpectedSystemInterruption);

      _flutterTts.setProgressHandler((
        String text,
        int startOffset,
        int endOffset,
        String word,
      ) {
        if (!_hasCurrentSystemUtterance) return;

        final chunk = _chunks[_chunkIndex];
        if (text != chunk.text) return;
        _confirmCurrentSystemUtteranceStartedNatively();
        if (_systemUtterancePhase == _SystemUtterancePhase.submitting) {
          return;
        }
        if (_systemUtterancePhase == _SystemUtterancePhase.queued) {
          _handleSystemStart();
        }
        if (_systemUtterancePhase != _SystemUtterancePhase.started) return;

        final chunkOffset = chunk.offset;
        _currentPos = chunkOffset + startOffset;
        onProgress?.call(
          chunkOffset + startOffset,
          chunkOffset + endOffset,
          word,
        );
      });

      _flutterTts.setErrorHandler((msg) {
        if (!_hasCurrentSystemUtterance) return;
        final token = _speakToken;
        _invalidateSystemUtterance();
        _chunks = const [];
        _isSpeaking = false;
        _isPaused = false;
        _lastErrorMessage = '系统语音朗读中断，请重新开始朗读';
        _lastErrorIsRecoverable = false;
        unawaited(_finishSystemError(token));
      });

      _isInitialized = true;
    } catch (e) {
      _isInitialized = false;
    }
  }

  Future<bool> speak(String text) async {
    if (_isStarting) return false;
    _prepareIntentionalSystemStop();
    final token = ++_speakToken;
    _isStarting = true;
    _lastErrorMessage = '';
    _lastErrorIsRecoverable = false;
    try {
      if (!_isInitialized) {
        await _init().timeout(const Duration(seconds: 3), onTimeout: () {});
        if (token != _speakToken) return false;
      }
      if (!_isInitialized || token != _speakToken) return false;

      _isStopping = true;
      _prepareIntentionalSystemStop();
      _chunks = const [];
      _clearIflytekPrefetch();
      _chunkIndex = 0;
      await _stopNative();
      if (token != _speakToken) return false;
      _isStopping = false;
      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (token != _speakToken) return false;

      final cleanText = _normalizeText(text);
      if (cleanText.isEmpty) {
        _isStarting = false;
        return false;
      }

      _currentText = cleanText;
      _currentPos = 0;
      _chunks = _splitIntoChunks(
        cleanText,
        maxChunkLength: settings.useIflytek
            ? _iflytekMaxChunkLength
            : _systemMaxChunkLength,
        splitAtSentence: !settings.useIflytek,
      );
      _chunkIndex = 0;
      if (settings.useIflytek) {
        if (authToken.trim().isEmpty) {
          _lastErrorMessage = '使用科大讯飞朗读需要先登录';
          onErrorMessage?.call(_lastErrorMessage);
          return false;
        }
      }

      if (!await _activateAudioSession()) {
        _lastErrorMessage = '其他应用正在占用音频，请稍后点击继续';
        _lastErrorIsRecoverable = true;
        onErrorMessage?.call(_lastErrorMessage);
        return false;
      }
      if (token != _speakToken) {
        await _deactivateAudioSession();
        return false;
      }

      final started = settings.useIflytek
          ? await _speakIflytekChunk(token)
          : await (() async {
              await _applySelectedSystemVoice();
              return _speakSystemChunk(token);
            })();
      if (!started) await _deactivateAudioSession();
      return started;
    } catch (e) {
      if (token == _speakToken) {
        final failure = _friendlyTtsFailure(e);
        _lastErrorMessage = failure.message;
        _lastErrorIsRecoverable = failure.recoverable;
        onErrorMessage?.call(_lastErrorMessage);
      }
      await _deactivateAudioSession();
      return false;
    } finally {
      if (token == _speakToken) _isStopping = false;
      _isStarting = false;
    }
  }

  Future<bool> stop() async {
    _prepareIntentionalSystemStop();
    final token = ++_speakToken;
    try {
      _isStopping = true;
      _prepareIntentionalSystemStop();
      _chunks = const [];
      _clearIflytekPrefetch();
      _chunkIndex = 0;
      await _stopNative();
      if (token != _speakToken) return true;
      _isSpeaking = false;
      _isPaused = false;
      _currentPos = 0;
      return true;
    } catch (e) {
      return false;
    } finally {
      await _deactivateAudioSession();
      if (token == _speakToken) _isStopping = false;
    }
  }

  Future<bool> pause() async {
    if (_isPaused) return true;
    if (!_isSpeaking && !_isStarting) return false;
    try {
      _isStopping = true;
      _prepareIntentionalSystemStop();
      if (settings.useIflytek) {
        await _audioPlayer.pause();
        if (_audioPlayer.state != PlayerState.paused) return false;
        _isSpeaking = false;
        _isPaused = true;
        await _deactivateAudioSession();
        return true;
      }

      // flutter_tts.pause() is not implemented consistently by Android TTS
      // engines. Some engines report success while speech keeps playing. Stop
      // the native utterance instead and keep _currentPos so resume() can
      // restart from the last progress callback.
      if (Platform.isAndroid) {
        _invalidateSystemUtterance();
        await _flutterTts.stop().timeout(
          const Duration(seconds: 2),
          onTimeout: () => null,
        );
        _isSpeaking = false;
        _isPaused = true;
        await _deactivateAudioSession();
        return true;
      }
      final result = await _flutterTts.pause().timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      _isSpeaking = result != 1;
      _isPaused = result == 1;
      if (_isPaused) await _deactivateAudioSession();
      return _isPaused;
    } catch (e) {
      return false;
    } finally {
      _isStopping = false;
    }
  }

  Future<bool> resume() async {
    _prepareIntentionalSystemStop();
    final token = ++_speakToken;
    try {
      if (!await _activateAudioSession()) return false;
      if (token != _speakToken) {
        await _deactivateAudioSession();
        return false;
      }
      if (settings.useIflytek) {
        await _audioPlayer.resume();
        if (token != _speakToken) {
          await _deactivateAudioSession();
          return false;
        }
        _isPaused = false;
        _isSpeaking = true;
        return true;
      }
      if (_currentText.isEmpty) {
        await _deactivateAudioSession();
        return false;
      }

      _isStopping = true;
      _prepareIntentionalSystemStop();
      _chunks = const [];
      _clearIflytekPrefetch();
      _chunkIndex = 0;
      await _stopNative();
      if (token != _speakToken) {
        await _deactivateAudioSession();
        return false;
      }
      _isStopping = false;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (token != _speakToken) {
        await _deactivateAudioSession();
        return false;
      }

      final resumeOffset = _currentPos.clamp(0, _currentText.length).toInt();
      final resumeText = _currentText.substring(resumeOffset);
      _chunks = _splitIntoChunks(
        resumeText,
        baseOffset: resumeOffset,
        splitAtSentence: true,
      );
      _chunkIndex = 0;
      _isPaused = false;
      final resumed = await _speakSystemChunk(token);
      if (!resumed) await _deactivateAudioSession();
      return resumed;
    } catch (e) {
      await _deactivateAudioSession();
      return false;
    } finally {
      if (token == _speakToken) _isStopping = false;
    }
  }

  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _flutterTts.setVolume(volume);
    await _audioPlayer.setVolume(volume.clamp(0.0, 1.0));
  }

  Future<void> setRate(double rate) async {
    _rate = rate;
    await _flutterTts.setSpeechRate(rate);
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch;
    await _flutterTts.setPitch(pitch);
  }

  String _normalizeText(String text) {
    return text
        .replaceAll(
          RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'),
          ' ',
        )
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), ' ');
  }

  Future<bool> _activateAudioSession() async {
    try {
      await _audioSession.configureForSpeech();
      return await _audioSession.activate();
    } catch (_) {
      return false;
    }
  }

  Future<void> _deactivateAudioSession() async {
    try {
      await _audioSession.deactivate();
    } catch (_) {}
  }

  Future<void> _handleAudioInterruption() async {
    if (_handlingAudioInterruption ||
        _isStopping ||
        _isPaused ||
        (!_isSpeaking && !_isStarting)) {
      return;
    }
    _handlingAudioInterruption = true;
    try {
      final interrupted = _isStarting && !_isSpeaking
          ? await _interruptPendingStart()
          : await pause();
      if (!interrupted) return;
      onInterrupted?.call();
    } finally {
      _handlingAudioInterruption = false;
    }
  }

  void _handleUnexpectedSystemInterruption() {
    if ((_isStopping ||
            !_hasCurrentSystemUtterance ||
            !_currentSystemUtteranceStartedNatively) &&
        _consumeExpectedNativeInterruptionCallback()) {
      return;
    }
    if (_handlingAudioInterruption ||
        _isStopping ||
        _isPaused ||
        (!_isSpeaking && !_isStarting) ||
        !_hasCurrentSystemUtterance) {
      return;
    }

    _handlingAudioInterruption = true;
    if (_isStarting && !_isSpeaking) {
      unawaited(_finishPendingSystemInterruption());
      return;
    }
    _invalidateSystemUtterance();
    _isSpeaking = false;
    _isPaused = true;
    unawaited(_finishUnexpectedSystemInterruption());
  }

  Future<void> _finishPendingSystemInterruption() async {
    try {
      if (await _interruptPendingStart(armExpectedNativeCallback: false)) {
        onInterrupted?.call();
      }
    } finally {
      _handlingAudioInterruption = false;
    }
  }

  Future<bool> _interruptPendingStart({
    bool armExpectedNativeCallback = true,
  }) async {
    if (!_isStarting || _isSpeaking) return false;
    if (armExpectedNativeCallback) _prepareIntentionalSystemStop();
    final token = ++_speakToken;
    _isStopping = true;
    _chunks = const [];
    _clearIflytekPrefetch();
    _chunkIndex = 0;
    _invalidateSystemUtterance();
    try {
      try {
        await _audioPlayer.stop();
      } catch (_) {}
      try {
        await _flutterTts.stop().timeout(
          const Duration(milliseconds: 800),
          onTimeout: () => null,
        );
      } catch (_) {}
      if (token != _speakToken) return false;
      _isStarting = false;
      _isSpeaking = false;
      _isPaused = true;
      _lastErrorMessage = '朗读已被其他音频暂停，点击继续可恢复';
      _lastErrorIsRecoverable = true;
      await _deactivateAudioSession();
      return token == _speakToken;
    } finally {
      if (token == _speakToken) _isStopping = false;
    }
  }

  Future<void> _finishUnexpectedSystemInterruption() async {
    try {
      await _deactivateAudioSession();
      onInterrupted?.call();
    } finally {
      _handlingAudioInterruption = false;
    }
  }

  void _pruneExpectedNativeInterruptionCallbacks(DateTime now) {
    _expectedNativeInterruptionDeadlines.removeWhere(
      (deadline) => !now.isBefore(deadline),
    );
  }

  bool _consumeExpectedNativeInterruptionCallback() {
    final now = DateTime.now();
    _pruneExpectedNativeInterruptionCallbacks(now);
    if (_expectedNativeInterruptionDeadlines.isEmpty) return false;
    _expectedNativeInterruptionDeadlines.removeAt(0);
    return true;
  }

  void _prepareIntentionalSystemStop() {
    if (!_hasCurrentSystemUtterance) return;
    final token = _systemUtteranceToken;
    final chunkIndex = _systemUtteranceChunkIndex;
    if (_armedIntentionalSystemUtteranceToken == token &&
        _armedIntentionalSystemUtteranceChunkIndex == chunkIndex) {
      return;
    }
    _armedIntentionalSystemUtteranceToken = token;
    _armedIntentionalSystemUtteranceChunkIndex = chunkIndex;
    final now = DateTime.now();
    _pruneExpectedNativeInterruptionCallbacks(now);
    _expectedNativeInterruptionDeadlines.add(
      now.add(const Duration(seconds: 2)),
    );
  }

  Future<void> _stopNative() async {
    _prepareIntentionalSystemStop();
    _invalidateSystemUtterance();
    await _audioPlayer.stop();
    await _flutterTts.stop().timeout(
      const Duration(milliseconds: 800),
      onTimeout: () => null,
    );
  }

  Future<bool> _speakSystemChunk(int token) async {
    if (token != _speakToken || _chunkIndex >= _chunks.length) return false;

    await _prepareSystemTts();
    if (token != _speakToken) return false;

    final chunk = _chunks[_chunkIndex];
    if (chunk.text.trim().isEmpty) {
      if (_chunkIndex + 1 >= _chunks.length) return false;
      _chunkIndex++;
      return _speakSystemChunk(token);
    }

    final chunkIndex = _chunkIndex;
    _systemUtteranceToken = token;
    _systemUtteranceChunkIndex = chunkIndex;
    _currentSystemUtteranceStartedNatively = false;
    _systemUtterancePhase = _SystemUtterancePhase.submitting;

    final result = await _flutterTts
        .speak(chunk.text, focus: false)
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (token != _speakToken ||
        chunkIndex != _chunkIndex ||
        _systemUtteranceToken != token ||
        _systemUtteranceChunkIndex != chunkIndex ||
        _systemUtterancePhase != _SystemUtterancePhase.submitting) {
      return false;
    }

    _isSpeaking = result == 1;
    if (_isSpeaking) {
      _systemUtterancePhase = _SystemUtterancePhase.queued;
      // Some Android engines emit onStart before the MethodChannel call
      // returns, while others omit range callbacks entirely. Treat method
      // acceptance as the single public start edge, while retaining the
      // separate native-start flag as the cancel-generation fence.
      _handleSystemStart();
      _currentPos = chunk.offset;
      _emitChunkProgress(chunk);
    } else {
      _invalidateSystemUtterance();
    }
    return _isSpeaking;
  }

  bool get _hasCurrentSystemUtterance {
    return _systemUtterancePhase != _SystemUtterancePhase.idle &&
        _systemUtteranceToken == _speakToken &&
        _systemUtteranceChunkIndex == _chunkIndex &&
        _chunkIndex >= 0 &&
        _chunkIndex < _chunks.length;
  }

  void _handleSystemStart() {
    if (_isStopping ||
        !_hasCurrentSystemUtterance ||
        _systemUtterancePhase != _SystemUtterancePhase.queued) {
      return;
    }
    _systemUtterancePhase = _SystemUtterancePhase.started;
    _isSpeaking = true;
    _isPaused = false;
    onStart?.call();
  }

  void _handleNativeSystemStart() {
    if (_isStopping || !_hasCurrentSystemUtterance) return;
    _confirmCurrentSystemUtteranceStartedNatively();
    if (_systemUtterancePhase == _SystemUtterancePhase.queued) {
      _handleSystemStart();
    }
  }

  void _confirmCurrentSystemUtteranceStartedNatively() {
    if (_currentSystemUtteranceStartedNatively) return;
    _currentSystemUtteranceStartedNatively = true;
    // Android delivers the old utterance's onStop before the replacement's
    // onStart/onRangeStart through the same progress listener. flutter_tts
    // drops the utterance IDs, so only native start/progress is a safe fence;
    // a successful speak() result alone is not evidence that old callbacks
    // have drained.
    _expectedNativeInterruptionDeadlines.clear();
  }

  void _handleSystemComplete() {
    if (_isStopping ||
        !_hasCurrentSystemUtterance ||
        _systemUtterancePhase != _SystemUtterancePhase.started) {
      return;
    }
    final token = _systemUtteranceToken;
    _invalidateSystemUtterance();
    if (_chunkIndex + 1 < _chunks.length) {
      _chunkIndex++;
      unawaited(_speakSystemChunk(token));
      return;
    }

    _chunks = const [];
    _isSpeaking = false;
    _isPaused = false;
    unawaited(_finishSystemPlayback(token));
  }

  Future<void> _finishSystemPlayback(int token) async {
    await _deactivateAudioSession();
    if (token != _speakToken || _isSpeaking || _isPaused) return;
    onComplete?.call();
  }

  Future<void> _finishSystemError(int token) async {
    await _deactivateAudioSession();
    if (token != _speakToken || _isSpeaking || _isPaused) return;
    onErrorMessage?.call(_lastErrorMessage);
    onError?.call();
  }

  void _invalidateSystemUtterance() {
    _systemUtterancePhase = _SystemUtterancePhase.idle;
    _systemUtteranceToken = 0;
    _systemUtteranceChunkIndex = -1;
    _currentSystemUtteranceStartedNatively = false;
  }

  Future<void> _prepareSystemTts() async {
    if (Platform.isAndroid && !_systemEnginePrepared) {
      await _selectSystemEngine();
      _systemEnginePrepared = true;
    }
    await _applySystemTtsOptions();
  }

  Future<void> _selectSystemEngine() async {
    try {
      final rawEngines = await _flutterTts.getEngines.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      if (rawEngines is! List || rawEngines.isEmpty) return;

      final engines = rawEngines.map((engine) => engine.toString()).toList();
      final defaultEngine = (await _flutterTts.getDefaultEngine.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      ))?.toString();

      var selected = defaultEngine;
      if (selected == null || _looksLikeIflytekEngine(selected)) {
        selected = _preferredSystemEngine(engines);
      }
      if (selected == null || selected.isEmpty) return;

      await _flutterTts
          .setEngine(selected)
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
    } catch (_) {
      // The platform TTS engine list is best-effort; speech can continue with
      // the device default if engine selection is unavailable.
    }
  }

  String? _preferredSystemEngine(List<String> engines) {
    for (final engine in engines) {
      if (engine == 'com.google.android.tts') return engine;
    }
    for (final engine in engines) {
      if (!_looksLikeIflytekEngine(engine)) return engine;
    }
    return engines.isEmpty ? null : engines.first;
  }

  bool _looksLikeIflytekEngine(String engine) {
    final lower = engine.toLowerCase();
    return lower.contains('iflytek') ||
        lower.contains('xfyun') ||
        lower.contains('speechcloud');
  }

  Future<void> _applySystemTtsOptions() async {
    Future<void> trySet(Future<dynamic> Function() action) async {
      try {
        await action().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    await trySet(() => _flutterTts.setLanguage('zh-CN'));
    await trySet(() => _flutterTts.setSpeechRate(_rate));
    await trySet(() => _flutterTts.setVolume(_volume));
    await trySet(() => _flutterTts.setPitch(_pitch));
    await trySet(() => _flutterTts.awaitSpeakCompletion(false));
  }

  void _emitChunkProgress(_TtsChunk chunk) {
    final start = chunk.offset.clamp(0, _currentText.length).toInt();
    final end = min(start + 1, _currentText.length);
    _currentPos = start;
    onProgress?.call(start, end, '');
  }

  Future<bool> _speakIflytekChunk(int token) async {
    if (token != _speakToken || _chunkIndex >= _chunks.length) return false;

    final chunk = _chunks[_chunkIndex];
    if (chunk.text.trim().isEmpty) {
      if (_chunkIndex + 1 >= _chunks.length) return false;
      _chunkIndex++;
      return _speakIflytekChunk(token);
    }

    try {
      _currentPos = chunk.offset;
      onProgress?.call(
        chunk.offset,
        min(chunk.offset + 1, _currentText.length),
        '',
      );
      final audioBytes = await _loadIflytekAudioForChunk(_chunkIndex);
      if (token != _speakToken) return false;
      await _audioPlayer.setVolume(_volume.clamp(0.0, 1.0));
      _currentAudioDuration = Duration.zero;
      final audioFile = await _writeIflytekAudioFile(
        audioBytes,
        token,
        _chunkIndex,
      );
      if (token != _speakToken || _isStopping || _isPaused) return false;
      await _audioPlayer.play(DeviceFileSource(audioFile.path));
      if (token != _speakToken || _isStopping || _isPaused) {
        await _audioPlayer.stop();
        return false;
      }
      _isSpeaking = true;
      _isPaused = false;
      _lastErrorMessage = '';
      _lastErrorIsRecoverable = false;
      _prefetchNextIflytekChunk(token);
      onStart?.call();
      return true;
    } catch (e) {
      if (token == _speakToken) {
        _isSpeaking = false;
        _isPaused = false;
        final failure = _friendlyTtsFailure(e);
        _lastErrorMessage = failure.message;
        _lastErrorIsRecoverable = failure.recoverable;
        onErrorMessage?.call(_lastErrorMessage);
        onError?.call();
      }
      return false;
    }
  }

  Future<Uint8List> _loadIflytekAudioForChunk(int index) async {
    if (_prefetchedIflytekIndex == index && _prefetchedIflytekAudio != null) {
      final result = await _prefetchedIflytekAudio!;
      _clearIflytekPrefetch();
      if (result.error != null) {
        Error.throwWithStackTrace(result.error!, result.stackTrace!);
      }
      return result.bytes!;
    }
    return _synthesizeIflytekChunk(_chunks[index]);
  }

  Future<Uint8List> _synthesizeIflytekChunk(_TtsChunk chunk) {
    return _iflytekTts.synthesize(
      text: chunk.text,
      settings: settings,
      authToken: authToken,
      rate: _rate,
      volume: _volume,
      pitch: _pitch,
    );
  }

  void _prefetchNextIflytekChunk(int token) {
    final nextIndex = _chunkIndex + 1;
    if (token != _speakToken || nextIndex >= _chunks.length) return;
    _prefetchedIflytekIndex = nextIndex;
    _prefetchedIflytekAudio = _synthesizeIflytekChunk(_chunks[nextIndex]).then(
      _IflytekPrefetchResult.success,
      onError: (Object error, StackTrace stackTrace) =>
          _IflytekPrefetchResult.failure(error, stackTrace),
    );
  }

  void _clearIflytekPrefetch() {
    _prefetchedIflytekAudio = null;
    _prefetchedIflytekIndex = -1;
  }

  Future<File> _writeIflytekAudioFile(
    Uint8List bytes,
    int token,
    int chunkIndex,
  ) async {
    final cacheDir = await getTemporaryDirectory();
    final file = File(
      '${cacheDir.path}/novel_iflytek_${token}_$chunkIndex.mp3',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  void _updateIflytekProgress(Duration position) {
    if (!settings.useIflytek ||
        _isStopping ||
        _chunkIndex >= _chunks.length ||
        _currentAudioDuration.inMilliseconds <= 0) {
      return;
    }
    final chunk = _chunks[_chunkIndex];
    final ratio =
        (position.inMilliseconds / _currentAudioDuration.inMilliseconds).clamp(
          0.0,
          1.0,
        );
    final localOffset = (chunk.text.length * ratio).floor();
    final start = (chunk.offset + localOffset).clamp(
      chunk.offset,
      chunk.offset + chunk.text.length,
    );
    final end = min(start + 1, chunk.offset + chunk.text.length);
    _currentPos = start;
    onProgress?.call(start, end, '');
  }

  Future<void> _handleIflytekChunkComplete(int token) async {
    if (token != _speakToken || _isStopping || !settings.useIflytek) return;
    if (_chunkIndex + 1 < _chunks.length) {
      _chunkIndex++;
      await _speakIflytekChunk(token);
      return;
    }
    _isSpeaking = false;
    _isPaused = false;
    await _deactivateAudioSession();
    if (token != _speakToken) return;
    onComplete?.call();
  }

  List<_TtsChunk> _splitIntoChunks(
    String text, {
    int baseOffset = 0,
    int maxChunkLength = _systemMaxChunkLength,
    bool splitAtSentence = false,
  }) {
    if (splitAtSentence) {
      return _splitIntoSentenceChunks(
        text,
        baseOffset: baseOffset,
        maxChunkLength: maxChunkLength,
      );
    }

    if (text.length <= maxChunkLength) {
      return [_TtsChunk(text, baseOffset)];
    }

    final chunks = <_TtsChunk>[];
    var start = 0;
    while (start < text.length) {
      var end = (start + maxChunkLength).clamp(0, text.length).toInt();
      if (end < text.length) {
        final boundary = _lastSpeechBoundary(text, start, end);
        if (boundary > start) end = boundary;
      }

      final rawChunkText = text.substring(start, end);
      final chunkText = rawChunkText.trim();
      if (chunkText.isNotEmpty) {
        final leadingWhitespace =
            rawChunkText.length - rawChunkText.trimLeft().length;
        chunks.add(
          _TtsChunk(chunkText, baseOffset + start + leadingWhitespace),
        );
      }
      start = end;
      while (start < text.length && text[start].trim().isEmpty) {
        start++;
      }
    }

    return chunks;
  }

  List<_TtsChunk> _splitIntoSentenceChunks(
    String text, {
    required int baseOffset,
    required int maxChunkLength,
  }) {
    final chunks = <_TtsChunk>[];
    var start = 0;

    void addRange(int rawStart, int rawEnd) {
      var rangeStart = rawStart;
      var rangeEnd = rawEnd;
      while (rangeStart < rangeEnd && text[rangeStart].trim().isEmpty) {
        rangeStart++;
      }
      while (rangeEnd > rangeStart && text[rangeEnd - 1].trim().isEmpty) {
        rangeEnd--;
      }
      if (rangeStart >= rangeEnd) return;

      var partStart = rangeStart;
      while (partStart < rangeEnd) {
        var partEnd = min(partStart + maxChunkLength, rangeEnd);
        if (partEnd < rangeEnd) {
          final boundary = _lastSpeechBoundary(text, partStart, partEnd);
          if (boundary > partStart) partEnd = boundary;
        }
        final rawChunkText = text.substring(partStart, partEnd);
        final chunkText = rawChunkText.trim();
        if (chunkText.isNotEmpty) {
          final leadingWhitespace =
              rawChunkText.length - rawChunkText.trimLeft().length;
          chunks.add(
            _TtsChunk(chunkText, baseOffset + partStart + leadingWhitespace),
          );
        }
        partStart = partEnd;
        while (partStart < rangeEnd && text[partStart].trim().isEmpty) {
          partStart++;
        }
      }
    }

    for (var i = 0; i < text.length; i++) {
      if (_isSentenceBoundary(text[i])) {
        var end = i + 1;
        while (end < text.length && _isClosingPunctuation(text[end])) {
          end++;
        }
        addRange(start, end);
        start = end;
        i = end - 1;
      }
    }
    addRange(start, text.length);

    return chunks.isEmpty ? [_TtsChunk(text, baseOffset)] : chunks;
  }

  bool _isSentenceBoundary(String char) {
    const boundaries = '。！？!?；;\n';
    return boundaries.contains(char);
  }

  bool _isClosingPunctuation(String char) {
    const closings = '”’』」》）)]}';
    return closings.contains(char);
  }

  int _lastSpeechBoundary(String text, int start, int end) {
    const boundaries = '\u3002\uff01\uff1f!?\uff1b;\uff0c,\n ';
    for (var i = end - 1; i > start; i--) {
      if (boundaries.contains(text[i])) return i + 1;
    }
    return end;
  }

  Future<List<dynamic>> get voices async {
    return await _flutterTts.getVoices;
  }

  ({String message, bool recoverable}) _friendlyTtsFailure(Object error) {
    if (error is IflytekTtsException) {
      return (message: error.message, recoverable: error.isRetryable);
    }
    if (error is TimeoutException) {
      return (message: '语音服务响应超时，请检查网络后点击继续', recoverable: true);
    }
    if (error is StateError) {
      return (message: error.message, recoverable: false);
    }
    return (message: '语音播放失败，请稍后点击继续', recoverable: true);
  }

  Future<void> _applySelectedSystemVoice() async {
    final name = settings.systemVoiceName.trim();
    final locale = settings.systemVoiceLocale.trim();
    if (name.isEmpty) {
      await _flutterTts.setLanguage(locale.isEmpty ? 'zh-CN' : locale);
      return;
    }
    await _flutterTts.setVoice({
      'name': name,
      'locale': locale.isEmpty ? 'zh-CN' : locale,
    });
  }

  Future<void> dispose() async {
    _prepareIntentionalSystemStop();
    _speakToken++;
    _isStopping = true;
    _invalidateSystemUtterance();
    _chunks = const [];
    _clearIflytekPrefetch();
    await Future.wait<void>([
      if (_playerStateSubscription case final subscription?)
        subscription.cancel(),
      if (_playerPositionSubscription case final subscription?)
        subscription.cancel(),
      if (_playerDurationSubscription case final subscription?)
        subscription.cancel(),
      if (_audioInterruptionSubscription case final subscription?)
        subscription.cancel(),
    ]);
    await _deactivateAudioSession();
    await _audioSession.dispose();
    await _audioPlayer.dispose();
    await _flutterTts.stop();
    _isSpeaking = false;
    _isPaused = false;
    _isInitialized = false;
  }
}

class _TtsChunk {
  const _TtsChunk(this.text, this.offset);

  final String text;
  final int offset;
}

class _IflytekPrefetchResult {
  const _IflytekPrefetchResult.success(this.bytes)
    : error = null,
      stackTrace = null;

  const _IflytekPrefetchResult.failure(this.error, this.stackTrace)
    : bytes = null;

  final Uint8List? bytes;
  final Object? error;
  final StackTrace? stackTrace;
}

enum _SystemUtterancePhase { idle, submitting, queued, started }
