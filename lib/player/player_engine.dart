import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'player_models.dart';

abstract interface class PlayerSurface {
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    Color backgroundColor = const Color(0xFF000000),
    bool showSubtitles = true,
  });
}

abstract interface class PlaybackCommandTarget {
  ValueListenable<PlayerTimeline> get timeline;
  PlaybackCapabilities get capabilities;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
}

abstract interface class PlayerEngine implements PlaybackCommandTarget {
  ValueListenable<PlayerStatus> get status;
  ValueListenable<PlayerTrackState> get tracks;
  Stream<PlayerEvent> get events;
  PlayerSurface get surface;

  Future<void> open(PlayerOpenRequest request);
  Future<void> stop();
  Future<void> selectTrack(PlayerTrackSelection selection);
  Future<void> dispose();
}
