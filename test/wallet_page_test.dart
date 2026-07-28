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
  _FakeOrderService(this.pages);

  final Map<int, BailianPaymentPage> pages;
  final List<_OrderRequest> requests = [];

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
    requests.add(
      _OrderRequest(
        offset: offset,
        limit: limit,
        snapshotMaxId: snapshotMaxId,
        searchQuery: searchQuery,
        fromDate: fromDate,
        toDate: toDate,
      ),
    );
    return pages[offset] ?? const BailianPaymentPage(items: [], hasMore: false);
  }
}

class _OrderRequest {
  const _OrderRequest({
    required this.offset,
    required this.limit,
    required this.snapshotMaxId,
    required this.searchQuery,
    required this.fromDate,
    required this.toDate,
  });

  final int offset;
  final int limit;
  final int snapshotMaxId;
  final String searchQuery;
  final DateTime? fromDate;
  final DateTime? toDate;
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
    final orderService = _FakeOrderService({
      0: BailianPaymentPage(
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
        total: 1,
      ),
    });

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
    expect(find.byKey(const ValueKey('wallet-order-search')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wallet-order-date-filter')),
      findsOneWidget,
    );
  });

  testWidgets('wallet search forwards the fuzzy query and resets paging', (
    tester,
  ) async {
    final orderService = _FakeOrderService({
      0: const BailianPaymentPage(
        items: [
          BailianPayment(
            id: 'matching-order',
            gameOrderId: 'game-match',
            productId: '1002',
            productName: '搜索结果',
            moneyCents: 600,
            coinCost: 60,
            balance: 1200,
            status: 'fulfilled',
          ),
        ],
        hasMore: false,
        snapshotMaxId: 42,
        total: 1,
      ),
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWalletPage(
          token: 'token-search',
          service: _FakeWalletService(_emptyWallet),
          orderService: orderService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('订单'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('wallet-order-search')),
      '  仙玉  ',
    );
    await tester.pump(const Duration(milliseconds: 349));
    expect(orderService.requests, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(orderService.requests, hasLength(2));
    expect(orderService.requests.last.offset, 0);
    expect(orderService.requests.last.limit, 20);
    expect(orderService.requests.last.snapshotMaxId, 0);
    expect(orderService.requests.last.searchQuery, '  仙玉  ');
    expect(find.text('搜索结果'), findsOneWidget);
  });

  testWidgets('wallet pagination replaces the current 20-order page', (
    tester,
  ) async {
    final firstPage = List.generate(
      20,
      (index) => BailianPayment(
        id: 'page-one-${index + 1}',
        gameOrderId: 'game-one-${index + 1}',
        productId: '${1000 + index}',
        productName: '第一页订单 ${index + 1}',
        moneyCents: 100,
        coinCost: 10,
        balance: 1000 - index,
        status: 'fulfilled',
      ),
    );
    final orderService = _FakeOrderService({
      0: BailianPaymentPage(
        items: firstPage,
        hasMore: true,
        snapshotMaxId: 99,
        total: 21,
        nextOffset: 20,
      ),
      20: const BailianPaymentPage(
        items: [
          BailianPayment(
            id: 'page-two-1',
            gameOrderId: 'game-two-1',
            productId: '2001',
            productName: '第二页唯一订单',
            moneyCents: 100,
            coinCost: 10,
            balance: 900,
            status: 'fulfilled',
          ),
        ],
        hasMore: false,
        snapshotMaxId: 99,
        total: 21,
        nextOffset: 21,
      ),
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWalletPage(
          token: 'token-pages',
          service: _FakeWalletService(_emptyWallet),
          orderService: orderService,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('订单'));
    await tester.pumpAndSettle();

    expect(orderService.requests.single.limit, 20);
    expect(find.text('第一页订单 1'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('wallet-orders-list')),
      const Offset(0, -2400),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('wallet-orders-next-page')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(orderService.requests, hasLength(2));
    expect(orderService.requests.last.offset, 20);
    expect(orderService.requests.last.limit, 20);
    expect(orderService.requests.last.snapshotMaxId, 99);
    expect(find.text('第二页唯一订单'), findsOneWidget);
    expect(find.text('第一页订单 20'), findsNothing);
    expect(find.text('第 2 / 2 页  共 21 笔'), findsOneWidget);
  });
}

const _emptyWallet = SakuraWalletSnapshot(
  balance: 0,
  ledger: SakuraWalletLedgerPage(page: 1, pageSize: 30, total: 0, items: []),
);
