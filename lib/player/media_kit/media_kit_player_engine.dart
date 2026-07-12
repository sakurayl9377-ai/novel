import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as media_kit;
import 'package:media_kit_video/media_kit_video.dart' as media_kit_video;

import '../player_engine.dart';
import '../player_models.dart';
import 'media_kit_player_mapper.dart';

class MediaKitPlayerEngine implements PlayerEngine {
  MediaKitPlayerEngine({
    media_kit.Player? player,
    int bufferSize = 32 * 1024 * 1024,
  }) : _player = player ?? _createPlayer(bufferSize) {
    _videoController = media_kit_video.VideoController(
      _player,
      configuration: const media_kit_video.VideoControllerConfiguration(
        hwdec: 'auto-safe',
        enableHardwareAcceleration: true,
      ),
    );
    _surface = _MediaKitPlayerSurface(_videoController);
    _listen();
  }

  final media_kit.Player _player;
  late final media_kit_video.VideoController _videoController;
  late final PlayerSurface _surface;
  final ValueNotifier<PlayerStatus> _status = ValueNotifier(
    const PlayerStatus(),
  );
  final ValueNotifier<PlayerTimeline> _timeline = ValueNotifier(
    const PlayerTimeline(),
  );
  final ValueNotifier<PlayerTrackState> _tracks = ValueNotifier(
    const PlayerTrackState(),
  );
  final StreamController<PlayerEvent> _events =
      StreamController<PlayerEvent>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;
  int _openGeneration = 0;
  bool _firstFrameEventSent = false;

  static media_kit.Player _createPlayer(int bufferSize) {
    // Loading libmpv is intentionally deferred until this engine is actually
    // selected. A native player issue must never prevent the app from opening.
    media_kit.MediaKit.ensureInitialized();
    return media_kit.Player(
      configuration: media_kit.PlayerConfiguration(
        title: 'Sakura',
        bufferSize: bufferSize,
        logLevel: media_kit.MPVLogLevel.error,
      ),
    );
  }

  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities();

  @override
  ValueListenable<PlayerStatus> get status => _status;

  @override
  ValueListenable<PlayerTimeline> get timeline => _timeline;

  @override
  ValueListenable<PlayerTrackState> get tracks => _tracks;

  @override
  Stream<PlayerEvent> get events => _events.stream;

  @override
  PlayerSurface get surface => _surface;

  void _listen() {
    _subscriptions.addAll([
      _player.stream.position.listen(
        (value) => _updateTimeline(position: value),
      ),
      _player.stream.duration.listen(
        (value) => _updateTimeline(duration: value),
      ),
      _player.stream.buffer.listen((value) => _updateTimeline(buffered: value)),
      _player.stream.playing.listen((value) {
        _updateTimeline(playing: value);
        if (value) _markFirstFrame();
      }),
      _player.stream.buffering.listen((value) {
        _updateTimeline(buffering: value);
        if (_status.value.phase != PlayerPhase.opening &&
            _status.value.phase != PlayerPhase.failed) {
          _status.value = _status.value.copyWith(
            phase: value ? PlayerPhase.buffering : PlayerPhase.ready,
          );
        }
      }),
      _player.stream.completed.listen((value) {
        _updateTimeline(completed: value);
        if (value && !_events.isClosed) {
          _events.add(const PlayerEvent(PlayerEventType.completed));
        }
      }),
      _player.stream.rate.listen((value) => _updateTimeline(rate: value)),
      _player.stream.volume.listen(
        (value) => _updateTimeline(volume: (value / 100).clamp(0, 1)),
      ),
      _player.stream.width.listen((value) {
        if (value != null && value > 0) {
          _status.value = _status.value.copyWith(width: value);
          _markFirstFrame();
        }
      }),
      _player.stream.height.listen((value) {
        if (value != null && value > 0) {
          _status.value = _status.value.copyWith(height: value);
          _markFirstFrame();
        }
      }),
      _player.stream.tracks.listen((_) => _updateTracks()),
      _player.stream.track.listen((_) => _updateTracks()),
      _player.stream.error.listen(_handleError),
    ]);
  }

  void _updateTimeline({
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? playing,
    bool? buffering,
    bool? completed,
    double? rate,
    double? volume,
  }) {
    if (_disposed) return;
    _timeline.value = _timeline.value.copyWith(
      position: position,
      duration: duration,
      buffered: buffered,
      playing: playing,
      buffering: buffering,
      completed: completed,
      rate: rate,
      volume: volume,
    );
  }

  void _updateTracks() {
    if (_disposed) return;
    _tracks.value = MediaKitPlayerMapper.tracks(
      _player.state.tracks,
      _player.state.track,
    );
  }

  void _markFirstFrame() {
    if (_disposed || _firstFrameEventSent) return;
    final width = _status.value.width;
    final height = _status.value.height;
    if (!_timeline.value.playing && (width == null || height == null)) return;
    _firstFrameEventSent = true;
    _status.value = _status.value.copyWith(firstFrameRendered: true);
    if (!_events.isClosed) {
      _events.add(const PlayerEvent(PlayerEventType.firstFrame));
    }
  }

  void _handleError(String message) {
    if (_disposed || message.trim().isEmpty) return;
    _status.value = _status.value.copyWith(
      phase: PlayerPhase.failed,
      errorMessage: message.trim(),
    );
    if (!_events.isClosed) {
      _events.add(PlayerEvent(PlayerEventType.error, message: message.trim()));
    }
  }

  @override
  Future<void> open(PlayerOpenRequest request) async {
    _ensureUsable();
    final generation = ++_openGeneration;
    _firstFrameEventSent = false;
    _status.value = const PlayerStatus(phase: PlayerPhase.opening);
    _timeline.value = PlayerTimeline(
      rate: _timeline.value.rate,
      volume: _timeline.value.volume,
    );
    try {
      await _player.open(
        media_kit.Media(
          request.source.uri.toString(),
          httpHeaders: request.source.httpHeaders.isEmpty
              ? null
              : request.source.httpHeaders,
        ),
        play: false,
      );
      if (!_isCurrent(generation)) return;
      await _player.setVolume(_timeline.value.volume * 100);
      await _player.setRate(_timeline.value.rate);
      if (request.startAt > Duration.zero) {
        await _player.seek(request.startAt);
      }
      if (request.autoplay) await _player.play();
      if (!_isCurrent(generation)) return;
      _status.value = _status.value.copyWith(
        phase: _timeline.value.buffering
            ? PlayerPhase.buffering
            : PlayerPhase.ready,
        clearError: true,
      );
      _updateTracks();
      if (!_events.isClosed) {
        _events.add(const PlayerEvent(PlayerEventType.opened));
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      final message = error.toString();
      _status.value = _status.value.copyWith(
        phase: PlayerPhase.failed,
        errorMessage: message,
      );
      if (!_events.isClosed) {
        _events.add(PlayerEvent(PlayerEventType.error, message: message));
      }
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    _ensureUsable();
    _openGeneration++;
    await _player.stop();
    _timeline.value = PlayerTimeline(
      rate: _timeline.value.rate,
      volume: _timeline.value.volume,
    );
    _status.value = const PlayerStatus();
  }

  @override
  Future<void> play() async {
    _ensureUsable();
    await _player.play();
  }

  @override
  Future<void> pause() async {
    _ensureUsable();
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureUsable();
    await _player.seek(position < Duration.zero ? Duration.zero : position);
  }

  @override
  Future<void> setRate(double rate) async {
    _ensureUsable();
    final value = rate.clamp(0.25, 4).toDouble();
    await _player.setRate(value);
  }

  @override
  Future<void> setVolume(double volume) async {
    _ensureUsable();
    await _player.setVolume(volume.clamp(0, 1).toDouble() * 100);
  }

  @override
  Future<void> selectTrack(PlayerTrackSelection selection) async {
    _ensureUsable();
    switch (selection.kind) {
      case PlayerTrackKind.video:
        if (selection.isExternal) {
          throw UnsupportedError('External video tracks are not supported');
        }
        final id = selection.id;
        final track = id == 'auto'
            ? media_kit.VideoTrack.auto()
            : id == 'no'
            ? media_kit.VideoTrack.no()
            : _player.state.tracks.video.firstWhere((item) => item.id == id);
        await _player.setVideoTrack(track);
      case PlayerTrackKind.audio:
        final track = selection.isExternal
            ? media_kit.AudioTrack.uri(
                selection.uri.toString(),
                title: selection.title,
                language: selection.language,
              )
            : selection.id == 'auto'
            ? media_kit.AudioTrack.auto()
            : selection.id == 'no'
            ? media_kit.AudioTrack.no()
            : _player.state.tracks.audio.firstWhere(
                (item) => item.id == selection.id,
              );
        await _player.setAudioTrack(track);
      case PlayerTrackKind.subtitle:
        final track = selection.isExternal
            ? media_kit.SubtitleTrack.uri(
                selection.uri.toString(),
                title: selection.title,
                language: selection.language,
              )
            : selection.id == 'auto'
            ? media_kit.SubtitleTrack.auto()
            : selection.id == 'no'
            ? media_kit.SubtitleTrack.no()
            : _player.state.tracks.subtitle.firstWhere(
                (item) => item.id == selection.id,
              );
        await _player.setSubtitleTrack(track);
    }
    _updateTracks();
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _openGeneration;

  void _ensureUsable() {
    if (_disposed) throw StateError('Player engine is disposed');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _openGeneration++;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    _status.value = const PlayerStatus(phase: PlayerPhase.disposed);
    await _events.close();
    _status.dispose();
    _timeline.dispose();
    _tracks.dispose();
  }
}

class _MediaKitPlayerSurface implements PlayerSurface {
  const _MediaKitPlayerSurface(this.controller);

  final media_kit_video.VideoController controller;

  @override
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    Color backgroundColor = const Color(0xFF000000),
    bool showSubtitles = true,
  }) => media_kit_video.Video(
    key: key,
    controller: controller,
    fit: fit,
    fill: backgroundColor,
    controls: null,
    wakelock: true,
    pauseUponEnteringBackgroundMode: false,
    resumeUponEnteringForegroundMode: false,
    subtitleViewConfiguration: media_kit_video.SubtitleViewConfiguration(
      visible: showSubtitles,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 54),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 30,
        height: 1.3,
        shadows: [
          Shadow(color: Colors.black, blurRadius: 4),
          Shadow(color: Colors.black, blurRadius: 8),
        ],
      ),
    ),
  );
}
