import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../player_engine.dart';
import '../player_models.dart';

class LegacyPlayerEngine implements PlayerEngine {
  LegacyPlayerEngine() : _surface = _LegacyPlayerSurface();

  final ValueNotifier<PlayerStatus> _status = ValueNotifier(
    const PlayerStatus(),
  );
  final ValueNotifier<PlayerTimeline> _timeline = ValueNotifier(
    const PlayerTimeline(),
  );
  final ValueNotifier<PlayerTrackState> _tracks = ValueNotifier(
    const PlayerTrackState(
      video: [
        PlayerTrackInfo(
          id: 'auto',
          kind: PlayerTrackKind.video,
          origin: PlayerTrackOrigin.automatic,
        ),
      ],
      audio: [
        PlayerTrackInfo(
          id: 'auto',
          kind: PlayerTrackKind.audio,
          origin: PlayerTrackOrigin.automatic,
        ),
      ],
      subtitle: [
        PlayerTrackInfo(
          id: 'no',
          kind: PlayerTrackKind.subtitle,
          origin: PlayerTrackOrigin.disabled,
        ),
      ],
      selectedSubtitleId: 'no',
    ),
  );
  final StreamController<PlayerEvent> _events =
      StreamController<PlayerEvent>.broadcast();
  final _LegacyPlayerSurface _surface;
  VideoPlayerController? _controller;
  bool _disposed = false;
  bool _firstFrameSent = false;
  int _generation = 0;
  double _rate = 1;
  double _volume = 1;

  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities(
    trackSelection: false,
    externalAudio: false,
    externalSubtitle: false,
    videoTrackSelection: false,
  );

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

  @override
  Future<void> open(PlayerOpenRequest request) async {
    _ensureUsable();
    final generation = ++_generation;
    await _disposeController();
    _status.value = const PlayerStatus(phase: PlayerPhase.opening);
    _firstFrameSent = false;
    final options = VideoPlayerOptions(mixWithOthers: false);
    final source = request.source;
    final controller = switch (source.uri.scheme) {
      'file' => VideoPlayerController.file(
        File(source.uri.toFilePath()),
        videoPlayerOptions: options,
      ),
      'content' => VideoPlayerController.contentUri(
        source.uri,
        videoPlayerOptions: options,
      ),
      _ => VideoPlayerController.networkUrl(
        source.uri,
        httpHeaders: source.httpHeaders,
        formatHint: _formatHint(source.uri),
        videoPlayerOptions: options,
      ),
    };
    try {
      await controller.initialize();
      if (!_isCurrent(generation)) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _surface.controller = controller;
      controller.addListener(_handleControllerChanged);
      await controller.setVolume(_volume);
      await controller.setPlaybackSpeed(_rate);
      if (request.startAt > Duration.zero) {
        await controller.seekTo(request.startAt);
      }
      if (request.autoplay) await controller.play();
      _handleControllerChanged();
      _status.value = PlayerStatus(
        phase: controller.value.isBuffering
            ? PlayerPhase.buffering
            : PlayerPhase.ready,
        width: controller.value.size.width.round(),
        height: controller.value.size.height.round(),
        firstFrameRendered: true,
      );
      _firstFrameSent = true;
      _events
        ..add(const PlayerEvent(PlayerEventType.opened))
        ..add(const PlayerEvent(PlayerEventType.firstFrame));
    } catch (error) {
      await controller.dispose();
      if (!_isCurrent(generation)) return;
      _status.value = PlayerStatus(
        phase: PlayerPhase.failed,
        errorMessage: error.toString(),
      );
      _events.add(
        PlayerEvent(PlayerEventType.error, message: error.toString()),
      );
      rethrow;
    }
  }

  void _handleControllerChanged() {
    if (_disposed) return;
    final value = _controller?.value;
    if (value == null) return;
    _timeline.value = PlayerTimeline(
      position: value.position,
      duration: value.duration,
      buffered: value.buffered.isEmpty
          ? Duration.zero
          : value.buffered.last.end,
      playing: value.isPlaying,
      buffering: value.isBuffering,
      completed: value.isCompleted,
      rate: value.playbackSpeed,
      volume: value.volume,
    );
    if (value.hasError) {
      final message = value.errorDescription ?? 'Playback failed';
      _status.value = _status.value.copyWith(
        phase: PlayerPhase.failed,
        errorMessage: message,
      );
      _events.add(PlayerEvent(PlayerEventType.error, message: message));
    } else if (value.isBuffering) {
      _status.value = _status.value.copyWith(phase: PlayerPhase.buffering);
    } else if (value.isInitialized) {
      _status.value = _status.value.copyWith(phase: PlayerPhase.ready);
    }
    if (value.isCompleted) {
      _events.add(const PlayerEvent(PlayerEventType.completed));
    }
    if (!_firstFrameSent && value.isInitialized) {
      _firstFrameSent = true;
      _events.add(const PlayerEvent(PlayerEventType.firstFrame));
    }
  }

  @override
  Future<void> play() async {
    _ensureUsable();
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    _ensureUsable();
    await _controller?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureUsable();
    await _controller?.seekTo(
      position < Duration.zero ? Duration.zero : position,
    );
  }

  @override
  Future<void> setRate(double rate) async {
    _ensureUsable();
    _rate = rate.clamp(0.25, 4).toDouble();
    await _controller?.setPlaybackSpeed(_rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    _ensureUsable();
    _volume = volume.clamp(0, 1).toDouble();
    await _controller?.setVolume(_volume);
  }

  @override
  Future<void> selectTrack(PlayerTrackSelection selection) {
    throw UnsupportedError(
      'Legacy video_player does not expose track selection',
    );
  }

  @override
  Future<void> stop() async {
    _ensureUsable();
    _generation++;
    await _disposeController();
    _status.value = const PlayerStatus();
    _timeline.value = PlayerTimeline(rate: _rate, volume: _volume);
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    _surface.controller = null;
    controller?.removeListener(_handleControllerChanged);
    await controller?.dispose();
  }

  VideoFormat? _formatHint(Uri uri) => switch (uri.path.toLowerCase()) {
    final path when path.endsWith('.m3u8') => VideoFormat.hls,
    final path when path.endsWith('.mpd') => VideoFormat.dash,
    _ => null,
  };

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _ensureUsable() {
    if (_disposed) throw StateError('Player engine is disposed');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _disposeController();
    _status.value = const PlayerStatus(phase: PlayerPhase.disposed);
    await _events.close();
    _status.dispose();
    _timeline.dispose();
    _tracks.dispose();
  }
}

class _LegacyPlayerSurface implements PlayerSurface {
  VideoPlayerController? controller;

  @override
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    Color backgroundColor = const Color(0xFF000000),
    bool showSubtitles = true,
  }) => ColoredBox(
    key: key,
    color: backgroundColor,
    child: ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller ?? _emptyValue,
      builder: (context, value, _) {
        final active = controller;
        if (active == null || !value.isInitialized) {
          return const SizedBox.expand();
        }
        final size = value.size;
        return Center(
          child: FittedBox(
            fit: fit,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: VideoPlayer(active),
            ),
          ),
        );
      },
    ),
  );

  static final ValueNotifier<VideoPlayerValue> _emptyValue = ValueNotifier(
    const VideoPlayerValue(duration: Duration.zero),
  );
}
