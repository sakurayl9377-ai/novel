import 'dart:async';

import 'package:flutter/foundation.dart';

import 'player_engine.dart';

@immutable
class PlayerClockSample {
  const PlayerClockSample({
    required this.position,
    required this.playing,
    required this.buffering,
  });

  final Duration position;
  final bool playing;
  final bool buffering;
}

class PlayerClock extends ValueNotifier<PlayerClockSample> {
  PlayerClock(
    this._target, {
    this.minimumInterval = const Duration(milliseconds: 60),
  }) : super(
         PlayerClockSample(
           position: _target.timeline.value.position,
           playing: _target.timeline.value.playing,
           buffering: _target.timeline.value.buffering,
         ),
       ) {
    _target.timeline.addListener(_handleTimelineChanged);
  }

  final PlaybackCommandTarget _target;
  final Duration minimumInterval;
  Timer? _timer;
  int _lastPublishedAtMs = 0;
  bool _disposed = false;

  void _handleTimelineChanged() {
    if (_disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final remaining =
        minimumInterval.inMilliseconds - (now - _lastPublishedAtMs);
    if (remaining <= 0) {
      _publish();
      return;
    }
    _timer ??= Timer(Duration(milliseconds: remaining), () {
      _timer = null;
      _publish();
    });
  }

  void _publish() {
    if (_disposed) return;
    final timeline = _target.timeline.value;
    _lastPublishedAtMs = DateTime.now().millisecondsSinceEpoch;
    value = PlayerClockSample(
      position: timeline.position,
      playing: timeline.playing,
      buffering: timeline.buffering,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _target.timeline.removeListener(_handleTimelineChanged);
    super.dispose();
  }
}
