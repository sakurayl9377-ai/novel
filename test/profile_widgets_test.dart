import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/screens/profile_screen.dart';

void main() {
  testWidgets('profile load error keeps an explicit retry action', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileLoadErrorBanner(
            message: '个人资料加载失败，请稍后重试',
            onRetry: () => retries++,
          ),
        ),
      ),
    );

    expect(find.text('个人资料加载失败，请稍后重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retries, 1);
  });

  test('legacy profile import keeps the public constructor available', () {
    expect(const ProfileScreen(), isA<StatefulWidget>());
  });
}
