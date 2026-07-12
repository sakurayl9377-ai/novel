import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/player_engine.dart';
import 'package:novel_app/player/player_models.dart';
import 'package:novel_app/player/player_session_controller.dart';

void main() {
  test(
    'quality switch reuses engine and preserves position and intent',
    () async {
      final engine = _FakePlayerEngine();
      final session = PlayerSessionController(engine: engine);
      final initial = _request('https://example.com/master.m3u8');
      await session.open(initial, sourceId: 'line-a');
      engine.timeline.value = const PlayerTimeline(
        position: Duration(seconds: 83),
        duration: Duration(minutes: 24),
        playing: true,
      );

      await session.switchQuality(
        _request('https://example.com/720.m3u8'),
        qualityId: '720p',
      );

      expect(engine.openRequests, hasLength(2));
      expect(engine.openRequests.last.startAt, const Duration(seconds: 83));
      expect(engine.openRequests.last.autoplay, isTrue);
      expect(engine.disposeCalls, 0);
      expect(session.currentSourceId, 'line-a');
      expect(session.currentQualityId, '720p');
      await session.close();
    },
  );

  test('quality failure does not poison the whole source', () async {
    final engine = _FakePlayerEngine();
    final session = PlayerSessionController(engine: engine);
    await session.open(
      _request('https://example.com/master.m3u8'),
      sourceId: 'a',
    );
    engine.failNextOpen = true;

    await expectLater(
      session.switchQuality(
        _request('https://example.com/1080.m3u8'),
        qualityId: '1080p',
      ),
      throwsStateError,
    );

    expect(session.failedSourceIds, isEmpty);
    expect(session.failedQualityIds['a'], contains('1080p'));
    await session.close();
  });

  test('preferred audio language is reapplied on the next media', () async {
    final engine = _FakePlayerEngine();
    engine.tracks.value = const PlayerTrackState(
      audio: [
        PlayerTrackInfo(
          id: 'zh-1',
          kind: PlayerTrackKind.audio,
          origin: PlayerTrackOrigin.embedded,
          language: 'zh',
        ),
      ],
    );
    final session = PlayerSessionController(engine: engine);
    await session.open(_request('https://example.com/1.m3u8'), sourceId: 'a');
    await session.selectTrack(
      const PlayerTrackSelection.embedded(PlayerTrackKind.audio, 'zh-1'),
    );
    engine.selections.clear();

    await session.switchEpisode(
      _request('https://example.com/2.m3u8'),
      sourceId: 'a',
    );

    expect(engine.selections.single.id, 'zh-1');
    await session.close();
  });
}

PlayerOpenRequest _request(String url) => PlayerOpenRequest(
  source: PlayerMediaSource.network(url, canonicalId: 'episode-1'),
);

class _FakePlayerEngine implements PlayerEngine {
  final ValueNotifier<PlayerStatus> mutableStatus = ValueNotifier(
    const PlayerStatus(),
  );
  final ValueNotifier<PlayerTimeline> mutableTimeline = ValueNotifier(
    const PlayerTimeline(),
  );
  final ValueNotifier<PlayerTrackState> mutableTracks = ValueNotifier(
    const PlayerTrackState(),
  );
  final StreamController<PlayerEvent> eventController =
      StreamController<PlayerEvent>.broadcast();
  final List<PlayerOpenRequest> openRequests = [];
  final List<PlayerTrackSelection> selections = [];
  bool failNextOpen = false;
  int disposeCalls = 0;

  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities();
  @override
  Stream<PlayerEvent> get events => eventController.stream;
  @override
  PlayerSurface get surface => const _FakeSurface();
  @override
  ValueListenable<PlayerStatus> get status => mutableStatus;
  @override
  ValueNotifier<PlayerTimeline> get timeline => mutableTimeline;
  @override
  ValueNotifier<PlayerTrackState> get tracks => mutableTracks;

  @override
  Future<void> open(PlayerOpenRequest request) async {
    openRequests.add(request);
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('failed');
    }
    mutableTimeline.value = PlayerTimeline(
      position: request.startAt,
      playing: request.autoplay,
    );
    mutableStatus.value = const PlayerStatus(phase: PlayerPhase.ready);
  }

  @override
  Future<void> pause() async {
    mutableTimeline.value = mutableTimeline.value.copyWith(playing: false);
  }

  @override
  Future<void> play() async {
    mutableTimeline.value = mutableTimeline.value.copyWith(playing: true);
  }

  @override
  Future<void> seek(Duration position) async {
    mutableTimeline.value = mutableTimeline.value.copyWith(position: position);
  }

  @override
  Future<void> selectTrack(PlayerTrackSelection selection) async {
    selections.add(selection);
  }

  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await eventController.close();
  }
}

class _FakeSurface implements PlayerSurface {
  const _FakeSurface();

  @override
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    Color backgroundColor = const Color(0xFF000000),
    bool showSubtitles = true,
  }) => SizedBox(key: key);
}
