import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/player_clock.dart';
import 'package:novel_app/player/player_engine.dart';
import 'package:novel_app/player/player_models.dart';

void main() {
  test(
    'coalesces timeline updates into a lightweight playback clock',
    () async {
      final target = _FakeTarget();
      final clock = PlayerClock(
        target,
        minimumInterval: const Duration(milliseconds: 20),
      );
      var notifications = 0;
      clock.addListener(() => notifications++);

      for (var index = 0; index < 10; index++) {
        target.mutableTimeline.value = PlayerTimeline(
          position: Duration(milliseconds: index * 10),
          playing: true,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(clock.value.position, const Duration(milliseconds: 90));
      expect(notifications, lessThan(10));
      clock.dispose();
    },
  );
}

class _FakeTarget implements PlaybackCommandTarget {
  final ValueNotifier<PlayerTimeline> mutableTimeline = ValueNotifier(
    const PlayerTimeline(),
  );

  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities();
  @override
  ValueNotifier<PlayerTimeline> get timeline => mutableTimeline;
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
}
