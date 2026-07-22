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

  test('wallet and space keep their expected service pages', () {
    expect(profileMoreServicesOrder[4], '钱包');
    expect(profileMoreServicesOrder.indexOf('空间'), greaterThanOrEqualTo(8));
    expect(profileMoreServicesOrder.take(8), contains('游戏中心'));
    expect(profileMoreServicesOrder.take(8), isNot(contains('空间')));
  });

  testWidgets('more services pager follows each page row count', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: ProfileServicesPager(
              children: List.generate(
                12,
                (index) => Center(child: Text('service $index')),
              ),
            ),
          ),
        ),
      ),
    );

    const viewportKey = ValueKey('profile-services-viewport');
    const firstSeparatorsKey = ValueKey('profile-services-separators-0');
    const secondSeparatorsKey = ValueKey('profile-services-separators-1');

    expect(tester.getSize(find.byKey(viewportKey)).height, 132);
    expect(tester.getSize(find.byKey(firstSeparatorsKey)).height, 132);

    await tester.drag(find.byType(PageView), const Offset(-350, 0));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(viewportKey)).height, 62);
    expect(tester.getSize(find.byKey(secondSeparatorsKey)).height, 62);
    expect(find.text('service 11'), findsOneWidget);
  });
}
