import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/interaction_user.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/screens/kdjx_authorization_screen.dart';
import 'package:novel_app/services/kdjx_game_service.dart';
import 'package:provider/provider.dart';

void main() {
  const deviceCode = 'kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const request = KdjxAuthorizationRequest(
    deviceCode: deviceCode,
    userCode: 'ABCD-2345',
  );

  testWidgets('approves a device code with the current Sakura session', (
    tester,
  ) async {
    final auth = _FakeAuthProvider();
    final service = _FakeKdjxGameService();
    final bridge = _FakeKdjxBridge();

    await tester.pumpWidget(
      ChangeNotifierProvider<InteractionAuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: KdjxAuthorizationScreen(
            request: request,
            bridge: bridge,
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sakura 登录授权'), findsOneWidget);
    expect(find.text('口袋觉醒正在请求登录'), findsOneWidget);
    expect(find.byKey(KdjxAuthorizationScreen.userCodeKey), findsOneWidget);
    expect(find.text('ABCD-2345'), findsOneWidget);
    await tester.tap(find.byKey(KdjxAuthorizationScreen.approveButtonKey));
    await tester.pumpAndSettle();

    expect(service.token, 'app-access-token');
    expect(service.request?.deviceCode, deviceCode);
    expect(service.request?.userCode, 'ABCD-2345');
    expect(service.approve, isTrue);
    expect(bridge.deviceCode, deviceCode);
    expect(bridge.status, 'approved');
  });

  testWidgets('denies a device code before returning to the game', (
    tester,
  ) async {
    final auth = _FakeAuthProvider();
    final service = _FakeKdjxGameService();
    final bridge = _FakeKdjxBridge();

    await tester.pumpWidget(
      ChangeNotifierProvider<InteractionAuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: KdjxAuthorizationScreen(
            request: request,
            bridge: bridge,
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(KdjxAuthorizationScreen.denyButtonKey));
    await tester.pumpAndSettle();

    expect(service.approve, isFalse);
    expect(bridge.deviceCode, deviceCode);
    expect(bridge.status, 'denied');
  });

  testWidgets('does not authorize after the Sakura account changes', (
    tester,
  ) async {
    final auth = _FakeAuthProvider();
    final service = _FakeKdjxGameService();
    final bridge = _FakeKdjxBridge();

    await tester.pumpWidget(
      ChangeNotifierProvider<InteractionAuthProvider>.value(
        value: auth,
        child: MaterialApp(
          home: KdjxAuthorizationScreen(
            request: request,
            bridge: bridge,
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    auth.switchUser(userId: 77, token: 'other-token');
    await tester.pump();

    expect(find.textContaining('账号已变化'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(KdjxAuthorizationScreen.approveButtonKey),
    );
    expect(button.onPressed, isNull);
    expect(service.request, isNull);
    expect(bridge.status, isNull);
  });

  test('rejects malformed native device authorization requests', () {
    expect(
      () => KdjxAuthorizationRequest.fromPlatform({
        'deviceCode': '../not-a-device-code',
        'userCode': 'ABCD-2345',
      }),
      throwsA(isA<KdjxGameException>()),
    );
  });

  test('normalizes and requires the authorization user code', () {
    expect(
      KdjxAuthorizationRequest.fromPlatform({
        'deviceCode': deviceCode,
        'userCode': 'abcd2345',
      }).userCode,
      'ABCD-2345',
    );
    expect(
      () => KdjxAuthorizationRequest.fromPlatform({'deviceCode': deviceCode}),
      throwsA(isA<KdjxGameException>()),
    );
  });
}

class _FakeAuthProvider extends InteractionAuthProvider {
  int currentUserId = 42;
  String currentToken = 'app-access-token';

  @override
  bool get isLoading => false;

  @override
  bool get isLoggedIn => true;

  @override
  String get token => currentToken;

  @override
  InteractionUser get user => InteractionUser(
    id: currentUserId,
    email: 'reader$currentUserId@example.com',
    nickname: 'Reader $currentUserId',
  );

  void switchUser({required int userId, required String token}) {
    currentUserId = userId;
    currentToken = token;
    notifyListeners();
  }
}

class _FakeKdjxGameService extends KdjxGameService {
  String? token;
  KdjxAuthorizationRequest? request;
  bool? approve;

  @override
  Future<void> decideDeviceAuthorization(
    String token,
    KdjxAuthorizationRequest request, {
    required bool approve,
  }) async {
    this.token = token;
    this.request = request;
    this.approve = approve;
  }
}

class _FakeKdjxBridge extends KdjxPaymentBridge {
  String? deviceCode;
  String? status;

  @override
  Future<bool> returnAuthorizationToGame({
    required String deviceCode,
    required String status,
  }) async {
    this.deviceCode = deviceCode;
    this.status = status;
    return true;
  }
}
