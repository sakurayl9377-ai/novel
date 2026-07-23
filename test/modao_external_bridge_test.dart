import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/modao_game_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/modao-external-bridge');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'takePendingPaymentRequest' => <String, Object>{
              'gameOrderId': 'order-2001',
              'productId': 'pack.6',
            },
            'takePendingSsoAuthorizationRequest' => <String, Object>{
              'requestId': 'request_nonce_1234567890_ABCDEFGHIJ',
            },
            'ackPendingPaymentRequest' ||
            'ackPendingSsoAuthorizationRequest' ||
            'returnPaymentToGame' ||
            'returnSsoAuthorizationToGame' => true,
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('receives hot payment and SSO availability callbacks', () async {
    final bridge = ModaoPaymentBridge(platformChannel: channel);
    var paymentEvents = 0;
    var authorizationEvents = 0;
    bridge.start(
      onPaymentRequestAvailable: () => paymentEvents++,
      onSsoAuthorizationRequestAvailable: () => authorizationEvents++,
    );

    await _sendNativeMethodCall(
      channel.name,
      const MethodCall('onPaymentRequestAvailable'),
    );
    await _sendNativeMethodCall(
      channel.name,
      const MethodCall('onSsoAuthorizationRequestAvailable'),
    );

    expect(paymentEvents, 1);
    expect(authorizationEvents, 1);
    bridge.stop();
  });

  test(
    'peeks and acknowledges persistent external requests separately',
    () async {
      final bridge = ModaoPaymentBridge(platformChannel: channel);

      final payment = await bridge.takePendingRequest();
      final authorization = await bridge.takePendingSsoAuthorizationRequest();

      expect(payment?.gameOrderId, 'order-2001');
      expect(payment?.productId, 'pack.6');
      expect(authorization?.requestId, 'request_nonce_1234567890_ABCDEFGHIJ');
      expect(await bridge.acknowledgePaymentRequest(payment!), isTrue);
      expect(
        await bridge.acknowledgeSsoAuthorizationRequest(authorization!),
        isTrue,
      );

      expect(
        calls.map((call) => call.method),
        containsAllInOrder(<String>[
          'takePendingPaymentRequest',
          'takePendingSsoAuthorizationRequest',
          'ackPendingPaymentRequest',
          'ackPendingSsoAuthorizationRequest',
        ]),
      );
    },
  );

  test(
    'returns SSO ticket only through fixed explicit callback payload',
    () async {
      final bridge = ModaoPaymentBridge(platformChannel: channel);
      const request = ModaoSsoAuthorizationRequest(
        requestId: 'request_nonce_1234567890_ABCDEFGHIJ',
      );
      final ticket = ModaoSsoTicket(
        ticket: 'ticket_value_1234567890_ABCDEFGHIJK',
        exchangeUrl: Uri.parse('https://49.232.137.85/sakura/sso/exchange'),
      );

      expect(
        await bridge.returnSsoAuthorizationToGame(
          request: request,
          ticket: ticket,
        ),
        isTrue,
      );

      final callback = calls.singleWhere(
        (call) => call.method == 'returnSsoAuthorizationToGame',
      );
      final arguments = (callback.arguments as Map).cast<String, Object>();
      expect(arguments['packageName'], 'com.you91.fish.lucky');
      expect(arguments['requestId'], request.requestId);
      expect(arguments['ticket'], ticket.ticket);
      expect(
        arguments['exchangeUrl'],
        'https://49.232.137.85/sakura/sso/exchange',
      );
      expect(arguments['allowedSsoHost'], '49.232.137.85');
      expect(arguments, isNot(contains('uri')));
      expect(arguments, isNot(contains('data')));
    },
  );
}

Future<void> _sendNativeMethodCall(String channel, MethodCall call) {
  final completer = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) => completer.complete(),
      );
  return completer.future;
}
