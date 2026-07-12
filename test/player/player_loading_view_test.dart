import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/widgets/player_loading_view.dart';

void main() {
  testWidgets('shows honest weak-network state and recovery actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        PlayerLoadingView(
          coverUrl: '',
          status: PlayerLoadingStatus.buffering,
          elapsedOverride: const Duration(seconds: 13),
          onRetry: () {},
          onChangeSource: () {},
        ),
      ),
    );

    expect(find.text('正在缓冲'), findsOneWidget);
    expect(find.text('网络较慢，正在继续连接'), findsOneWidget);
    expect(find.byKey(const Key('player-loading-retry')), findsOneWidget);
    expect(
      find.byKey(const Key('player-loading-change-source')),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('uses static decoration when reduced motion is enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const PlayerLoadingView(coverUrl: ''), disableAnimations: true),
    );

    expect(
      find.byKey(const Key('player-loading-static-petals')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('player-loading-static-dots')), findsOneWidget);
    expect(
      find.byKey(const Key('player-loading-animated-petals')),
      findsNothing,
    );
  });

  testWidgets('advances the visible loading animation when motion is enabled', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const PlayerLoadingView(coverUrl: '')));

    final firstPainter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byKey(const Key('player-loading-animated-petals')),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter;
    await tester.pump(const Duration(milliseconds: 450));
    final secondPainter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byKey(const Key('player-loading-animated-petals')),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter;

    expect(firstPainter, isNot(same(secondPainter)));
  });

  testWidgets('falls back to the theme gradient when cover cannot load', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const PlayerLoadingView(coverUrl: 'not-a-valid-network-url'),
        disableAnimations: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('player-loading-fallback')), findsOneWidget);
  });

  testWidgets('fades away after the caller reports the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const PlayerLoadingView(coverUrl: '', visible: true)),
    );
    await tester.pumpWidget(
      _host(const PlayerLoadingView(coverUrl: '', visible: false)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final opacity = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('player-loading-opacity')),
    );
    expect(opacity.opacity, 0);
  });

  testWidgets('lets taps reach controls before recovery actions appear', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps += 1,
            ),
            const PlayerLoadingView(
              coverUrl: '',
              status: PlayerLoadingStatus.buffering,
              elapsedOverride: Duration(seconds: 4),
            ),
          ],
        ),
      ),
    );

    await tester.tapAt(const Offset(320, 180));
    expect(taps, 1);
  });
}

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: SizedBox(width: 640, height: 360, child: child)),
  ),
);
