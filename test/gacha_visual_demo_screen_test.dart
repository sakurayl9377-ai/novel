import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/card_game/gacha_visual_demo_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDemo(
    WidgetTester tester, {
    bool disableAnimations = false,
    bool accessibleNavigation = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            disableAnimations: disableAnimations,
            accessibleNavigation: accessibleNavigation,
          ),
          child: const GachaVisualDemoScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('lobby exposes four effect tiers and both pull actions', (
    tester,
  ) async {
    await pumpDemo(tester, disableAnimations: true);

    expect(find.byKey(GachaVisualDemoKeys.screen), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.localModeBadge), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.reducedMotionBadge), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.singlePullButton), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.tenPullButton), findsOneWidget);
    for (final rarity in GachaDemoRarity.values) {
      expect(find.byKey(GachaVisualDemoKeys.rarity(rarity)), findsOneWidget);
    }

    final particlePaint = find.descendant(
      of: find.byKey(GachaVisualDemoKeys.particleLayer),
      matching: find.byType(CustomPaint),
    );
    expect(particlePaint, findsWidgets);
  });

  testWidgets('disableAnimations reveals a selected UR card immediately', (
    tester,
  ) async {
    await pumpDemo(tester, disableAnimations: true);

    await tester.tap(
      find.byKey(GachaVisualDemoKeys.rarity(GachaDemoRarity.ur)),
    );
    await tester.pump();
    await tester.tap(find.byKey(GachaVisualDemoKeys.singlePullButton));
    await tester.pump();

    expect(find.byKey(GachaVisualDemoKeys.resultView), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.singleResultCard), findsOneWidget);
    expect(find.textContaining('UR'), findsWidgets);
    expect(find.byKey(GachaVisualDemoKeys.skipButton), findsNothing);
    expect(find.byKey(GachaVisualDemoKeys.urRevealOverlay), findsNothing);
  });

  testWidgets('accessible navigation uses the same static reveal path', (
    tester,
  ) async {
    await pumpDemo(tester, accessibleNavigation: true);

    await tester.tap(find.byKey(GachaVisualDemoKeys.tenPullButton));
    await tester.pump();

    expect(find.byKey(GachaVisualDemoKeys.resultView), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.tenResultGrid), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.skipButton), findsNothing);
    for (var index = 0; index < 10; index++) {
      expect(find.byKey(GachaVisualDemoKeys.resultCard(index)), findsOneWidget);
    }
  });

  testWidgets('animated ten pull can be skipped without changing results', (
    tester,
  ) async {
    await pumpDemo(tester);

    await tester.tap(find.byKey(GachaVisualDemoKeys.tenPullButton));
    await tester.pump();

    expect(find.byKey(GachaVisualDemoKeys.animationStage), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.skipButton), findsOneWidget);

    await tester.tap(find.byKey(GachaVisualDemoKeys.skipButton));
    await tester.pump();

    expect(find.byKey(GachaVisualDemoKeys.animationStage), findsNothing);
    expect(find.byKey(GachaVisualDemoKeys.tenResultGrid), findsOneWidget);
    for (var index = 0; index < 10; index++) {
      expect(find.byKey(GachaVisualDemoKeys.resultCard(index)), findsOneWidget);
    }
  });

  testWidgets('UR selection enters its full-screen exclusive reveal', (
    tester,
  ) async {
    await pumpDemo(tester);

    await tester.tap(
      find.byKey(GachaVisualDemoKeys.rarity(GachaDemoRarity.ur)),
    );
    await tester.pump();
    await tester.tap(find.byKey(GachaVisualDemoKeys.singlePullButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 950));
    await tester.pump();

    expect(find.byKey(GachaVisualDemoKeys.urRevealOverlay), findsOneWidget);
    expect(find.byKey(GachaVisualDemoKeys.skipButton), findsOneWidget);

    await tester.tap(find.byKey(GachaVisualDemoKeys.skipButton));
    await tester.pump();
    expect(find.byKey(GachaVisualDemoKeys.singleResultCard), findsOneWidget);
  });
}
