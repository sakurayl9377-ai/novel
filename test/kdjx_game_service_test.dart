import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/kdjx_game_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const apkSha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const signingSha =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  Map<String, dynamic> manifestJson({
    String packageName = KdjxGameManifest.expectedPackageName,
    String certificate = signingSha,
    bool includeParts = true,
    List<String> downloadHosts = const ['novel.kxhub.xyz'],
  }) {
    final apkFileName = 'kdjx-3-aaaaaaaaaaaa.apk';
    return {
      'packageName': packageName,
      'versionName': '2.1.0.0',
      'versionCode': 3,
      'apkUrl': 'https://${downloadHosts.first}/games/kdjx/$apkFileName',
      'apkUrls': [
        for (final host in downloadHosts)
          'https://$host/games/kdjx/$apkFileName',
      ],
      'sizeBytes': 500,
      'sha256': apkSha,
      'signingCertificateSha256': certificate,
      'notes': ['Sakura SSO'],
      if (includeParts)
        'parts': [
          for (var index = 0; index < 5; index++)
            {
              'index': index,
              'url':
                  'https://${downloadHosts[index % downloadHosts.length]}/games/kdjx/'
                  'kdjx-3-aaaaaaaaaaaa.part-${index.toString().padLeft(3, '0')}.apk',
              'sizeBytes': 100,
              'sha256': '${index + 1}' * 64,
            },
        ],
    };
  }

  KdjxGameService serviceWith({
    http.Client? client,
    MethodChannel? channel,
    Set<String>? trustedDownloadHosts,
    String? apiBaseUrl,
  }) {
    return KdjxGameService(
      httpClient: client,
      platformChannel: channel,
      expectedSigningCertificateSha256: signingSha,
      trustedDownloadHosts: trustedDownloadHosts,
      apiBaseUrl: apiBaseUrl,
    );
  }

  test('accepts the fixed five-part release manifest', () async {
    http.Request? captured;
    final service = serviceWith(
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(manifestJson()), 200, request: request);
      }),
    );

    final manifest = await service.fetchManifest();

    expect(captured?.url.path, '/games/kdjx/manifest.json');
    expect(captured?.url.queryParameters['cacheBust'], isNotEmpty);
    expect(captured?.followRedirects, isFalse);
    expect(manifest.packageName, KdjxGameManifest.expectedPackageName);
    expect(manifest.parts, hasLength(5));
    expect(
      manifest.parts.fold<int>(0, (sum, part) => sum + part.sizeBytes),
      manifest.sizeBytes,
    );
    expect(manifest.downloadFileName, 'kdjx-3-aaaaaaaaaaaa.apk');
  });

  test('passes part hashes and whole-APK fallback to Android', () async {
    const channel = MethodChannel('test/kdjx-parts');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return {
            'status': 'queued',
            'sourceIndex': 0,
            'sourceUrl': (call.arguments as Map)['url'],
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final service = serviceWith(channel: channel);
    final manifest = KdjxGameManifest.fromJson(manifestJson());

    final state = await service.startDownload(manifest, allowMetered: false);

    expect(state.status, KdjxDownloadStatus.queued);
    expect(captured?.method, 'startDownload');
    final arguments = captured?.arguments as Map;
    expect(arguments['url'], endsWith('kdjx-3-aaaaaaaaaaaa.apk'));
    expect(arguments['trustedDownloadHosts'], ['novel.kxhub.xyz']);
    expect(arguments['signingCertificateSha256'], signingSha);
    expect(arguments['parts'], hasLength(5));
    expect((arguments['parts'] as List).first, {
      'index': 0,
      'url':
          'https://novel.kxhub.xyz/games/kdjx/'
          'kdjx-3-aaaaaaaaaaaa.part-000.apk',
      'sizeBytes': 100,
      'sha256': '1' * 64,
    });
  });

  test('rejects mirrors and raw IP download hosts', () {
    expect(
      () => serviceWith(
        trustedDownloadHosts: const {'novel.kxhub.xyz', 'mirror.kxhub.xyz'},
      ),
      throwsArgumentError,
    );
    expect(
      () => serviceWith(trustedDownloadHosts: const {'47.88.26.14'}),
      throwsArgumentError,
    );
  });

  test('allows only owned Novel API entry points', () {
    expect(
      () => serviceWith(apiBaseUrl: 'https://49.232.137.85/novel-api'),
      returnsNormally,
    );
    expect(
      () => serviceWith(apiBaseUrl: 'https://novel.kxhub.xyz/novel-api'),
      returnsNormally,
    );
    for (final value in <String>[
      'https://legacy.example.com/novel-api',
      'http://49.232.137.85/novel-api',
      'https://49.232.137.85/other',
      'https://novel.kxhub.xyz/novel-api?target=evil',
    ]) {
      expect(() => serviceWith(apiBaseUrl: value), throwsArgumentError);
    }
  });

  test(
    'rejects non-contiguous parts, wrong totals, and an unpinned signer',
    () {
      var json = manifestJson();
      (json['parts'] as List)[2]['index'] = 4;
      expect(
        () => serviceWith().startDownload(
          KdjxGameManifest.fromJson(json),
          allowMetered: false,
        ),
        throwsA(isA<KdjxGameException>()),
      );

      json = manifestJson();
      (json['parts'] as List)[0]['sizeBytes'] = 99;
      expect(
        () => serviceWith().startDownload(
          KdjxGameManifest.fromJson(json),
          allowMetered: false,
        ),
        throwsA(isA<KdjxGameException>()),
      );

      json = manifestJson(certificate: 'c' * 64);
      expect(
        () => serviceWith().startDownload(
          KdjxGameManifest.fromJson(json),
          allowMetered: false,
        ),
        throwsA(isA<KdjxGameException>()),
      );
    },
  );

  test('verifies the assembled APK metadata and pinned signer', () async {
    const channel = MethodChannel('test/kdjx-inspect');
    var actualSigner = signingSha;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'inspectApk');
          return {
            'exists': true,
            'sizeBytes': 500,
            'sha256': apkSha,
            'packageName': KdjxGameManifest.expectedPackageName,
            'versionCode': 3,
            'signingCertificateSha256s': [actualSigner],
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final service = serviceWith(channel: channel);
    final manifest = KdjxGameManifest.fromJson(manifestJson());

    await service.verifyDownloadedApk(manifest, r'C:\games\kdjx.apk');

    actualSigner = 'd' * 64;
    await expectLater(
      service.verifyDownloadedApk(manifest, r'C:\games\kdjx.apk'),
      throwsA(
        isA<KdjxGameException>().having(
          (error) => error.message,
          'message',
          contains('签名'),
        ),
      ),
    );
  });

  test('launches KDJX with only the fixed package name', () async {
    const channel = MethodChannel('test/kdjx-launch');
    MethodCall? launchCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          launchCall = call;
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final service = serviceWith(channel: channel);

    await service.launchGame('42');

    final arguments = launchCall?.arguments as Map;
    expect(arguments, {
      'packageName': KdjxGameManifest.expectedPackageName,
      'expectedUserId': '42',
    });
    expect(arguments.containsKey('ticket'), isFalse);
    expect(arguments.containsKey('credential'), isFalse);
    expect(arguments.containsKey('gameOpenId'), isFalse);
    expect(arguments.containsKey('exchangeUrl'), isFalse);
    await expectLater(
      service.launchGame('042'),
      throwsA(isA<KdjxGameException>()),
    );
  });

  test(
    'acknowledges persisted native authorization and payment requests',
    () async {
      const channel = MethodChannel('test/kdjx-ack');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final bridge = KdjxPaymentBridge(platformChannel: channel);
      const authorization = KdjxAuthorizationRequest(
        deviceCode: 'kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        userCode: 'ABCD-2345',
      );
      const payment = KdjxPaymentRequest(
        gameOrderId: 'order-1001',
        productId: 'recharge.6',
        accountId: 'account-7',
        roleId: 'role-9',
        serverKey: 'game.cn.1',
        yyId: '0',
        csvId: '6',
        returnNonce: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );

      expect(
        await bridge.acknowledgeAuthorizationRequest(authorization),
        isTrue,
      );
      expect(await bridge.acknowledgePaymentRequest(payment), isTrue);
      expect(calls.map((call) => call.method), [
        'ackPendingAuthorizationRequest',
        'ackPendingPaymentRequest',
      ]);
      expect(calls.last.arguments, {
        'gameOrderId': payment.gameOrderId,
        'returnNonce': payment.returnNonce,
      });
      expect(calls.first.arguments, {
        'deviceCode': authorization.deviceCode,
        'userCode': authorization.userCode,
      });
    },
  );

  test('approves only a valid device code using the Sakura session', () async {
    http.Request? captured;
    final service = serviceWith(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'ok': true, 'status': 'approved'}),
          200,
          request: request,
        );
      }),
    );
    const request = KdjxAuthorizationRequest(
      deviceCode: 'kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      userCode: 'ABCD-2345',
    );

    await service.decideDeviceAuthorization(
      'app-access-token',
      request,
      approve: true,
    );

    expect(
      captured?.url.path,
      '/novel-api/games/kdjx/device-authorizations/approve',
    );
    expect(captured?.headers['Authorization'], 'Bearer app-access-token');
    expect(jsonDecode(captured!.body), {
      'deviceCode': request.deviceCode,
      'userCode': request.userCode,
    });
  });

  test('derives a stable payment key from the trusted return nonce', () {
    const request = KdjxPaymentRequest(
      gameOrderId: 'order-1000',
      productId: 'recharge.6',
      accountId: 'account-7',
      roleId: 'role-9',
      serverKey: 'game.cn.1',
      yyId: '0',
      csvId: '6',
      returnNonce: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );

    expect(
      serviceWith().createPaymentIdempotencyKey(request),
      'kdjx-pay-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(
      serviceWith().createPaymentIdempotencyKey(request),
      serviceWith().createPaymentIdempotencyKey(request),
    );
  });

  test('payment submits and verifies the exact previewed quote', () async {
    const request = KdjxPaymentRequest(
      gameOrderId: 'order-quote-1',
      productId: 'recharge.6',
      accountId: 'account-7',
      roleId: 'role-9',
      serverKey: 'game.cn.1',
      yyId: '0',
      csvId: '6',
      returnNonce: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    const preview = KdjxPayment(
      gameOrderId: 'order-quote-1',
      sakuraOrderId: 'sakura_order-quote-1',
      productId: 'recharge.6',
      productName: '60钻石',
      displayPrice: '6元',
      moneyCents: 600,
      coinCost: 60,
      balance: 300,
      status: 'preview',
      lastError: '',
      canRetry: false,
    );
    http.Request? captured;
    final service = serviceWith(
      client: MockClient((incoming) async {
        captured = incoming;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'item': {
                'gameOrderId': request.gameOrderId,
                'sakuraOrderId': preview.sakuraOrderId,
                'productId': request.productId,
                'productName': preview.productName,
                'displayPrice': preview.displayPrice,
                'moneyCents': preview.moneyCents,
                'coinCost': preview.coinCost,
                'balance': 240,
                'status': 'fulfilled',
              },
            }),
          ),
          200,
          request: incoming,
        );
      }),
    );

    final payment = await service.pay(
      'app-token',
      request,
      idempotencyKey: 'kdjx-pay-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      expectedPreview: preview,
    );

    expect(payment.status, 'fulfilled');
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['expectedMoneyCents'], 600);
    expect(body['expectedCoinCost'], 60);
    expect(body['expectedDisplayPrice'], '6元');
    expect(
      captured?.headers['Idempotency-Key'],
      'kdjx-pay-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
  });

  test(
    'payment rejects a response whose quote changed after preview',
    () async {
      const request = KdjxPaymentRequest(
        gameOrderId: 'order-quote-2',
        productId: 'recharge.6',
        accountId: 'account-7',
        roleId: 'role-9',
        serverKey: 'game.cn.1',
        yyId: '0',
        csvId: '6',
        returnNonce: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      const preview = KdjxPayment(
        gameOrderId: 'order-quote-2',
        sakuraOrderId: 'sakura_order-quote-2',
        productId: 'recharge.6',
        productName: '60钻石',
        displayPrice: '6元',
        moneyCents: 600,
        coinCost: 60,
        balance: 300,
        status: 'preview',
        lastError: '',
        canRetry: false,
      );
      final service = serviceWith(
        client: MockClient((incoming) async {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'item': {
                  'gameOrderId': request.gameOrderId,
                  'sakuraOrderId': preview.sakuraOrderId,
                  'productId': request.productId,
                  'productName': '70钻石',
                  'displayPrice': '7元',
                  'moneyCents': 700,
                  'coinCost': 70,
                  'balance': 230,
                  'status': 'fulfilled',
                },
              }),
            ),
            200,
            request: incoming,
          );
        }),
      );

      await expectLater(
        service.pay(
          'app-token',
          request,
          idempotencyKey:
              'kdjx-pay-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          expectedPreview: preview,
        ),
        throwsA(
          isA<KdjxGameException>().having(
            (error) => error.message,
            'message',
            contains('报价已变化'),
          ),
        ),
      );
    },
  );

  test(
    'payment uses authoritative catalog price and exact identity fields',
    () async {
      const request = KdjxPaymentRequest(
        gameOrderId: 'order-1001',
        productId: 'recharge.6',
        accountId: 'account-7',
        roleId: 'role-9',
        serverKey: 'game.cn.1',
        yyId: '0',
        csvId: '6',
        returnNonce: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      http.Request? captured;
      final service = serviceWith(
        client: MockClient((incoming) async {
          captured = incoming;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'item': {
                  'gameOrderId': 'order-1001',
                  'sakuraOrderId': 'sakura_order-1001',
                  'productId': 'recharge.6',
                  'productName': '60钻石',
                  'displayPrice': '6元',
                  'moneyCents': 600,
                  'coinCost': 60,
                  'balance': 300,
                  'status': 'preview',
                },
              }),
            ),
            200,
            request: incoming,
          );
        }),
      );

      final preview = await service.previewPayment('app-token', request);

      expect(preview.displayPrice, '6元');
      expect(preview.coinCost, 60);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body, request.toJson());
      expect(body.containsKey('moneyCents'), isFalse);
      expect(body.containsKey('coinCost'), isFalse);
    },
  );

  test('rejects untrusted payment identifiers and price ratios', () async {
    expect(
      () => KdjxPaymentRequest.fromPlatform({
        'gameOrderId': '../order',
        'productId': 'recharge.6',
        'accountId': 'account-7',
        'roleId': 'role-9',
        'serverKey': 'game.cn.1',
        'yyId': '0',
        'csvId': '6',
        'returnNonce': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      }),
      throwsA(isA<KdjxGameException>()),
    );
    expect(
      () => KdjxPaymentRequest.fromPlatform({
        'gameOrderId': 'order-1002',
        'productId': 'recharge.6',
        'accountId': 'account-7',
        'roleId': 'role-9',
        'serverKey': 'game.cn.1',
        'yyId': '0',
        'csvId': '6',
      }),
      throwsA(isA<KdjxGameException>()),
    );
    expect(
      () => KdjxPaymentRequest.fromPlatform({
        'gameOrderId': 'order-1002',
        'productId': 'recharge.6',
        'accountId': 'account-7',
        'roleId': 'role-9',
        'serverKey': 'game.cn.1',
        'yyId': '0',
        'csvId': '6',
        'returnNonce': 'not-a-valid-return-nonce',
      }),
      throwsA(isA<KdjxGameException>()),
    );

    const request = KdjxPaymentRequest(
      gameOrderId: 'order-1002',
      productId: 'recharge.6',
      accountId: 'account-7',
      roleId: 'role-9',
      serverKey: 'game.cn.1',
      yyId: '0',
      csvId: '6',
      returnNonce: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    final service = serviceWith(
      client: MockClient((incoming) async {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'gameOrderId': 'order-1002',
              'sakuraOrderId': 'sakura_order-1002',
              'productId': 'recharge.6',
              'productName': 'bad price',
              'displayPrice': '6元',
              'moneyCents': 600,
              'coinCost': 6,
              'balance': 300,
              'status': 'preview',
            }),
          ),
          200,
          request: incoming,
        );
      }),
    );

    await expectLater(
      service.previewPayment('app-token', request),
      throwsA(
        isA<KdjxGameException>().having(
          (error) => error.message,
          'message',
          contains('价格'),
        ),
      ),
    );
  });

  test('native bridge is initialized before Flutter engine configuration', () {
    final source = File(
      'android/app/src/main/kotlin/com/novel/novel_app/MainActivity.kt',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      source,
      contains(
        'private val kdjxGameBridge by lazy(LazyThreadSafetyMode.NONE) {\n'
        '        KdjxGameBridge(this)\n'
        '    }',
      ),
    );
    expect(source, isNot(contains('lateinit var kdjxGameBridge')));
    expect(source, isNot(contains('kdjxGameBridge = KdjxGameBridge(this)')));
  });
}
