import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/kdjx_game_service.dart';
import 'package:novel_app/services/modao_parallel_downloader.dart';

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

  test(
    'uses the shared parallel range downloader and native finalize',
    () async {
      const channel = MethodChannel('test/kdjx-parts');
      final directory = Directory.systemTemp.createTempSync(
        'kdjx_parallel_adapter_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final payloads = [
        for (var index = 0; index < 5; index++)
          List<int>.filled(100, index + 1),
      ];
      final json = manifestJson();
      for (var index = 0; index < payloads.length; index++) {
        (json['parts'] as List)[index]['sha256'] = crypto.sha256
            .convert(payloads[index])
            .toString();
      }
      final manifest = KdjxGameManifest.fromJson(json);
      const releaseKey =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final finalPath = File(
        '${directory.path}${Platform.pathSeparator}${manifest.downloadFileName}',
      ).path;
      MethodCall? prepareCall;
      var prepared = false;
      var finalized = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'getDownloadState':
                if (!prepared) {
                  return {
                    'status': 'none',
                    'downloadedBytes': 0,
                    'totalBytes': 0,
                    'localPath': '',
                  };
                }
                return {
                  'status': finalized ? 'completed' : 'downloading',
                  'downloadedBytes': finalized ? manifest.sizeBytes : 0,
                  'totalBytes': manifest.sizeBytes,
                  'localPath': finalPath,
                  'sourceUrl': manifest.parts.first.url.toString(),
                  'sourceIndex': 0,
                  'segmented': true,
                  'partCount': manifest.parts.length,
                  'transport': 'app_http',
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                };
              case 'prepareAppDownload':
                prepareCall = call;
                prepared = true;
                return {
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                  'finalPath': finalPath,
                  'totalBytes': manifest.sizeBytes,
                  'transport': 'app_http',
                  'parts': [
                    for (final part in manifest.parts)
                      {
                        'index': part.index,
                        'path': File(
                          '${directory.path}${Platform.pathSeparator}'
                          'part-${part.index.toString().padLeft(3, '0')}',
                        ).path,
                        'sizeBytes': part.sizeBytes,
                        'sha256': part.sha256,
                      },
                  ],
                };
              case 'finalizeAppDownload':
                finalized = true;
                return {
                  'status': 'completed',
                  'downloadedBytes': manifest.sizeBytes,
                  'totalBytes': manifest.sizeBytes,
                  'localPath': finalPath,
                  'sourceUrl': manifest.parts.first.url.toString(),
                  'sourceIndex': 0,
                  'segmented': true,
                  'partCount': manifest.parts.length,
                  'retainedBytes': manifest.sizeBytes,
                  'transport': 'app_http',
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                };
              case 'cancelDownloadWork':
                return true;
              case 'clearDownload':
                prepared = false;
                finalized = false;
                return true;
            }
            fail('Unexpected platform call: ${call.method}');
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final ranges = <String>[];
      final service = serviceWith(
        channel: channel,
        client: MockClient((request) async {
          final match = RegExp(
            r'\.part-(\d{3})\.apk$',
          ).firstMatch(request.url.path);
          final index = int.parse(match!.group(1)!);
          expect(
            request.headers['User-Agent'],
            contains('Mozilla/5.0 (Linux; Android 14)'),
          );
          expect(request.headers['Accept-Encoding'], 'identity');
          ranges.add(request.headers['Range']!);
          return http.Response.bytes(
            payloads[index],
            206,
            headers: {
              'content-range': 'bytes 0-99/100',
              'content-length': '100',
            },
            request: request,
          );
        }),
      );

      final state = await service.startDownload(manifest, allowMetered: false);
      for (var attempt = 0; attempt < 100 && !finalized; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(state.status, KdjxDownloadStatus.downloading);
      expect(finalized, isTrue);
      expect(ranges, hasLength(5));
      expect(ranges.toSet(), {'bytes=0-99'});
      expect(prepareCall?.method, 'prepareAppDownload');
      final arguments = prepareCall?.arguments as Map;
      expect(arguments['url'], endsWith('kdjx-3-aaaaaaaaaaaa.apk'));
      expect(arguments['trustedDownloadHosts'], ['novel.kxhub.xyz']);
      expect(arguments['signingCertificateSha256'], signingSha);
      expect(arguments['sizeBytes'], manifest.sizeBytes);
      expect(arguments['sha256'], manifest.sha256);
      expect(arguments['parts'], hasLength(5));
      expect((arguments['parts'] as List).first, {
        'index': 0,
        'url':
            'https://novel.kxhub.xyz/games/kdjx/'
            'kdjx-3-aaaaaaaaaaaa.part-000.apk',
        'sizeBytes': 100,
        'sha256': manifest.parts.first.sha256,
      });
      expect(
        (await service.getDownloadState()).status,
        KdjxDownloadStatus.completed,
      );
      await service.clearDownload();
    },
  );

  test(
    'cancels native work before waiting for the parallel session to clear',
    () async {
      const channel = MethodChannel('test/kdjx-clear-order');
      final directory = Directory.systemTemp.createTempSync(
        'kdjx_clear_order_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final events = <String>[];
      final downloader = _BlockingParallelDownloader(events);
      final manifest = KdjxGameManifest.fromJson(manifestJson());
      const releaseKey =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      var prepared = false;
      final nativeCancelObserved = Completer<void>();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'getDownloadState':
                if (!prepared) return const {'status': 'none'};
                return {
                  'status': 'downloading',
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                };
              case 'prepareAppDownload':
                prepared = true;
                events.add('native:prepare');
                return {
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                  'finalPath': File(
                    '${directory.path}${Platform.pathSeparator}'
                    '${manifest.downloadFileName}',
                  ).path,
                  'totalBytes': manifest.sizeBytes,
                  'transport': 'app_http',
                  'parts': [
                    for (final part in manifest.parts)
                      {
                        'index': part.index,
                        'path': File(
                          '${directory.path}${Platform.pathSeparator}'
                          'part-${part.index.toString().padLeft(3, '0')}',
                        ).path,
                        'sizeBytes': part.sizeBytes,
                        'sha256': part.sha256,
                      },
                  ],
                };
              case 'cancelDownloadWork':
                events.add('native:cancel-work');
                if (!nativeCancelObserved.isCompleted) {
                  nativeCancelObserved.complete();
                }
                return true;
              case 'clearDownload':
                events.add('native:clear');
                return true;
            }
            fail('Unexpected platform call: ${call.method}');
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final service = KdjxGameService(
        platformChannel: channel,
        expectedSigningCertificateSha256: signingSha,
        parallelDownloader: downloader,
      );

      final start = service.startDownload(manifest, allowMetered: false);
      await downloader.startObserved.future;
      final clear = service.clearDownload();
      try {
        await nativeCancelObserved.future.timeout(const Duration(seconds: 1));
        expect(events, isNot(contains('native:clear')));
      } finally {
        downloader.releaseStart();
      }
      await start;
      await clear;

      expect(events, [
        'native:prepare',
        'parallel:start',
        'native:cancel-work',
        'parallel:cancel',
        'native:clear',
      ]);
    },
  );

  test(
    'pauses an unmetered download on cellular and resumes it on Wi-Fi',
    () async {
      const channel = MethodChannel('test/kdjx-network-policy');
      final manifest = KdjxGameManifest.fromJson(manifestJson());
      const releaseKey =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final downloader = _PolicyParallelDownloader();
      var prepared = false;
      var prepareCalls = 0;
      var metered = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'getDownloadState':
                if (!prepared) return const {'status': 'none'};
                return {
                  'status': 'downloading',
                  'downloadedBytes': 16,
                  'totalBytes': manifest.sizeBytes,
                  'localPath': r'C:\games\kdjx-3-aaaaaaaaaaaa.apk',
                  'reason': '',
                  'segmented': true,
                  'partCount': manifest.parts.length,
                  'retainedBytes': 16,
                  'transport': 'app_http',
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                };
              case 'prepareAppDownload':
                prepared = true;
                prepareCalls++;
                return {
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                  'finalPath': r'C:\games\kdjx-3-aaaaaaaaaaaa.apk',
                  'totalBytes': manifest.sizeBytes,
                  'transport': 'app_http',
                  'parts': [
                    for (final part in manifest.parts)
                      {
                        'index': part.index,
                        'path':
                            'C:\\games\\part-'
                            '${part.index.toString().padLeft(3, '0')}',
                        'sizeBytes': part.sizeBytes,
                        'sha256': part.sha256,
                      },
                  ],
                };
              case 'getDeviceEnvironment':
                return {
                  'freeBytes': 10 * 1024 * 1024 * 1024,
                  'networkType': metered ? 'cellular' : 'wifi',
                  'connected': true,
                  'validated': true,
                  'metered': metered,
                };
              case 'cancelDownloadWork':
                return true;
              case 'clearDownload':
                return true;
            }
            fail('Unexpected platform call: ${call.method}');
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final service = KdjxGameService(
        platformChannel: channel,
        expectedSigningCertificateSha256: signingSha,
        parallelDownloader: downloader,
        networkPolicyPollInterval: const Duration(milliseconds: 10),
      );

      await service.startDownload(manifest, allowMetered: false);
      expect(downloader.startCalls, 1);
      expect(prepareCalls, 1);

      metered = true;
      await _waitUntil(() => downloader.pauseCalls == 1);
      expect(downloader.current?.status, ModaoParallelDownloadStatus.paused);
      expect(downloader.current?.downloadedBytes, 16);

      metered = false;
      await _waitUntil(() => downloader.startCalls == 2);
      expect(
        downloader.current?.status,
        ModaoParallelDownloadStatus.downloading,
      );
      expect(downloader.current?.downloadedBytes, 16);
      expect(prepareCalls, 1);

      await service.clearDownload();
    },
  );

  test(
    'a paused unmetered download can be upgraded to allow mobile data',
    () async {
      const channel = MethodChannel('test/kdjx-network-upgrade');
      final manifest = KdjxGameManifest.fromJson(manifestJson());
      const releaseKey =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final downloader = _PolicyParallelDownloader();
      var prepared = false;
      var prepareCalls = 0;
      var metered = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'getDownloadState':
                if (!prepared) return const {'status': 'none'};
                return {
                  'status': 'downloading',
                  'downloadedBytes': 16,
                  'totalBytes': manifest.sizeBytes,
                  'localPath': r'C:\games\kdjx-3-aaaaaaaaaaaa.apk',
                  'reason': '',
                  'segmented': true,
                  'partCount': manifest.parts.length,
                  'retainedBytes': 16,
                  'transport': 'app_http',
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                };
              case 'prepareAppDownload':
                prepared = true;
                prepareCalls++;
                return {
                  'artifactKey': manifest.sha256,
                  'releaseKey': releaseKey,
                  'finalPath': r'C:\games\kdjx-3-aaaaaaaaaaaa.apk',
                  'totalBytes': manifest.sizeBytes,
                  'transport': 'app_http',
                  'parts': [
                    for (final part in manifest.parts)
                      {
                        'index': part.index,
                        'path':
                            'C:\\games\\part-'
                            '${part.index.toString().padLeft(3, '0')}',
                        'sizeBytes': part.sizeBytes,
                        'sha256': part.sha256,
                      },
                  ],
                };
              case 'getDeviceEnvironment':
                return {
                  'freeBytes': 10 * 1024 * 1024 * 1024,
                  'networkType': metered ? 'cellular' : 'wifi',
                  'connected': true,
                  'validated': true,
                  'metered': metered,
                };
              case 'cancelDownloadWork':
                return true;
              case 'clearDownload':
                return true;
            }
            fail('Unexpected platform call: ${call.method}');
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final service = KdjxGameService(
        platformChannel: channel,
        expectedSigningCertificateSha256: signingSha,
        parallelDownloader: downloader,
        networkPolicyPollInterval: const Duration(milliseconds: 10),
      );

      await service.startDownload(manifest, allowMetered: false);
      metered = true;
      await _waitUntil(() => downloader.pauseCalls == 1);

      final resumed = await service.startDownload(manifest, allowMetered: true);

      expect(resumed.status, KdjxDownloadStatus.downloading);
      expect(downloader.startCalls, 2);
      expect(downloader.current?.downloadedBytes, 16);
      expect(prepareCalls, 1);

      // Metered stays on; the upgraded download must not be paused again.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(downloader.pauseCalls, 1);
      expect(
        downloader.current?.status,
        ModaoParallelDownloadStatus.downloading,
      );

      await service.clearDownload();
    },
  );

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

  test('native merge commits completed state before deleting the parts', () {
    final source = _kdjxBridgeSource();

    // The assembling step must publish the APK without deleting parts.
    final assembleStart = source.indexOf('fun assemblePreparedDownload(');
    final assembleEnd = source.indexOf('fun preparedPartFile(');
    expect(assembleStart, greaterThanOrEqualTo(0));
    expect(assembleEnd, greaterThan(assembleStart));
    expect(
      source.substring(assembleStart, assembleEnd),
      isNot(contains('workDirectory.deleteRecursively()')),
    );

    // The worker persists "completed" with commit() first and only then
    // removes the parts, so a crash in between restores as completed.
    final committedIndex = source.indexOf(
      'persistDownloadStateCommittedLocked()',
    );
    final deletePartsIndex = source.indexOf(
      'prepared.workDirectory.deleteRecursively()',
    );
    expect(committedIndex, greaterThanOrEqualTo(0));
    expect(deletePartsIndex, greaterThan(committedIndex));
    expect(
      source,
      contains(
        'private fun persistDownloadStateCommittedLocked() {\n'
        '        if (!downloadStateEditorLocked().commit()) {',
      ),
    );
  });

  test('native restore verifies a crashed merge before trusting the APK', () {
    final source = _kdjxBridgeSource();

    final mergingRestoreIndex = source.indexOf(
      'if (downloadStatus == "merging") {',
    );
    expect(mergingRestoreIndex, greaterThanOrEqualTo(0));
    expect(source, contains('verifiedCompletedMergeFileLocked()'));

    final verifyStart = source.indexOf(
      'fun verifiedCompletedMergeFileLocked()',
    );
    final verifyEnd = source.indexOf('fun downloadStateEditorLocked()');
    expect(verifyStart, greaterThanOrEqualTo(0));
    expect(verifyEnd, greaterThan(verifyStart));
    final verifyBody = source.substring(verifyStart, verifyEnd);
    expect(verifyBody, contains('requireDownloadedApk(downloadPath)'));
    expect(verifyBody, contains('file.length() != totalBytes'));
    expect(verifyBody, contains('sha256Hex(file) != downloadArtifactKey'));

    // A failed verification must keep retained parts resumable.
    final mergingBlock = source.substring(
      mergingRestoreIndex,
      source.indexOf('if (downloadStatus in setOf(', mergingRestoreIndex),
    );
    expect(mergingBlock, contains('retainedPartBytesFromState()'));
    expect(mergingBlock, isNot(contains('deleteRecursively')));
  });

  test('native finalize is single-flight per download generation', () {
    final source = _kdjxBridgeSource();

    // The first finalize atomically takes merge ownership under the lock.
    final ownershipIndex = source.indexOf('activeMergeGeneration = generation');
    final workerIndex = source.indexOf('ioExecutor.execute {', ownershipIndex);
    expect(ownershipIndex, greaterThanOrEqualTo(0));
    expect(workerIndex, greaterThan(ownershipIndex));

    // A duplicate finalize for the running merge returns the merging state;
    // a different release is rejected.
    expect(
      source,
      contains('if (sameRelease && downloadStatus == "merging") {'),
    );
    expect(source, contains('"Another KDJX merge is already active"'));

    // The worker clears only the merge marker it owns.
    expect(
      source,
      contains(
        'finally {\n'
        '                synchronized(downloadLock) {\n'
        '                    if (activeMergeGeneration == generation) {\n'
        '                        activeMergeGeneration = null\n'
        '                    }\n'
        '                }\n'
        '            }',
      ),
    );

    // Cancel and clear interrupt the current generation's merge.
    for (final cancelSite in [
      'fun cancelDownloadWork()',
      'fun clearDownload()',
    ]) {
      final siteIndex = source.indexOf(cancelSite);
      expect(siteIndex, greaterThanOrEqualTo(0));
      final siteBlock = source.substring(siteIndex, siteIndex + 600);
      expect(siteBlock, contains('downloadGeneration += 1'));
      expect(siteBlock, contains('activeMergeGeneration = null'));
    }
  });
}

String _kdjxBridgeSource() => File(
  'android/app/src/main/kotlin/com/novel/novel_app/KdjxGameBridge.kt',
).readAsStringSync().replaceAll('\r\n', '\n');

class _PolicyParallelDownloader extends ModaoParallelDownloader {
  _PolicyParallelDownloader() : super(sessionNamespace: 'kdjx-policy-test');

  ModaoParallelDownloadSnapshot? current;
  int startCalls = 0;
  int pauseCalls = 0;

  @override
  ModaoParallelDownloadSnapshot? snapshot(
    String artifactKey, {
    required String releaseKey,
  }) => current?.artifactKey == artifactKey && current?.releaseKey == releaseKey
      ? current
      : null;

  @override
  Future<ModaoParallelDownloadSnapshot> start(
    ModaoParallelDownloadPlan plan, {
    Future<void> Function()? onPartsReady,
  }) async {
    startCalls++;
    current = ModaoParallelDownloadSnapshot(
      artifactKey: plan.artifactKey,
      releaseKey: plan.releaseKey,
      status: ModaoParallelDownloadStatus.downloading,
      downloadedBytes: current?.downloadedBytes ?? 16,
      totalBytes: plan.totalBytes,
      partCount: plan.parts.length,
    );
    return current!;
  }

  @override
  Future<void> pause(
    String artifactKey, {
    required String releaseKey,
    required String reason,
  }) async {
    pauseCalls++;
    final before = current!;
    current = ModaoParallelDownloadSnapshot(
      artifactKey: before.artifactKey,
      releaseKey: before.releaseKey,
      status: ModaoParallelDownloadStatus.paused,
      downloadedBytes: before.downloadedBytes,
      totalBytes: before.totalBytes,
      partCount: before.partCount,
      reason: reason,
    );
  }

  @override
  Future<void> cancel(String artifactKey, {required String releaseKey}) async {
    current = null;
  }

  @override
  Future<void> cancelAllExcept({
    required String artifactKey,
    required String releaseKey,
  }) async {}

  @override
  void forget(String artifactKey, {required String releaseKey}) {}
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for asynchronous state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _BlockingParallelDownloader extends ModaoParallelDownloader {
  _BlockingParallelDownloader(this.events)
    : super(sessionNamespace: 'kdjx-clear-order-test');

  final List<String> events;
  final Completer<void> startObserved = Completer<void>();
  final Completer<void> _release = Completer<void>();

  @override
  Future<ModaoParallelDownloadSnapshot> start(
    ModaoParallelDownloadPlan plan, {
    Future<void> Function()? onPartsReady,
  }) async {
    events.add('parallel:start');
    startObserved.complete();
    await _release.future;
    return ModaoParallelDownloadSnapshot(
      artifactKey: plan.artifactKey,
      releaseKey: plan.releaseKey,
      status: ModaoParallelDownloadStatus.downloading,
      downloadedBytes: 0,
      totalBytes: plan.totalBytes,
      partCount: plan.parts.length,
    );
  }

  @override
  Future<void> cancel(String artifactKey, {required String releaseKey}) async {
    events.add('parallel:cancel');
  }

  void releaseStart() {
    if (!_release.isCompleted) _release.complete();
  }
}
