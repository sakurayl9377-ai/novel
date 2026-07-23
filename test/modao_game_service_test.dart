import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/modao_game_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sha256 =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const signingSha256 = ModaoGameManifest.expectedSigningCertificateSha256;

  Map<String, dynamic> manifestJson({
    String packageName = ModaoGameManifest.expectedPackageName,
    String apkUrl = 'https://novel.kxhub.xyz/games/modao/modao-116.apk',
    int sizeBytes = 2147483648,
    String signingCertificateSha256 = signingSha256,
    Object? parts,
  }) {
    final result = <String, dynamic>{
      'packageName': packageName,
      'versionName': '1.1.6',
      'versionCode': 116,
      'apkUrl': apkUrl,
      'sizeBytes': sizeBytes,
      'sha256': sha256,
      'signingCertificateSha256': signingCertificateSha256,
      'notes': ['release'],
    };
    if (parts != null) result['parts'] = parts;
    return result;
  }

  List<Map<String, dynamic>> partsJson({
    int count = 5,
    int totalBytes = 2147483648,
  }) => List.generate(count, (index) {
    final start = (totalBytes * index) ~/ count;
    final end = (totalBytes * (index + 1)) ~/ count;
    return {
      'index': index,
      'url':
          'https://novel.kxhub.xyz/games/modao/modao-116-aaaaaaaaaaaa.part-${index.toString().padLeft(3, '0')}.apk',
      'sizeBytes': end - start,
      'sha256': '${index + 1}' * 64,
    };
  });

  test('uses a dedicated HTTPS manifest and accepts a 2 GiB APK', () async {
    final manifestUri = Uri.parse(ModaoGameService.manifestUrl);
    expect(manifestUri.scheme, 'https');
    expect(manifestUri.host, 'novel.kxhub.xyz');
    expect(manifestUri.path, '/games/modao/manifest.json');

    http.Request? capturedRequest;
    final service = ModaoGameService(
      httpClient: MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode(manifestJson()), 200, request: request);
      }),
    );

    final manifest = await service.fetchManifest();

    expect(capturedRequest?.url.path, '/games/modao/manifest.json');
    expect(capturedRequest?.url.queryParameters['cacheBust'], isNotEmpty);
    expect(capturedRequest?.headers['Cache-Control'], 'no-cache, no-store');
    expect(capturedRequest?.followRedirects, isFalse);
    expect(manifest.packageName, ModaoGameManifest.expectedPackageName);
    expect(manifest.sizeBytes, 2147483648);
    expect(manifest.downloadFileName, 'modao-116-aaaaaaaaaaaa.apk');
  });

  test('rejects an untrusted APK host and unexpected package name', () async {
    var response = manifestJson(
      apkUrl: 'https://downloads.example.com/games/modao/game.apk',
    );
    final service = ModaoGameService(
      httpClient: MockClient((request) async {
        return http.Response(jsonEncode(response), 200, request: request);
      }),
    );

    await expectLater(
      service.fetchManifest(),
      throwsA(isA<ModaoGameException>()),
    );

    response = manifestJson(packageName: 'com.example.fake');
    await expectLater(
      service.fetchManifest(),
      throwsA(isA<ModaoGameException>()),
    );
  });

  test('rejects an unapproved certificate declared by the manifest', () async {
    final service = ModaoGameService(
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode(
            manifestJson(
              signingCertificateSha256:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ),
          ),
          200,
          request: request,
        );
      }),
    );

    await expectLater(
      service.fetchManifest(),
      throwsA(isA<ModaoGameException>()),
    );
  });

  test(
    'accepts 5 trusted static parts whose Long sizes cover the APK',
    () async {
      final service = ModaoGameService(
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode(manifestJson(parts: partsJson())),
            200,
            request: request,
          );
        }),
      );

      final manifest = await service.fetchManifest();

      expect(manifest.parts, hasLength(5));
      expect(
        manifest.parts.fold<int>(0, (total, part) => total + part.sizeBytes),
        2147483648,
      );
      expect(manifest.parts.last.index, 4);
      expect(manifest.parts.last.fileName, endsWith('.part-004.apk'));
    },
  );

  test('rejects malformed, misordered, or incomplete static parts', () async {
    var parts = partsJson();
    parts[1]['index'] = 7;
    var response = manifestJson(parts: parts);
    final service = ModaoGameService(
      httpClient: MockClient((request) async {
        return http.Response(jsonEncode(response), 200, request: request);
      }),
    );

    await expectLater(
      service.fetchManifest(),
      throwsA(isA<ModaoGameException>()),
    );

    parts = partsJson();
    parts[0]['sizeBytes'] = (parts[0]['sizeBytes'] as int) - 1;
    response = manifestJson(parts: parts);
    await expectLater(
      service.fetchManifest(),
      throwsA(isA<ModaoGameException>()),
    );

    response = manifestJson(parts: ['not-a-part']);
    await expectLater(
      service.fetchManifest(),
      throwsA(isA<ModaoGameException>()),
    );
  });

  test(
    'passes static parts and 2 GiB size to Android without narrowing',
    () async {
      const channel = MethodChannel('test/modao-download-parts');
      MethodCall? startCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            startCall = call;
            return {
              'status': 'queued',
              'downloadedBytes': 0,
              'totalBytes': 2147483648,
              'localPath': r'C:\games\modao.apk',
              'reason': '',
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final service = ModaoGameService(platformChannel: channel);
      final manifest = ModaoGameManifest.fromJson(
        manifestJson(parts: partsJson()),
      );

      final state = await service.startDownload(manifest, allowMetered: true);

      expect(state.totalBytes, 2147483648);
      expect(startCall?.method, 'startDownload');
      final arguments = startCall!.arguments as Map;
      expect(arguments['sizeBytes'], 2147483648);
      expect(arguments['sha256'], sha256);
      expect(arguments['allowMetered'], isTrue);
      final sentParts = arguments['parts'] as List;
      expect(sentParts, hasLength(5));
      expect((sentParts.last as Map)['sizeBytes'], greaterThan(400000000));
    },
  );

  test('parses segmented task metadata returned by Android', () {
    final state = ModaoDownloadState.fromPlatform({
      'status': 'downloading',
      'downloadedBytes': 3000000000,
      'totalBytes': 4000000000,
      'localPath': r'C:\games\modao.apk',
      'reason': '',
      'segmented': true,
      'partCount': 5,
      'retainedBytes': 1600000000,
    });

    expect(state.segmented, isTrue);
    expect(state.partCount, 5);
    expect(state.downloadedBytes, 3000000000);
    expect(state.totalBytes, 4000000000);
    expect(state.retainedBytes, 1600000000);
  });

  test('normalizes and checks the installed signing certificate', () async {
    const channel = MethodChannel('test/modao-installed');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getInstalledGame');
          return {
            'installed': true,
            'packageName': ModaoGameManifest.expectedPackageName,
            'versionName': '1.1.6',
            'versionCode': 116,
            'signingCertificateSha256s': [
              signingSha256.toUpperCase().replaceAllMapped(
                RegExp(r'..(?!$)'),
                (match) => '${match.group(0)}:',
              ),
            ],
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final service = ModaoGameService(platformChannel: channel);
    final manifest = ModaoGameManifest.fromJson(manifestJson());

    final installed = await service.getInstalledGame();

    expect(installed.isTrustedFor(manifest), isTrue);
    expect(installed.isCurrentFor(manifest), isTrue);
  });

  test('verifies size, digest, package, version, and APK signer', () async {
    const channel = MethodChannel('test/modao-inspect');
    var returnedSignature = signingSha256;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'inspectApk');
          expect((call.arguments as Map)['path'], r'C:\games\modao.apk');
          return {
            'exists': true,
            'sizeBytes': 2147483648,
            'sha256': sha256,
            'packageName': ModaoGameManifest.expectedPackageName,
            'versionCode': 116,
            'signingCertificateSha256s': [returnedSignature],
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final service = ModaoGameService(platformChannel: channel);
    final manifest = ModaoGameManifest.fromJson(manifestJson());

    await service.verifyDownloadedApk(manifest, r'C:\games\modao.apk');

    returnedSignature = sha256;
    await expectLater(
      service.verifyDownloadedApk(manifest, r'C:\games\modao.apk'),
      throwsA(
        isA<ModaoGameException>().having(
          (error) => error.message,
          'message',
          contains('签名'),
        ),
      ),
    );
  });

  test(
    'passes only the one-time ticket and trusted bridge URL to Android',
    () async {
      const channel = MethodChannel('test/modao-launch');
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
      final service = ModaoGameService(
        platformChannel: channel,
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/novel-api/games/modao/sso-ticket');
          expect(request.headers['Authorization'], 'Bearer app-access-token');
          return http.Response(
            jsonEncode({
              'ticket': 'one-time-ticket',
              'launchUrl': 'https://49.232.137.85/sakura/sso/exchange',
            }),
            200,
            request: request,
          );
        }),
      );

      final ticket = await service.createSsoTicket('app-access-token');
      await service.launchGame(ticket);

      expect(launchCall?.method, 'launchGame');
      final arguments = launchCall?.arguments as Map;
      expect(arguments['ticket'], 'one-time-ticket');
      expect(
        arguments['exchangeUrl'],
        'https://49.232.137.85/sakura/sso/exchange',
      );
      expect(arguments['allowedSsoHost'], '49.232.137.85');
      expect(arguments.values, isNot(contains('app-access-token')));
    },
  );

  test('rejects an SSO bridge URL outside the pinned host', () async {
    final service = ModaoGameService(
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'ticket': 'one-time-ticket',
            'launchUrl': 'https://game.example.com/sakura/sso/exchange',
          }),
          200,
          request: request,
        );
      }),
    );

    await expectLater(
      service.createSsoTicket('app-access-token'),
      throwsA(
        isA<ModaoGameException>().having(
          (error) => error.message,
          'message',
          contains('登录地址'),
        ),
      ),
    );
  });

  test(
    'requires the ticket issuer to provide the HTTPS bridge launch URL',
    () async {
      final service = ModaoGameService(
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({'ticket': 'one-time-ticket'}),
            200,
            request: request,
          );
        }),
      );

      await expectLater(
        service.createSsoTicket('app-access-token'),
        throwsA(
          isA<ModaoGameException>().having(
            (error) => error.message,
            'message',
            contains('登录地址'),
          ),
        ),
      );
    },
  );

  test(
    'payment preview trusts only the server catalog price at 10:1',
    () async {
      final request = ModaoPaymentRequest.fromPlatform({
        'gameOrderId': 'order-1001',
        'productId': 'pack.6',
        'moneyCents': 1,
      });
      http.Request? capturedRequest;
      final service = ModaoGameService(
        httpClient: MockClient((incoming) async {
          capturedRequest = incoming;
          return http.Response(
            jsonEncode({
              'item': {
                'gameOrderId': 'order-1001',
                'productId': 'pack.6',
                'productName': '6 yuan pack',
                'moneyCents': 600,
                'sakuraCoinAmount': 60,
                'balance': 200,
                'status': 'preview',
              },
            }),
            200,
            request: incoming,
          );
        }),
      );

      final preview = await service.previewPayment('app-token', request);

      expect(preview.moneyCents, 600);
      expect(preview.coinCost, 60);
      expect(
        capturedRequest?.url.path,
        '/novel-api/games/modao/payments/preview',
      );
      expect(capturedRequest?.headers['Authorization'], 'Bearer app-token');
      final sentBody =
          jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(sentBody, {'gameOrderId': 'order-1001', 'productId': 'pack.6'});
      expect(sentBody.containsKey('moneyCents'), isFalse);
      expect(sentBody.containsKey('coinCost'), isFalse);
    },
  );

  test(
    'payment rejects a server response that violates the 10:1 ratio',
    () async {
      const request = ModaoPaymentRequest(
        gameOrderId: 'order-1002',
        productId: 'pack.6',
      );
      final service = ModaoGameService(
        httpClient: MockClient((incoming) async {
          return http.Response(
            jsonEncode({
              'gameOrderId': 'order-1002',
              'productId': 'pack.6',
              'productName': 'invalid pack',
              'moneyCents': 600,
              'coinCost': 6,
              'balance': 100,
              'status': 'preview',
            }),
            200,
            request: incoming,
          );
        }),
      );

      await expectLater(
        service.previewPayment('app-token', request),
        throwsA(
          isA<ModaoGameException>().having(
            (error) => error.message,
            'message',
            contains('价格校验'),
          ),
        ),
      );
    },
  );

  test(
    'payment submit sends an idempotency key and no client amount',
    () async {
      const request = ModaoPaymentRequest(
        gameOrderId: 'order-1003',
        productId: 'pack.30',
      );
      http.Request? capturedRequest;
      final service = ModaoGameService(
        httpClient: MockClient((incoming) async {
          capturedRequest = incoming;
          return http.Response(
            jsonEncode({
              'gameOrderId': 'order-1003',
              'productId': 'pack.30',
              'productName': '30 yuan pack',
              'moneyCents': 3000,
              'coinCost': 300,
              'balance': 700,
              'status': 'fulfilled',
            }),
            200,
            request: incoming,
          );
        }),
      );

      final payment = await service.pay(
        'app-token',
        request,
        idempotencyKey: '12345678-1234-1234-1234-123456789012',
      );

      expect(payment.delivered, isTrue);
      expect(
        capturedRequest?.headers['Idempotency-Key'],
        '12345678-1234-1234-1234-123456789012',
      );
      final body = jsonDecode(capturedRequest!.body) as Map<String, dynamic>;
      expect(body['gameOrderId'], 'order-1003');
      expect(body['productId'], 'pack.30');
      expect(body.containsKey('moneyCents'), isFalse);
      expect(body.containsKey('coinCost'), isFalse);
    },
  );

  test('payment deep-link identifiers use a strict allowlist', () {
    expect(
      () => ModaoPaymentRequest.fromPlatform({
        'gameOrderId': '../order',
        'productId': 'pack.6',
      }),
      throwsA(isA<ModaoGameException>()),
    );
    expect(
      () => ModaoPaymentRequest.fromPlatform({
        'gameOrderId': 'order-1004',
        'productId': 'pack.6',
        'moneyCents': '999999999',
      }),
      returnsNormally,
    );
  });
}
