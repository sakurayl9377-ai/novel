import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String screen;

  setUpAll(() {
    screen = File('lib/screens/anime_player_screen.dart').readAsStringSync();
  });

  test('Chewie fullscreen is disabled and never toggled', () {
    expect(screen, contains('allowFullScreen: false'));
    expect(screen, isNot(contains('.toggleFullScreen()')));
    expect(screen, isNot(contains('.enterFullScreen()')));
    expect(screen, isNot(contains('.exitFullScreen()')));
    expect(screen, isNot(contains('routePageBuilder:')));
  });

  test('a persistent managed route owns fullscreen', () {
    final enter = _methodSource(screen, 'Future<void> _enterManagedFullScreen');
    expect(enter, contains('Navigator.of(context, rootNavigator: true).push'));
    expect(enter, contains('_ManagedAnimeFullScreen('));
    expect(enter, contains('_managedFullScreenEpoch'));
    expect(enter, contains('await _restoreSystemUi();'));
  });

  test('fullscreen temporarily forces landscape and releases it on exit', () {
    final enter = _methodSource(screen, 'Future<void> _enterManagedFullScreen');
    final restore = _methodSource(screen, 'Future<void> _restoreSystemUi');
    final cleanupOwner = enter.indexOf('try {');
    final orientationRequest = enter.indexOf(
      'await SystemChrome.setPreferredOrientations',
    );
    final staleEntryGuard = enter.indexOf('if (!mounted', orientationRequest);
    final cleanup = enter.lastIndexOf('await _restoreSystemUi();');

    expect(enter, contains('DeviceOrientation.landscapeLeft'));
    expect(enter, contains('DeviceOrientation.landscapeRight'));
    expect(enter, isNot(contains('isAutoRotationEnabled')));
    expect(enter, contains('_managedFullScreenForcedOrientation = true;'));
    expect(restore, contains('setPreferredOrientations(const [])'));
    expect(restore, contains('_managedFullScreenForcedOrientation = false;'));
    expect(cleanupOwner, greaterThanOrEqualTo(0));
    expect(orientationRequest, greaterThan(cleanupOwner));
    expect(staleEntryGuard, greaterThan(orientationRequest));
    expect(cleanup, greaterThan(staleEntryGuard));
  });

  test('inline can only enter and fullscreen can only exit', () {
    expect(screen, contains('onFullScreenPressed: forceFullScreenLayout'));
    expect(screen, contains('? (_) => _requestManagedFullScreenExit()'));
    expect(screen, contains(': _enterManagedFullScreen'));

    final enter = _methodSource(screen, 'Future<void> _enterManagedFullScreen');
    final exit = _methodSource(
      screen,
      'Future<void> _requestManagedFullScreenExit',
    );

    expect(enter, contains('Navigator.of(context, rootNavigator: true).push'));
    expect(
      enter,
      contains('onExit: () => unawaited(_requestManagedFullScreenExit())'),
    );
    expect(exit, contains('if (!_managedFullScreenActive'));
    expect(exit, isNot(contains('_enterManagedFullScreen')));
    expect(exit, isNot(contains('.push')));
    expect(exit, contains('Navigator.of(context, rootNavigator: true).pop'));
    expect(screen, isNot(contains('_toggleManagedFullScreen')));
    expect(screen, contains('_managedFullScreenEnterBlockedUntilMs'));
  });

  test(
    'episode switches detach fullscreen before disposing old controller',
    () {
      final load = _methodSource(screen, 'Future<void> _loadEpisode');
      final loading = load.indexOf('_publishManagedFullScreenLoading();');
      final frame = load.indexOf('await WidgetsBinding.instance.endOfFrame;');
      final dispose = load.indexOf('await _disposePlayer();');
      expect(loading, greaterThanOrEqualTo(0));
      expect(frame, greaterThan(loading));
      expect(dispose, greaterThan(frame));
      expect(load, isNot(contains('Navigator.')));
      expect(load, isNot(contains('setPreferredOrientations')));
    },
  );

  test('new controller only replaces the managed session', () {
    final load = _methodSource(screen, 'Future<void> _loadEpisode');
    expect(load, contains('_publishManagedFullScreenReady('));
    expect(screen, contains('ValueNotifier<_ManagedFullScreenSession>'));
    expect(screen, contains('key: ValueKey<int>(session.generation)'));
  });

  test('playback progress dismisses a sticky Android buffering overlay', () {
    expect(
      screen,
      contains('(!value.isBuffering || value.position > Duration.zero)'),
    );
  });

  test(
    'fullscreen video uses contain fit while inline player remains 16 by 9',
    () {
      expect(screen, contains('class _ManagedAnimeFullScreen'));
      expect(screen, contains('fit: BoxFit.contain'));
      expect(
        screen,
        contains('AspectRatio(aspectRatio: 16 / 9, child: _buildPlayerArea())'),
      );
    },
  );

  test('inline Chewie is keyed and first frame keeps loading visible', () {
    expect(
      screen,
      contains('key: ValueKey<ChewieController>(chewieController)'),
    );
    expect(screen, contains('final waitingForFirstFrame ='));
    expect(screen, contains('value.position <= Duration.zero'));
    expect(screen, contains('visible: waitingForFirstFrame'));
  });

  test(
    'new episode cancels an old overlay fade before showing its overlay',
    () {
      final loadEpisode = _methodSource(screen, 'Future<void> _loadEpisode');
      final cancelFade = loadEpisode.indexOf(
        '_loadingOverlayFadeTimer?.cancel();',
      );
      final showOverlay = loadEpisode.indexOf('_showLoadingOverlay = true;');

      expect(cancelFade, greaterThanOrEqualTo(0));
      expect(showOverlay, greaterThan(cancelFade));
    },
  );

  test('old video listener is detached before its controller is disposed', () {
    final dispose = _methodSource(screen, 'Future<void> _disposePlayer');
    final detach = dispose.indexOf(
      'videoController?.removeListener(_handleVideoChanged);',
    );
    final disposeController = dispose.indexOf(
      'await videoController?.dispose();',
    );

    expect(detach, greaterThanOrEqualTo(0));
    expect(disposeController, greaterThan(detach));
  });
}

String _methodSource(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'Missing $signature');

  final asyncBody = source.indexOf(' async {', start);
  final openingBrace = asyncBody < 0 ? -1 : asyncBody + ' async '.length;
  expect(
    openingBrace,
    greaterThanOrEqualTo(0),
    reason: 'Missing body for $signature',
  );

  var depth = 0;
  for (var index = openingBrace; index < source.length; index += 1) {
    if (source[index] == '{') {
      depth += 1;
    } else if (source[index] == '}') {
      depth -= 1;
      if (depth == 0) return source.substring(start, index + 1);
    }
  }
  fail('Unterminated body for $signature');
}
