import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/tts_settings.dart';
import 'iflytek_tts_service.dart';

class TtsService {
  static const int _systemMaxChunkLength = 3500;
  static const int _iflytekMaxChunkLength = 180;

  late final FlutterTts _flutterTts;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final IflytekTtsService _iflytekTts = IflytekTtsService();
  TtsSettings settings = const TtsSettings();
  VoidCallback? onStart;
  VoidCallback? onComplete;
  VoidCallback? onError;
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
  String _lastErrorMessage = '';
  Duration _currentAudioDuration = Duration.zero;
  Future<Uint8List>? _prefetchedIflytekAudio;
  int _prefetchedIflytekIndex = -1;
  bool _systemEnginePrepared = false;

  bool get isSpeaking => _isSpeaking;
  bool get isPaused => _isPaused;
  double get volume => _volume;
  double get rate => _rate;
  double get pitch => _pitch;
  String get currentText => _currentText;
  int get currentPos => _currentPos;
  String get lastErrorMessage => _lastErrorMessage;

  TtsService() {
    _flutterTts = FlutterTts();
    _init();
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

      _flutterTts.setStartHandler(() {
        _isSpeaking = true;
        _isPaused = false;
        onStart?.call();
      });

      _flutterTts.setCompletionHandler(() {
        if (_isStopping) return;

        if (_chunkIndex + 1 < _chunks.length) {
          _chunkIndex++;
          final token = _speakToken;
          unawaited(_speakSystemChunk(token));
          return;
        }

        _isSpeaking = false;
        _isPaused = false;
        onComplete?.call();
      });

      _flutterTts.setProgressHandler((
        String text,
        int startOffset,
        int endOffset,
        String word,
      ) {
        if (_chunkIndex >= _chunks.length) return;

        final chunkOffset = _chunks[_chunkIndex].offset;
        _currentPos = chunkOffset + startOffset;
        onProgress?.call(
          chunkOffset + startOffset,
          chunkOffset + endOffset,
          word,
        );
      });

      _flutterTts.setErrorHandler((msg) {
        _isSpeaking = false;
        _isPaused = false;
        onError?.call();
      });

      _isInitialized = true;
    } catch (e) {
      _isInitialized = false;
    }
  }

  Future<bool> speak(String text) async {
    if (_isStarting) return false;
    if (!_isInitialized) {
      await _init().timeout(const Duration(seconds: 3), onTimeout: () {});
    }
    if (!_isInitialized) return false;
    try {
      _isStarting = true;
      _isStopping = true;
      _speakToken++;
      _chunks = const [];
      _clearIflytekPrefetch();
      _chunkIndex = 0;
      await _stopNative();
      _isStopping = false;
      await Future<void>.delayed(const Duration(milliseconds: 160));

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
      final token = _speakToken;
      return settings.useIflytek && settings.hasIflytekCredentials
          ? await _speakIflytekChunk(token)
          : await _speakSystemChunk(token);
    } catch (e) {
      _lastErrorMessage = e.toString();
      onErrorMessage?.call(_lastErrorMessage);
      return false;
    } finally {
      _isStopping = false;
      _isStarting = false;
    }
  }

  Future<bool> stop() async {
    try {
      _isStopping = true;
      _speakToken++;
      _chunks = const [];
      _clearIflytekPrefetch();
      _chunkIndex = 0;
      await _stopNative();
      _isSpeaking = false;
      _isPaused = false;
      _currentPos = 0;
      return true;
    } catch (e) {
      return false;
    } finally {
      _isStopping = false;
    }
  }

  Future<bool> pause() async {
    try {
      if (settings.useIflytek) {
        await _audioPlayer.pause();
        _isPaused = true;
        return true;
      }
      final result = await _flutterTts.pause().timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
      _isPaused = result == 1;
      return _isPaused;
    } catch (e) {
      return false;
    }
  }

  Future<bool> resume() async {
    try {
      if (settings.useIflytek) {
        await _audioPlayer.resume();
        _isPaused = false;
        _isSpeaking = true;
        return true;
      }
      if (_currentText.isEmpty) return false;

      _isStopping = true;
      _speakToken++;
      _chunks = const [];
      _clearIflytekPrefetch();
      _chunkIndex = 0;
      await _stopNative();
      _isStopping = false;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final resumeOffset = _currentPos.clamp(0, _currentText.length).toInt();
      final resumeText = _currentText.substring(resumeOffset);
      _chunks = _splitIntoChunks(
        resumeText,
        baseOffset: resumeOffset,
        splitAtSentence: true,
      );
      _chunkIndex = 0;
      final token = _speakToken;
      _isPaused = false;
      return await _speakSystemChunk(token);
    } catch (e) {
      return false;
    } finally {
      _isStopping = false;
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

  Future<void> _stopNative() async {
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

    final result = await _flutterTts
        .speak(chunk.text)
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (token != _speakToken) return false;

    _isSpeaking = result == 1;
    if (_isSpeaking) {
      _isPaused = false;
      _currentPos = chunk.offset;
      _emitChunkProgress(chunk);
    }
    return _isSpeaking;
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
      await _audioPlayer.play(DeviceFileSource(audioFile.path));
      if (token != _speakToken) return false;
      _isSpeaking = true;
      _isPaused = false;
      _prefetchNextIflytekChunk(token);
      onStart?.call();
      return true;
    } catch (e) {
      if (token == _speakToken) {
        _isSpeaking = false;
        _isPaused = false;
        _lastErrorMessage = e.toString();
        onErrorMessage?.call(_lastErrorMessage);
        onError?.call();
      }
      return false;
    }
  }

  Future<Uint8List> _loadIflytekAudioForChunk(int index) async {
    if (_prefetchedIflytekIndex == index && _prefetchedIflytekAudio != null) {
      final audio = await _prefetchedIflytekAudio!;
      _clearIflytekPrefetch();
      return audio;
    }
    return _synthesizeIflytekChunk(_chunks[index]);
  }

  Future<Uint8List> _synthesizeIflytekChunk(_TtsChunk chunk) {
    return _iflytekTts.synthesize(
      text: chunk.text,
      settings: settings,
      rate: _rate,
      volume: _volume,
      pitch: _pitch,
    );
  }

  void _prefetchNextIflytekChunk(int token) {
    final nextIndex = _chunkIndex + 1;
    if (token != _speakToken || nextIndex >= _chunks.length) return;
    _prefetchedIflytekIndex = nextIndex;
    _prefetchedIflytekAudio = _synthesizeIflytekChunk(_chunks[nextIndex]);
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

  void dispose() {
    _playerStateSubscription?.cancel();
    _playerPositionSubscription?.cancel();
    _playerDurationSubscription?.cancel();
    _audioPlayer.dispose();
    _flutterTts.stop();
  }
}

class _TtsChunk {
  const _TtsChunk(this.text, this.offset);

  final String text;
  final int offset;
}
