import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/screens/bailian_orders_screen.dart';
import 'package:novel_app/services/bailian_game_service.dart';

class _FakeService extends BailianGameService {
  _FakeService(this.pages);

  final List<BailianPaymentPage> pages;
  int calls = 0;
  final List<int> snapshotMaxIds = [];

  @override
  Future<BailianPaymentPage> listPayments(
    String token, {
    int offset = 0,
    int limit = 20,
    int snapshotMaxId = 0,
    String searchQuery = '',
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    snapshotMaxIds.add(snapshotMaxId);
    return pages[calls++];
  }
}

void main() {
  testWidgets('shows payment details and loads the next page', (tester) async {
    final service = _FakeService([
      BailianPaymentPage(
        items: [
          BailianPayment(
            id: 'ledger-entry-uuid',
            gameOrderId: 'game-1',
            productId: '1001',
            productName: '仙玉礼包',
            moneyCents: 600,
            coinCost: 60,
            balance: 940,
            status: 'fulfilled',
            createdAt: DateTime(2026, 7, 22, 12, 30),
          ),
        ],
        hasMore: true,
        snapshotMaxId: 77,
      ),
      const BailianPaymentPage(items: [], hasMore: false, snapshotMaxId: 77),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: BailianOrdersScreen(token: 'token', service: service),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的订单'), findsOneWidget);

    expect(find.text('仙玉礼包'), findsOneWidget);
    expect(find.text('60 樱花币  ·  ¥6.00'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('2026-07-22 12:30'), findsOneWidget);
    expect(service.pages.first.items.single.id, 'ledger-entry-uuid');

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(service.calls, 2);
    expect(service.snapshotMaxIds, [0, 77]);
    expect(find.text('加载更多'), findsNothing);
  });
}
