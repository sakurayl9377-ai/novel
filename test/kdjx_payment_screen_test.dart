import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/interaction_user.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/screens/kdjx_payment_screen.dart';
import 'package:novel_app/services/kdjx_game_service.dart';
import 'package:provider/provider.dart';

void main() {
  const request = KdjxPaymentRequest(
    gameOrderId: 'order-2001',
    productId: 'recharge.6',
    accountId: 'account-7',
    roleId: 'role-9',
    serverKey: 'game.cn.1',
    yyId: '0',
    csvId: '6',
    returnNonce: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );

  Future<void> pumpPayment(
    WidgetTester tester, {
    required _FakeAuthProvider auth,
    required _FakeKdjxGameService service,
    _FakePaymentBridge? bridge,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<InteractionAuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: KdjxPaymentScreen(
            request: request,
            bridge: bridge ?? _FakePaymentBridge(),
            service: service,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('keeps the yuan price while charging Sakura coins', (
    tester,
  ) async {
    final auth = _FakeAuthProvider(loggedInValue: true);
    final service = _FakeKdjxGameService();
    await pumpPayment(tester, auth: auth, service: service);
    await tester.pumpAndSettle();

    expect(find.text('60钻石'), findsOneWidget);
    expect(find.text('6元'), findsOneWidget);
    expect(find.text('支付 6元'), findsOneWidget);
    expect(find.text('樱花币'), findsOneWidget);
    expect(find.text('60 樱花币'), findsOneWidget);
    expect(find.text('200 樱花币'), findsOneWidget);
    expect(service.payCalls, 0);

    await tester.tap(find.byKey(KdjxPaymentScreen.confirmButtonKey));
    await tester.pumpAndSettle();

    expect(service.payCalls, 1);
    expect(
      service.lastIdempotencyKey,
      'kdjx-pay-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(find.text('支付并发货成功'), findsOneWidget);
    expect(find.text('余额 140 樱花币'), findsOneWidget);
  });

  testWidgets('waits for restored Sakura login before previewing the order', (
    tester,
  ) async {
    final auth = _FakeAuthProvider(loggedInValue: false, loadingValue: true);
    final service = _FakeKdjxGameService();
    await pumpPayment(tester, auth: auth, service: service);

    expect(service.previewCalls, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    auth.restoreLoggedInSession();
    await tester.pumpAndSettle();

    expect(service.previewCalls, 1);
    expect(find.text('6元'), findsOneWidget);
    expect(find.byKey(KdjxPaymentScreen.confirmButtonKey), findsOneWidget);
  });

  testWidgets('keeps a paid processing order in Sakura until it is terminal', (
    tester,
  ) async {
    final auth = _FakeAuthProvider(loggedInValue: true);
    final bridge = _FakePaymentBridge();
    final service = _FakeKdjxGameService(
      payResult: _payment(status: 'processing', balance: 140),
      statusResults: [_payment(status: 'fulfilled', balance: 140)],
    );
    await pumpPayment(tester, auth: auth, service: service, bridge: bridge);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(KdjxPaymentScreen.confirmButtonKey));
    await tester.pump();

    expect(find.byKey(KdjxPaymentScreen.returnButtonKey), findsNothing);
    expect(find.textContaining('等待发货'), findsOneWidget);
    expect(bridge.returnCalls, 0);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(bridge.returnCalls, 0);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(service.statusCalls, 1);
    expect(find.byKey(KdjxPaymentScreen.returnButtonKey), findsOneWidget);
    expect(find.text('支付并发货成功'), findsOneWidget);
  });

  testWidgets('switching Sakura users invalidates and reloads the preview', (
    tester,
  ) async {
    final auth = _FakeAuthProvider(loggedInValue: true);
    final service = _FakeKdjxGameService();
    await pumpPayment(tester, auth: auth, service: service);
    await tester.pumpAndSettle();

    expect(find.text('200 樱花币'), findsOneWidget);
    auth.switchUser(userId: 77, token: 'other-token');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(service.previewTokens, ['app-token', 'other-token']);
    expect(find.text('500 樱花币'), findsOneWidget);

    await tester.tap(find.byKey(KdjxPaymentScreen.confirmButtonKey));
    await tester.pumpAndSettle();

    expect(service.payToken, 'other-token');
    expect(service.expectedPreview?.balance, 500);
  });

  for (final action in ['remove', 'logout']) {
    testWidgets('$action invalidates a previously loaded payment preview', (
      tester,
    ) async {
      final auth = _FakeAuthProvider(loggedInValue: true);
      final service = _FakeKdjxGameService();
      await pumpPayment(tester, auth: auth, service: service);
      await tester.pumpAndSettle();
      expect(find.byKey(KdjxPaymentScreen.confirmButtonKey), findsOneWidget);

      auth.clearCurrentSession();
      await tester.pump();

      expect(service.payCalls, 0);
      expect(find.byKey(KdjxPaymentScreen.confirmButtonKey), findsNothing);
    });
  }
}

KdjxPayment _payment({required String status, required int balance}) {
  return KdjxPayment(
    gameOrderId: 'order-2001',
    sakuraOrderId: 'sakura_order-2001',
    productId: 'recharge.6',
    productName: '60钻石',
    displayPrice: '6元',
    moneyCents: 600,
    coinCost: 60,
    balance: balance,
    status: status,
    lastError: '',
    canRetry: false,
  );
}

class _FakeAuthProvider extends InteractionAuthProvider {
  _FakeAuthProvider({required this.loggedInValue, this.loadingValue = false});

  bool loggedInValue;
  bool loadingValue;
  int currentUserId = 42;
  String currentToken = 'app-token';

  @override
  bool get isLoading => loadingValue;

  @override
  bool get isLoggedIn => loggedInValue;

  @override
  String get token => loggedInValue ? currentToken : '';

  @override
  InteractionUser? get user => loggedInValue
      ? InteractionUser(
          id: currentUserId,
          email: 'reader$currentUserId@example.com',
          nickname: 'Reader $currentUserId',
        )
      : null;

  void restoreLoggedInSession() {
    loadingValue = false;
    loggedInValue = true;
    notifyListeners();
  }

  void switchUser({required int userId, required String token}) {
    currentUserId = userId;
    currentToken = token;
    loggedInValue = true;
    notifyListeners();
  }

  void clearCurrentSession() {
    loggedInValue = false;
    notifyListeners();
  }
}

class _FakeKdjxGameService extends KdjxGameService {
  _FakeKdjxGameService({this.payResult, List<KdjxPayment>? statusResults})
    : statusResults = statusResults ?? <KdjxPayment>[];

  int previewCalls = 0;
  int payCalls = 0;
  int statusCalls = 0;
  String? lastIdempotencyKey;
  String? payToken;
  KdjxPayment? expectedPreview;
  final KdjxPayment? payResult;
  final List<KdjxPayment> statusResults;
  final List<String> previewTokens = [];

  @override
  Future<KdjxPayment> previewPayment(
    String token,
    KdjxPaymentRequest request,
  ) async {
    previewCalls++;
    previewTokens.add(token);
    return _payment(
      status: 'preview',
      balance: token == 'other-token' ? 500 : 200,
    );
  }

  @override
  Future<KdjxPayment> pay(
    String token,
    KdjxPaymentRequest request, {
    required String idempotencyKey,
    required KdjxPayment expectedPreview,
  }) async {
    payCalls++;
    payToken = token;
    lastIdempotencyKey = idempotencyKey;
    this.expectedPreview = expectedPreview;
    return payResult ?? _payment(status: 'fulfilled', balance: 140);
  }

  @override
  Future<KdjxPayment> paymentStatus(
    String token,
    KdjxPaymentRequest request,
  ) async {
    statusCalls++;
    return statusResults.removeAt(0);
  }
}

class _FakePaymentBridge extends KdjxPaymentBridge {
  int returnCalls = 0;

  @override
  Future<bool> returnToGame({
    required String gameOrderId,
    required String status,
    required int balance,
    required String returnNonce,
  }) async {
    returnCalls++;
    return true;
  }
}
