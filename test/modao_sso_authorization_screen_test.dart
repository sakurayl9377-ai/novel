import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/interaction_user.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/screens/modao_sso_authorization_screen.dart';
import 'package:novel_app/services/modao_game_service.dart';
import 'package:provider/provider.dart';

void main() {
  const request = ModaoSsoAuthorizationRequest(
    requestId: 'request_nonce_1234567890_ABCDEFGHIJ',
  );

  Future<void> pumpAuthorization(
    WidgetTester tester, {
    required _FakeAuthorizationAuthProvider auth,
    required _FakeAuthorizationService service,
    required _FakeAuthorizationBridge bridge,
    ModaoLoginLauncher? loginLauncher,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<InteractionAuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: ModaoSsoAuthorizationScreen(
            request: request,
            bridge: bridge,
            service: service,
            loginLauncher: loginLauncher,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'requires explicit consent before issuing and returning a ticket',
    (tester) async {
      final auth = _FakeAuthorizationAuthProvider(loggedInValue: true);
      final service = _FakeAuthorizationService();
      final bridge = _FakeAuthorizationBridge();
      await pumpAuthorization(
        tester,
        auth: auth,
        service: service,
        bridge: bridge,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('modao-auth-confirmation')),
        findsOneWidget,
      );
      expect(find.text('樱花用户'), findsOneWidget);
      expect(service.ticketCalls, 0);
      expect(bridge.returnCalls, 0);

      await tester.tap(
        find.byKey(const ValueKey<String>('modao-auth-confirm')),
      );
      await tester.pumpAndSettle();

      expect(service.ticketCalls, 1);
      expect(service.lastToken, 'app-token');
      expect(bridge.returnCalls, 1);
      expect(bridge.lastRequest?.requestId, request.requestId);
      expect(bridge.lastTicket?.ticket, service.ticket.ticket);
    },
  );

  testWidgets(
    'waits for session restore then resumes after existing login flow',
    (tester) async {
      final auth = _FakeAuthorizationAuthProvider(
        loggedInValue: false,
        loadingValue: true,
      );
      final service = _FakeAuthorizationService();
      final bridge = _FakeAuthorizationBridge();
      var loginCalls = 0;
      await pumpAuthorization(
        tester,
        auth: auth,
        service: service,
        bridge: bridge,
        loginLauncher: (_) async {
          loginCalls++;
          auth.logIn();
          return true;
        },
      );

      expect(
        find.byKey(const ValueKey<String>('modao-auth-restoring')),
        findsOneWidget,
      );
      expect(loginCalls, 0);

      auth.completeRestoreLoggedOut();
      await tester.pumpAndSettle();

      expect(loginCalls, 1);
      expect(
        find.byKey(const ValueKey<String>('modao-auth-confirmation')),
        findsOneWidget,
      );
      expect(service.ticketCalls, 0);
      expect(bridge.returnCalls, 0);
    },
  );

  testWidgets('cancelling does not issue a ticket', (tester) async {
    final auth = _FakeAuthorizationAuthProvider(loggedInValue: true);
    final service = _FakeAuthorizationService();
    final bridge = _FakeAuthorizationBridge();
    await pumpAuthorization(
      tester,
      auth: auth,
      service: service,
      bridge: bridge,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('modao-auth-cancel')));
    await tester.pumpAndSettle();

    expect(service.ticketCalls, 0);
    expect(bridge.returnCalls, 0);
  });
}

class _FakeAuthorizationAuthProvider extends InteractionAuthProvider {
  _FakeAuthorizationAuthProvider({
    required this.loggedInValue,
    this.loadingValue = false,
  });

  bool loggedInValue;
  bool loadingValue;

  @override
  bool get isLoading => loadingValue;

  @override
  bool get isLoggedIn => loggedInValue;

  @override
  String get token => loggedInValue ? 'app-token' : '';

  @override
  InteractionUser? get user => loggedInValue
      ? const InteractionUser(
          id: 7,
          email: 'sakura@example.com',
          nickname: '樱花用户',
        )
      : null;

  void completeRestoreLoggedOut() {
    loadingValue = false;
    notifyListeners();
  }

  void logIn() {
    loadingValue = false;
    loggedInValue = true;
    notifyListeners();
  }
}

class _FakeAuthorizationService extends ModaoGameService {
  final ModaoSsoTicket ticket = ModaoSsoTicket(
    ticket: 'ticket_value_1234567890_ABCDEFGHIJK',
    exchangeUrl: Uri.parse('https://49.232.137.85/sakura/sso/exchange'),
  );
  int ticketCalls = 0;
  String? lastToken;

  @override
  Future<ModaoSsoTicket> createSsoTicket(String token) async {
    ticketCalls++;
    lastToken = token;
    return ticket;
  }
}

class _FakeAuthorizationBridge extends ModaoPaymentBridge {
  int returnCalls = 0;
  ModaoSsoAuthorizationRequest? lastRequest;
  ModaoSsoTicket? lastTicket;

  @override
  Future<bool> returnSsoAuthorizationToGame({
    required ModaoSsoAuthorizationRequest request,
    required ModaoSsoTicket ticket,
  }) async {
    returnCalls++;
    lastRequest = request;
    lastTicket = ticket;
    return true;
  }
}
