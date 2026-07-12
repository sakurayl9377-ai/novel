import 'dart:async';

import 'package:flutter/foundation.dart';

import 'player_engine.dart';
import 'player_models.dart';

enum PlayerSwitchScope { episode, source, quality, recovery }

class PlayerSessionController extends ChangeNotifier
    implements PlaybackCommandTarget {
  PlayerSessionController({required this.engine}) {
    engine.status.addListener(_relay);
    engine.timeline.addListener(_relay);
    engine.tracks.addListener(_relay);
  }

  final PlayerEngine engine;
  final Set<String> failedSourceIds = <String>{};
  final Map<String, Set<String>> failedQualityIds = <String, Set<String>>{};
  PlayerOpenRequest? _currentRequest;
  String _currentSourceId = '';
  String _currentQualityId = 'auto';
  bool _playbackIntent = true;
  String _preferredAudioLanguage = '';
  String _preferredSubtitleLanguage = '';
  bool _closed = false;

  PlayerOpenRequest? get currentRequest => _currentRequest;
  String get currentSourceId => _currentSourceId;
  String get currentQualityId => _currentQualityId;
  bool get playbackIntent => _playbackIntent;

  @override
  PlaybackCapabilities get capabilities => engine.capabilities;

  @override
  ValueListenable<PlayerTimeline> get timeline => engine.timeline;

  ValueListenable<PlayerStatus> get status => engine.status;
  ValueListenable<PlayerTrackState> get tracks => engine.tracks;
  PlayerSurface get surface => engine.surface;

  Future<void> open(
    PlayerOpenRequest request, {
    required String sourceId,
    String qualityId = 'auto',
    PlayerSwitchScope scope = PlayerSwitchScope.episode,
    bool preservePosition = false,
  }) async {
    _ensureOpen();
    final oldTimeline = engine.timeline.value;
    final startAt = preservePosition ? oldTimeline.position : request.startAt;
    final shouldPlay = preservePosition
        ? _playbackIntent || oldTimeline.playing
        : request.autoplay;
    final next = request.copyWith(startAt: startAt, autoplay: shouldPlay);
    try {
      await engine.open(next);
      _currentRequest = next;
      _currentSourceId = sourceId;
      _currentQualityId = qualityId;
      _playbackIntent = shouldPlay;
      await _applyTrackPreferences();
    } catch (_) {
      if (scope == PlayerSwitchScope.quality) {
        failedQualityIds.putIfAbsent(sourceId, () => <String>{}).add(qualityId);
      } else if (scope == PlayerSwitchScope.source) {
        failedSourceIds.add(sourceId);
      }
      rethrow;
    }
  }

  Future<void> switchEpisode(
    PlayerOpenRequest request, {
    required String sourceId,
  }) => open(
    request,
    sourceId: sourceId,
    scope: PlayerSwitchScope.episode,
    preservePosition: false,
  );

  Future<void> switchSource(
    PlayerOpenRequest request, {
    required String sourceId,
  }) => open(
    request,
    sourceId: sourceId,
    scope: PlayerSwitchScope.source,
    preservePosition: true,
  );

  Future<void> switchQuality(
    PlayerOpenRequest request, {
    required String qualityId,
  }) => open(
    request,
    sourceId: _currentSourceId,
    qualityId: qualityId,
    scope: PlayerSwitchScope.quality,
    preservePosition: true,
  );

  Future<void> selectTrack(PlayerTrackSelection selection) async {
    await engine.selectTrack(selection);
    if (selection.isExternal) {
      if (selection.kind == PlayerTrackKind.audio) {
        _preferredAudioLanguage = selection.language;
      } else if (selection.kind == PlayerTrackKind.subtitle) {
        _preferredSubtitleLanguage = selection.language;
      }
      return;
    }
    final collection = switch (selection.kind) {
      PlayerTrackKind.video => engine.tracks.value.video,
      PlayerTrackKind.audio => engine.tracks.value.audio,
      PlayerTrackKind.subtitle => engine.tracks.value.subtitle,
    };
    final selected = collection.where((item) => item.id == selection.id);
    if (selected.isEmpty) return;
    if (selection.kind == PlayerTrackKind.audio) {
      _preferredAudioLanguage = selected.first.language;
    } else if (selection.kind == PlayerTrackKind.subtitle) {
      _preferredSubtitleLanguage = selected.first.language;
    }
  }

  Future<void> _applyTrackPreferences() async {
    final state = engine.tracks.value;
    if (_preferredAudioLanguage.isNotEmpty) {
      final matches = state.audio.where(
        (item) => item.language == _preferredAudioLanguage,
      );
      if (matches.isNotEmpty) {
        await engine.selectTrack(
          PlayerTrackSelection.embedded(
            PlayerTrackKind.audio,
            matches.first.id,
          ),
        );
      }
    }
    if (_preferredSubtitleLanguage.isNotEmpty) {
      final matches = state.subtitle.where(
        (item) => item.language == _preferredSubtitleLanguage,
      );
      if (matches.isNotEmpty) {
        await engine.selectTrack(
          PlayerTrackSelection.embedded(
            PlayerTrackKind.subtitle,
            matches.first.id,
          ),
        );
      }
    }
  }

  @override
  Future<void> play() async {
    _playbackIntent = true;
    await engine.play();
  }

  @override
  Future<void> pause() async {
    _playbackIntent = false;
    await engine.pause();
  }

  @override
  Future<void> seek(Duration position) => engine.seek(position);

  @override
  Future<void> setRate(double rate) => engine.setRate(rate);

  @override
  Future<void> setVolume(double volume) => engine.setVolume(volume);

  void _relay() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    engine.status.removeListener(_relay);
    engine.timeline.removeListener(_relay);
    engine.tracks.removeListener(_relay);
    await engine.dispose();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Player session is closed');
  }

  @override
  void dispose() {
    if (!_closed) {
      _closed = true;
      engine.status.removeListener(_relay);
      engine.timeline.removeListener(_relay);
      engine.tracks.removeListener(_relay);
      unawaited(engine.dispose());
    }
    super.dispose();
  }
}
