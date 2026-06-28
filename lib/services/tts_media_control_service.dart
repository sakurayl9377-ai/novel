import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/novel.dart';

typedef TtsMediaAction = Future<void> Function();

class TtsMediaControlService {
  TtsMediaControlService._(this._handler);

  TtsMediaControlService.disabled() : _handler = null;

  final _TtsMediaHandler? _handler;
  Object? _owner;

  static Future<TtsMediaControlService> init() async {
    final handler = await AudioService.init<_TtsMediaHandler>(
      builder: _TtsMediaHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.novel.novel_app.channel.tts',
        androidNotificationChannelName: '听书播放',
        androidNotificationChannelDescription: '小说听书锁屏控制',
        androidNotificationClickStartsActivity: true,
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
      ),
    );
    return TtsMediaControlService._(handler);
  }

  void bindControls({
    required Object owner,
    required TtsMediaAction onPlay,
    required TtsMediaAction onPause,
    required TtsMediaAction onStop,
  }) {
    _owner = owner;
    _handler?.bindControls(onPlay: onPlay, onPause: onPause, onStop: onStop);
  }

  void unbindControls(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _handler?.clearControls();
  }

  Future<bool> ensureNotificationPermission() async {
    if (!Platform.isAndroid) {
      return true;
    }

    final status = await Permission.notification.status;
    if (status.isGranted) {
      return true;
    }

    final requested = await Permission.notification.request();
    return requested.isGranted;
  }

  Future<void> show({
    required Novel novel,
    required String chapterTitle,
    required bool playing,
  }) async {
    final title = novel.title.trim().isEmpty ? '语音朗读' : novel.title.trim();
    final subtitle = chapterTitle.trim().isEmpty ? '语音朗读' : chapterTitle.trim();
    final author = novel.author.trim().isEmpty ? 'Sakura' : novel.author.trim();

    _handler?.setMediaItem(
      MediaItem(
        id: 'novel:${novel.id}',
        title: title,
        artist: subtitle,
        album: author,
        extras: {'novelId': novel.id, 'chapterTitle': subtitle},
      ),
    );
    await setPlaying(playing);
  }

  Future<void> setPlaying(bool playing) async {
    _handler?.emitPlaybackState(
      playing: playing,
      processingState: AudioProcessingState.ready,
    );
  }

  Future<void> stop() async {
    _handler?.clearMediaSession();
  }
}

class _TtsMediaHandler extends BaseAudioHandler {
  TtsMediaAction? _onPlay;
  TtsMediaAction? _onPause;
  TtsMediaAction? _onStop;

  void bindControls({
    required TtsMediaAction onPlay,
    required TtsMediaAction onPause,
    required TtsMediaAction onStop,
  }) {
    _onPlay = onPlay;
    _onPause = onPause;
    _onStop = onStop;
  }

  void clearControls() {
    _onPlay = null;
    _onPause = null;
    _onStop = null;
  }

  void setMediaItem(MediaItem item) {
    mediaItem.add(item);
  }

  void emitPlaybackState({
    required bool playing,
    required AudioProcessingState processingState,
  }) {
    final controls = [
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
    ];

    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processingState,
        playing: playing,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
      ),
    );
  }

  void clearMediaSession() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [],
        androidCompactActionIndices: const [],
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
      ),
    );
    mediaItem.add(null);
  }

  @override
  Future<void> play() async {
    await _onPlay?.call();
  }

  @override
  Future<void> pause() async {
    await _onPause?.call();
  }

  @override
  Future<void> stop() async {
    await _onStop?.call();
  }

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> skipToNext() async {}
}
