import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/screens/game_center_screen.dart';

void main() {
  Future<void> pumpCenter(
    WidgetTester tester, {
    required Size size,
    VoidCallback? onHorseRaceTap,
    VoidCallback? onBailianTap,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: GameCenterScreen(
          onHorseRaceTap: onHorseRaceTap,
          onBailianTap: onBailianTap,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows only the production game entries with stable keys', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpCenter(tester, size: const Size(390, 844));

      expect(find.text('樱游阁'), findsOneWidget);
      expect(find.text('樱愿召唤'), findsNothing);
      expect(find.text('视觉样片'), findsNothing);
      expect(find.text('樱花赛马'), findsOneWidget);
      expect(find.text('百练英雄'), findsOneWidget);
      expect(find.byKey(GameCenterScreen.horseRaceEntryKey), findsOneWidget);
      expect(find.byKey(GameCenterScreen.bailianEntryKey), findsOneWidget);
      expect(find.byKey(GameCenterScreen.ordersEntryKey), findsOneWidget);
      expect(find.bySemanticsLabel('樱花赛马，实时竞技'), findsOneWidget);
      expect(find.bySemanticsLabel('百练英雄，单点登录'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('uses one column on phones and two columns on tablets', (
    tester,
  ) async {
    await pumpCenter(tester, size: const Size(390, 844));
    final phoneBailian = tester.getTopLeft(
      find.byKey(GameCenterScreen.bailianEntryKey),
    );
    final phoneRace = tester.getTopLeft(
      find.byKey(GameCenterScreen.horseRaceEntryKey),
    );
    expect(phoneBailian.dx, phoneRace.dx);
    expect(phoneBailian.dy, greaterThan(phoneRace.dy));

    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpAndSettle();
    final tabletBailian = tester.getTopLeft(
      find.byKey(GameCenterScreen.bailianEntryKey),
    );
    final tabletRace = tester.getTopLeft(
      find.byKey(GameCenterScreen.horseRaceEntryKey),
    );
    expect(tabletBailian.dy, tabletRace.dy);
    expect(tabletBailian.dx, greaterThan(tabletRace.dx));
  });

  testWidgets('horse race entry can retain the caller login gate', (
    tester,
  ) async {
    var taps = 0;
    await pumpCenter(
      tester,
      size: const Size(390, 844),
      onHorseRaceTap: () => taps += 1,
    );

    await tester.tap(find.byKey(GameCenterScreen.horseRaceEntryKey));
    await tester.pump();

    expect(taps, 1);
    expect(find.byType(GameCenterScreen), findsOneWidget);
  });

  testWidgets('bailian entry can retain the caller login gate', (tester) async {
    var taps = 0;
    await pumpCenter(
      tester,
      size: const Size(390, 844),
      onBailianTap: () => taps += 1,
    );

    await tester.drag(
      find.byKey(GameCenterScreen.scrollKey),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(GameCenterScreen.bailianEntryKey));
    await tester.pump();

    expect(taps, 1);
  });
}
