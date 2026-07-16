import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/screens/interaction_auth_screen.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('formal auth screen has no beta account entry', (tester) async {
    await _pumpAuthScreen(tester, betaTestAccountEnabled: false);

    expect(
      find.byKey(const ValueKey('beta-test-account-button')),
      findsNothing,
    );
  });

  testWidgets('beta auth screen exposes the one-tap test account entry', (
    tester,
  ) async {
    await _pumpAuthScreen(tester, betaTestAccountEnabled: true);

    expect(
      find.byKey(const ValueKey('beta-test-account-button')),
      findsOneWidget,
    );
  });
}

Future<void> _pumpAuthScreen(
  WidgetTester tester, {
  required bool betaTestAccountEnabled,
}) {
  return tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => InteractionAuthProvider(
        betaTestAccountEnabled: betaTestAccountEnabled,
      ),
      child: const MaterialApp(home: InteractionAuthScreen()),
    ),
  );
}
