import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/screens/modao_payment_screen.dart';
import 'package:novel_app/services/modao_game_service.dart';
import 'package:provider/provider.dart';

void main() {
  const request = ModaoPaymentRequest(
    gameOrderId: 'order-2001',
    productId: 'pack.6',
  );

  Future<void> pumpPayment(
    WidgetTester tester, {
    required _FakeAuthProvider auth,
    required _FakeModaoGameService service,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<InteractionAuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: ModaoPaymentScreen(
            request: request,
            bridge: _FakePaymentBridge(),
            service: service,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows only the server preview price before user confirmation', (
    tester,
  ) async {
    final auth = _FakeAuthProvider(loggedInValue: true);
    final service = _FakeModaoGameService();
    await pumpPayment(tester, auth: auth, service: service);
    await tester.pumpAndSettle();

    expect(find.text('6 元礼包'), findsOneWidget);
    expect(find.text('60 樱花币'), findsOneWidget);
    expect(find.text('¥6.00'), findsOneWidget);
    expect(find.text('10 樱花币 = ¥1.00'), findsOneWidget);
    expect(find.text('200 樱花币'), findsOneWidget);
    expect(service.payCalls, 0);

    await tester.tap(find.byKey(const ValueKey('modao-confirm-payment')));
    await tester.pumpAndSettle();

    expect(service.payCalls, 1);
    expect(service.lastIdempotencyKey, 'fixed-idempotency-key');
    expect(find.text('支付并发货成功'), findsOneWidget);
    expect(find.text('余额 140 樱花币'), findsOneWidget);
  });

  testWidgets('waits for restored login before resuming the pending order', (
    tester,
  ) async {
    final auth = _FakeAuthProvider(loggedInValue: false, loadingValue: true);
    final service = _FakeModaoGameService();
    await pumpPayment(tester, auth: auth, service: service);

    expect(service.previewCalls, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    auth.restoreLoggedInSession();
    await tester.pumpAndSettle();

    expect(service.previewCalls, 1);
    expect(find.text('6 元礼包'), findsOneWidget);
    expect(find.byKey(const ValueKey('modao-confirm-payment')), findsOneWidget);
  });
}

class _FakeAuthProvider extends InteractionAuthProvider {
  _FakeAuthProvider({required this.loggedInValue, this.loadingValue = false});

  bool loggedInValue;
  bool loadingValue;

  @override
  bool get isLoading => loadingValue;

  @override
  bool get isLoggedIn => loggedInValue;

  @override
  String get token => loggedInValue ? 'app-token' : '';

  void restoreLoggedInSession() {
    loadingValue = false;
    loggedInValue = true;
    notifyListeners();
  }
}

class _FakeModaoGameService extends ModaoGameService {
  int previewCalls = 0;
  int payCalls = 0;
  String? lastIdempotencyKey;

  @override
  String createPaymentIdempotencyKey() => 'fixed-idempotency-key';

  @override
  Future<ModaoPayment> previewPayment(
    String token,
    ModaoPaymentRequest request,
  ) async {
    previewCalls++;
    return const ModaoPayment(
      gameOrderId: 'order-2001',
      productId: 'pack.6',
      productName: '6 元礼包',
      moneyCents: 600,
      coinCost: 60,
      balance: 200,
      status: 'preview',
      lastError: '',
      canRetry: false,
    );
  }

  @override
  Future<ModaoPayment> pay(
    String token,
    ModaoPaymentRequest request, {
    required String idempotencyKey,
  }) async {
    payCalls++;
    lastIdempotencyKey = idempotencyKey;
    return const ModaoPayment(
      gameOrderId: 'order-2001',
      productId: 'pack.6',
      productName: '6 元礼包',
      moneyCents: 600,
      coinCost: 60,
      balance: 140,
      status: 'fulfilled',
      lastError: '',
      canRetry: false,
    );
  }
}

class _FakePaymentBridge extends ModaoPaymentBridge {
  @override
  Future<bool> returnToGame({
    required String gameOrderId,
    required String status,
    required int balance,
  }) async => true;
}
