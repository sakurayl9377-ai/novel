import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/wallet_models.dart';
import 'package:novel_app/screens/profile_screen.dart';
import 'package:novel_app/services/bailian_game_service.dart';
import 'package:novel_app/services/interaction_service.dart';

class _FakeWalletService extends InteractionService {
  _FakeWalletService(this.snapshot);

  final SakuraWalletSnapshot snapshot;

  @override
  Future<SakuraWalletSnapshot> fetchWallet({
    required String token,
    int page = 1,
    int pageSize = 30,
    int snapshotMaxId = 0,
  }) async => snapshot;
}

class _FakeOrderService extends BailianGameService {
  _FakeOrderService(this.page);

  final BailianPaymentPage page;

  @override
  Future<BailianPaymentPage> listPayments(
    String token, {
    int offset = 0,
    int limit = 20,
    int snapshotMaxId = 0,
  }) async => page;
}

void main() {
  testWidgets('wallet shows balance, ledger, and existing order data', (
    tester,
  ) async {
    final walletService = _FakeWalletService(
      const SakuraWalletSnapshot(
        balance: 1250,
        ledger: SakuraWalletLedgerPage(
          page: 1,
          pageSize: 30,
          total: 1,
          items: [
            SakuraWalletLedgerEntry(
              id: '7',
              action: 'login_bonus',
              coinsDelta: 20,
              description: '今日登录赠送',
              createdAt: '2026-07-22T08:00:00.000Z',
            ),
          ],
        ),
      ),
    );
    final orderService = _FakeOrderService(
      BailianPaymentPage(
        items: [
          BailianPayment(
            id: 'payment-uuid',
            gameOrderId: 'game-1',
            productId: '1001',
            productName: '仙玉礼包',
            moneyCents: 100,
            coinCost: 10,
            balance: 1240,
            status: 'fulfilled',
            createdAt: DateTime(2026, 7, 22, 8, 5),
          ),
        ],
        hasMore: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWalletPage(
          token: 'token-a',
          service: walletService,
          orderService: orderService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1,250'), findsOneWidget);
    expect(find.text('今日登录赠送'), findsOneWidget);
    expect(find.text('+20'), findsOneWidget);

    await tester.tap(find.text('订单'));
    await tester.pumpAndSettle();
    expect(find.text('仙玉礼包'), findsOneWidget);
    expect(find.text('-10'), findsOneWidget);
    expect(find.text('支付成功'), findsOneWidget);
  });
}
