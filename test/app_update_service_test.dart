import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/app_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PackageInfo.setMockInitialValues(
    appName: 'Sakura',
    packageName: 'com.novel.novel_app',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  test('uses the dedicated HTTPS download host for update metadata', () {
    final uri = Uri.parse(AppUpdateService.updateJsonUrl);

    expect(uri.scheme, 'https');
    expect(uri.host, 'novel.kxhub.xyz');
    expect(uri.path, '/app3/version.json');
  });

  test('downloadApk reuses a full response to the range probe', () async {
    final testDir = Directory.systemTemp.createTempSync('app_update_test_');
    addTearDown(() {
      if (testDir.existsSync()) {
        testDir.deleteSync(recursive: true);
      }
    });
    final apkBytes = utf8.encode('fake apk payload');
    final sha256 = crypto.sha256.convert(apkBytes).toString();
    final update = AppUpdateInfo(
      versionName: '2.0.2',
      versionCode: 4,
      apkUrl: 'https://novel.kxhub.xyz/app3/test.apk',
      sha256: sha256,
      notes: const [],
    );

    var requestCount = 0;
    final service = AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      httpClient: MockClient((request) async {
        requestCount++;
        expect(request.headers['Range'], 'bytes=0-0');
        expect(request.headers['Accept-Encoding'], 'identity');
        return http.Response.bytes(
          apkBytes,
          200,
          request: request,
          headers: {'content-length': apkBytes.length.toString()},
        );
      }),
    );

    final first = await service.downloadApk(update);
    expect(requestCount, 1);
    expect(await first.readAsBytes(), apkBytes);

    final cachedService = AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      httpClient: MockClient((request) async {
        fail('cached APK should be used without a network request');
      }),
    );
    final second = await cachedService.downloadApk(update);

    expect(second.path, first.path);
    expect(await second.readAsBytes(), apkBytes);
    expect(testDir.existsSync(), isTrue);
  });

  test('downloads a large APK with four concurrent verified ranges', () async {
    final testDir = Directory.systemTemp.createTempSync('app_update_parts_');
    addTearDown(() {
      if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    });
    final apkBytes = List<int>.generate(160, (index) => index % 251);
    final sha256 = crypto.sha256.convert(apkBytes).toString();
    final update = AppUpdateInfo(
      versionName: '10.0.0',
      versionCode: 10,
      apkUrl: 'https://novel.kxhub.xyz/app3/app-release-10.0.0+10.apk',
      sha256: sha256,
      notes: const [],
    );
    final requestedRanges = <String>[];
    final progress = <(int, int)>[];
    var activeParts = 0;
    var maximumActiveParts = 0;
    final service = AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      parallelDownloadParts: 4,
      parallelDownloadThresholdBytes: 32,
      minimumParallelPartBytes: 1,
      httpClient: MockClient((request) async {
        final range = request.headers['Range'];
        expect(request.headers['Accept-Encoding'], 'identity');
        expect(request.followRedirects, isFalse);
        if (range == 'bytes=0-0') {
          return _rangeResponse(apkBytes, request);
        }
        requestedRanges.add(range!);
        activeParts += 1;
        if (activeParts > maximumActiveParts) {
          maximumActiveParts = activeParts;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        activeParts -= 1;
        return _rangeResponse(apkBytes, request);
      }),
    );

    final apk = await service.downloadApk(
      update,
      onProgress: (received, total) => progress.add((received, total)),
    );

    expect(await apk.readAsBytes(), apkBytes);
    expect(maximumActiveParts, 4);
    expect(requestedRanges.toSet(), {
      'bytes=0-39',
      'bytes=40-79',
      'bytes=80-119',
      'bytes=120-159',
    });
    expect(progress, isNotEmpty);
    expect(progress.last, (apkBytes.length, apkBytes.length));
    for (var index = 1; index < progress.length; index++) {
      expect(progress[index].$1, greaterThanOrEqualTo(progress[index - 1].$1));
      expect(progress[index].$1, lessThanOrEqualTo(progress[index].$2));
    }
    expect(
      testDir.listSync().where(
        (entity) => entity.path.contains('.download.part-'),
      ),
      isEmpty,
    );
  });

  test('resumes an existing range part from its exact byte offset', () async {
    final testDir = Directory.systemTemp.createTempSync('app_update_resume_');
    addTearDown(() {
      if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    });
    final apkBytes = List<int>.generate(100, (index) => (index * 3) % 251);
    final sha256 = crypto.sha256.convert(apkBytes).toString();
    final part = File(
      '${testDir.path}/sakura-11-${sha256.substring(0, 12)}.apk'
      '.download.part-0-24',
    );
    await part.writeAsBytes(apkBytes.sublist(0, 10));
    final update = AppUpdateInfo(
      versionName: '11.0.0',
      versionCode: 11,
      apkUrl: 'https://novel.kxhub.xyz/app3/app-release-11.0.0+11.apk',
      sha256: sha256,
      notes: const [],
    );
    final requestedRanges = <String>[];
    final service = AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      parallelDownloadThresholdBytes: 1,
      minimumParallelPartBytes: 1,
      httpClient: MockClient((request) async {
        final range = request.headers['Range']!;
        if (range != 'bytes=0-0') requestedRanges.add(range);
        return _rangeResponse(apkBytes, request);
      }),
    );

    final apk = await service.downloadApk(update);

    expect(await apk.readAsBytes(), apkBytes);
    expect(requestedRanges, contains('bytes=10-24'));
    expect(requestedRanges, isNot(contains('bytes=0-24')));
  });

  test(
    'falls back to one full response when later ranges are ignored',
    () async {
      final testDir = Directory.systemTemp.createTempSync(
        'app_update_fallback_',
      );
      addTearDown(() {
        if (testDir.existsSync()) testDir.deleteSync(recursive: true);
      });
      final apkBytes = List<int>.generate(96, (index) => index % 251);
      final sha256 = crypto.sha256.convert(apkBytes).toString();
      final update = AppUpdateInfo(
        versionName: '12.0.0',
        versionCode: 12,
        apkUrl: 'https://novel.kxhub.xyz/app3/app-release-12.0.0+12.apk',
        sha256: sha256,
        notes: const [],
      );
      var fullRequests = 0;
      var ignoredRangeRequests = 0;
      final service = AppUpdateService(
        temporaryDirectoryProvider: () async => testDir,
        parallelDownloadThresholdBytes: 1,
        minimumParallelPartBytes: 1,
        httpClient: MockClient((request) async {
          final range = request.headers['Range'];
          if (range == 'bytes=0-0') return _rangeResponse(apkBytes, request);
          if (range != null) {
            ignoredRangeRequests += 1;
          } else {
            fullRequests += 1;
          }
          return http.Response.bytes(
            apkBytes,
            200,
            request: request,
            headers: {'content-length': '${apkBytes.length}'},
          );
        }),
      );

      final apk = await service.downloadApk(update);

      expect(await apk.readAsBytes(), apkBytes);
      expect(ignoredRangeRequests, greaterThan(0));
      expect(fullRequests, 1);
      expect(
        testDir.listSync().where(
          (entity) => entity.path.contains('.download.part-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'keeps range unsupported as the primary failure after peer cancellation',
    () async {
      final testDir = Directory.systemTemp.createTempSync(
        'app_update_primary_failure_',
      );
      addTearDown(() {
        if (testDir.existsSync()) testDir.deleteSync(recursive: true);
      });
      final apkBytes = List<int>.generate(80, (index) => index % 251);
      final sha256 = crypto.sha256.convert(apkBytes).toString();
      final update = AppUpdateInfo(
        versionName: '12.1.0',
        versionCode: 121,
        apkUrl: 'https://novel.kxhub.xyz/app3/app-release-12.1.0+121.apk',
        sha256: sha256,
        notes: const [],
      );
      final stalledPartStarted = Completer<void>();
      final stalledPartController = StreamController<List<int>>(
        onListen: stalledPartStarted.complete,
      );
      addTearDown(() async {
        if (!stalledPartController.isClosed) {
          await stalledPartController.close();
        }
      });
      var fullRequests = 0;
      final service = AppUpdateService(
        temporaryDirectoryProvider: () async => testDir,
        parallelDownloadThresholdBytes: 1,
        minimumParallelPartBytes: 1,
        httpClient: MockClient.streaming((request, _) async {
          final range = request.headers['Range'];
          if (range == 'bytes=0-0') {
            return _streamedRangeResponse(apkBytes, request);
          }
          if (range == 'bytes=0-19') {
            final abortTrigger =
                (request as http.AbortableRequest).abortTrigger!;
            unawaited(
              abortTrigger.then((_) async {
                if (!stalledPartController.isClosed) {
                  await stalledPartController.close();
                }
              }),
            );
            return http.StreamedResponse(
              stalledPartController.stream,
              206,
              contentLength: 20,
              headers: {
                'content-range': 'bytes 0-19/${apkBytes.length}',
                'content-length': '20',
                'content-encoding': 'identity',
              },
              request: request,
            );
          }
          if (range == 'bytes=20-39') {
            await stalledPartStarted.future;
            return http.StreamedResponse(
              Stream<List<int>>.value(apkBytes),
              200,
              contentLength: apkBytes.length,
              headers: {'content-length': '${apkBytes.length}'},
              request: request,
            );
          }
          if (range == null) {
            fullRequests += 1;
            return http.StreamedResponse(
              Stream<List<int>>.value(apkBytes),
              200,
              contentLength: apkBytes.length,
              headers: {'content-length': '${apkBytes.length}'},
              request: request,
            );
          }
          return _streamedRangeResponse(apkBytes, request);
        }),
      );

      final apk = await service.downloadApk(update);

      expect(await apk.readAsBytes(), apkBytes);
      expect(fullRequests, 1);
      expect(
        testDir.listSync().where(
          (entity) => entity.path.contains('.download.part-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'aborts and settles a timed out range request before retrying',
    () async {
      final testDir = Directory.systemTemp.createTempSync(
        'app_update_header_timeout_',
      );
      addTearDown(() {
        if (testDir.existsSync()) testDir.deleteSync(recursive: true);
      });
      final apkBytes = List<int>.generate(80, (index) => index % 251);
      final sha256 = crypto.sha256.convert(apkBytes).toString();
      final update = AppUpdateInfo(
        versionName: '12.2.0',
        versionCode: 122,
        apkUrl: 'https://novel.kxhub.xyz/app3/app-release-12.2.0+122.apk',
        sha256: sha256,
        notes: const [],
      );
      final firstAttemptAborted = Completer<void>();
      var firstPartAttempts = 0;
      var retryStartedAfterAbort = false;
      final service = AppUpdateService(
        temporaryDirectoryProvider: () async => testDir,
        parallelDownloadThresholdBytes: 1,
        minimumParallelPartBytes: 1,
        requestHeaderTimeout: const Duration(milliseconds: 10),
        requestAbortSettleTimeout: const Duration(seconds: 1),
        httpClient: MockClient.streaming((request, _) async {
          final range = request.headers['Range'];
          if (range == 'bytes=0-0') {
            return _streamedRangeResponse(apkBytes, request);
          }
          if (range == 'bytes=0-19') {
            firstPartAttempts += 1;
            if (firstPartAttempts == 1) {
              final abortTrigger =
                  (request as http.AbortableRequest).abortTrigger!;
              await abortTrigger;
              firstAttemptAborted.complete();
              throw http.RequestAbortedException(request.url);
            }
            retryStartedAfterAbort = firstAttemptAborted.isCompleted;
          }
          return _streamedRangeResponse(apkBytes, request);
        }),
      );

      final apk = await service.downloadApk(update);

      expect(await apk.readAsBytes(), apkBytes);
      expect(firstPartAttempts, 2);
      expect(firstAttemptAborted.isCompleted, isTrue);
      expect(retryStartedAfterAbort, isTrue);
    },
  );

  test(
    'joins concurrent service instances into one network download',
    () async {
      final testDir = Directory.systemTemp.createTempSync('app_update_join_');
      addTearDown(() {
        if (testDir.existsSync()) testDir.deleteSync(recursive: true);
      });
      final apkBytes = List<int>.generate(80, (index) => index % 251);
      final sha256 = crypto.sha256.convert(apkBytes).toString();
      final update = AppUpdateInfo(
        versionName: '13.0.0',
        versionCode: 13,
        apkUrl: 'https://novel.kxhub.xyz/app3/app-release-13.0.0+13.apk',
        sha256: sha256,
        notes: const [],
      );
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount += 1;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _rangeResponse(apkBytes, request);
      });
      AppUpdateService createService() => AppUpdateService(
        temporaryDirectoryProvider: () async => testDir,
        parallelDownloadThresholdBytes: 1,
        minimumParallelPartBytes: 1,
        httpClient: client,
      );
      final firstProgress = <(int, int)>[];
      final secondProgress = <(int, int)>[];

      final results = await Future.wait([
        createService().downloadApk(
          update,
          onProgress: (received, total) => firstProgress.add((received, total)),
        ),
        createService().downloadApk(
          update,
          onProgress: (received, total) =>
              secondProgress.add((received, total)),
        ),
      ]);

      expect(requestCount, 5);
      expect(results[0].path, results[1].path);
      expect(firstProgress.last, (apkBytes.length, apkBytes.length));
      expect(secondProgress.last, (apkBytes.length, apkBytes.length));
    },
  );

  test('throttles progress callbacks for very small network chunks', () async {
    final testDir = Directory.systemTemp.createTempSync('app_update_progress_');
    addTearDown(() {
      if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    });
    final apkBytes = List<int>.generate(10000, (index) => index % 251);
    final sha256 = crypto.sha256.convert(apkBytes).toString();
    final update = AppUpdateInfo(
      versionName: '14.0.0',
      versionCode: 14,
      apkUrl: 'https://novel.kxhub.xyz/app3/app-release-14.0.0+14.apk',
      sha256: sha256,
      notes: const [],
    );
    final callbacks = <(int, int)>[];
    final service = AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      httpClient: MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            for (final byte in apkBytes) [byte],
          ]),
          200,
          contentLength: apkBytes.length,
          headers: {'content-length': '${apkBytes.length}'},
          request: request,
        );
      }),
    );

    await service.downloadApk(
      update,
      onProgress: (received, total) => callbacks.add((received, total)),
    );

    expect(callbacks.length, lessThan(100));
    expect(callbacks.last, (apkBytes.length, apkBytes.length));
  });

  test('retries a short range from the last persisted byte', () async {
    final testDir = Directory.systemTemp.createTempSync('app_update_retry_');
    addTearDown(() {
      if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    });
    final apkBytes = List<int>.generate(80, (index) => index % 251);
    final sha256 = crypto.sha256.convert(apkBytes).toString();
    final update = AppUpdateInfo(
      versionName: '15.0.0',
      versionCode: 15,
      apkUrl: 'https://novel.kxhub.xyz/app3/app-release-15.0.0+15.apk',
      sha256: sha256,
      notes: const [],
    );
    final requestedRanges = <String>[];
    var shortened = false;
    final service = AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      parallelDownloadThresholdBytes: 1,
      minimumParallelPartBytes: 1,
      httpClient: MockClient.streaming((request, _) async {
        final range = request.headers['Range']!;
        requestedRanges.add(range);
        if (range == 'bytes=0-19' && !shortened) {
          shortened = true;
          return _streamedRangeResponse(apkBytes, request, returnedBodyEnd: 9);
        }
        return _streamedRangeResponse(apkBytes, request);
      }),
    );

    final apk = await service.downloadApk(update);

    expect(await apk.readAsBytes(), apkBytes);
    expect(requestedRanges, containsAllInOrder(['bytes=0-19', 'bytes=10-19']));
  });

  test('rejects a wrong range total and resumes safe parts later', () async {
    final testDir = Directory.systemTemp.createTempSync(
      'app_update_bad_range_',
    );
    addTearDown(() {
      if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    });
    final apkBytes = List<int>.generate(96, (index) => index % 251);
    final sha256 = crypto.sha256.convert(apkBytes).toString();
    final update = AppUpdateInfo(
      versionName: '16.0.0',
      versionCode: 16,
      apkUrl: 'https://novel.kxhub.xyz/app3/app-release-16.0.0+16.apk',
      sha256: sha256,
      notes: const [],
    );
    var returnWrongTotal = true;
    var correctedFirstPartRequests = 0;
    final client = MockClient((request) async {
      final range = request.headers['Range']!;
      if (range == 'bytes=0-23' && returnWrongTotal) {
        final response = _rangeResponse(apkBytes, request);
        return http.Response.bytes(
          response.bodyBytes,
          206,
          request: request,
          headers: {
            ...response.headers,
            'content-range': 'bytes 0-23/${apkBytes.length + 1}',
          },
        );
      }
      if (range == 'bytes=0-23') correctedFirstPartRequests += 1;
      return _rangeResponse(apkBytes, request);
    });
    AppUpdateService createService() => AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      parallelDownloadThresholdBytes: 1,
      minimumParallelPartBytes: 1,
      httpClient: client,
    );

    await expectLater(
      createService().downloadApk(update),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('range response is invalid'),
        ),
      ),
    );
    returnWrongTotal = false;
    final apk = await createService().downloadApk(update);

    expect(await apk.readAsBytes(), apkBytes);
    expect(correctedFirstPartRequests, 1);
  });

  test('removes every range part after a merged checksum mismatch', () async {
    final testDir = Directory.systemTemp.createTempSync('app_update_bad_sha_');
    addTearDown(() {
      if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    });
    final expectedBytes = List<int>.generate(64, (index) => index % 251);
    final servedBytes = List<int>.of(expectedBytes)..[40] ^= 0xff;
    final sha256 = crypto.sha256.convert(expectedBytes).toString();
    final update = AppUpdateInfo(
      versionName: '17.0.0',
      versionCode: 17,
      apkUrl: 'https://novel.kxhub.xyz/app3/app-release-17.0.0+17.apk',
      sha256: sha256,
      notes: const [],
    );
    final service = AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      parallelDownloadThresholdBytes: 1,
      minimumParallelPartBytes: 1,
      httpClient: MockClient(
        (request) async => _rangeResponse(servedBytes, request),
      ),
    );

    await expectLater(
      service.downloadApk(update),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('checksum mismatch'),
        ),
      ),
    );

    expect(
      testDir.listSync().where(
        (entity) =>
            entity.path.contains('.download.part-') ||
            entity.path.endsWith('.merge'),
      ),
      isEmpty,
    );
  });

  test('coalesces duplicate install requests for the same APK', () async {
    const channel = MethodChannel('com.novel.novel_app/app_update');
    final installStarted = Completer<void>();
    final releaseInstall = Completer<void>();
    var installCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          installCalls += 1;
          installStarted.complete();
          await releaseInstall.future;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final apk = File(
      '${Directory.systemTemp.path}/app-update-install-${DateTime.now().microsecondsSinceEpoch}.apk',
    );
    await apk.writeAsBytes([1]);
    addTearDown(() async {
      if (await apk.exists()) await apk.delete();
    });
    final first = AppUpdateService().installApk(apk);
    await installStarted.future;
    final second = AppUpdateService().installApk(apk);
    releaseInstall.complete();

    await Future.wait([first, second]);

    expect(installCalls, 1);
  });

  test('rejects an insecure APK URL from update metadata', () async {
    final service = AppUpdateService(
      httpClient: MockClient((request) async {
        expect(request.url.toString(), AppUpdateService.updateJsonUrl);
        return http.Response(
          jsonEncode({
            'versionName': '2.0.0',
            'versionCode': 2,
            'apkUrl': 'http://downloads.example.com/app.apk',
            'sha256': List.filled(64, '0').join(),
          }),
          200,
          request: request,
        );
      }),
    );

    await expectLater(
      service.checkForUpdate(),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Invalid update config'),
        ),
      ),
    );
  });

  test('rejects an APK URL on an untrusted HTTPS host', () async {
    final service = AppUpdateService(
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'versionName': '2.0.0',
            'versionCode': 2,
            'apkUrl': 'https://downloads.example.com/app.apk',
            'sha256': List.filled(64, '0').join(),
          }),
          200,
          request: request,
        );
      }),
    );

    await expectLater(
      service.checkForUpdate(),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Invalid update config'),
        ),
      ),
    );
  });

  test('rejects update metadata without a full SHA-256 digest', () async {
    final service = AppUpdateService(
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'versionName': '2.0.0',
            'versionCode': 2,
            'apkUrl': 'https://novel.kxhub.xyz/app3/app-release.apk',
            'sha256': 'abc123',
          }),
          200,
          request: request,
        );
      }),
    );

    await expectLater(
      service.checkForUpdate(),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Invalid update config'),
        ),
      ),
    );
  });

  test('does not follow redirects for update metadata', () async {
    final service = AppUpdateService(
      httpClient: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'http://untrusted.example/version.json'},
          request: request,
        );
      }),
    );

    await expectLater(
      service.checkForUpdate(),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Update check failed: 302'),
        ),
      ),
    );
  });

  test('restarts a stale ranged download after HTTP 416', () async {
    final testDir = Directory.systemTemp.createTempSync('app_update_416_test_');
    addTearDown(() {
      if (testDir.existsSync()) testDir.deleteSync(recursive: true);
    });
    final apkBytes = utf8.encode('fresh APK bytes');
    final sha256 = crypto.sha256.convert(apkBytes).toString();
    final partial = File(
      '${testDir.path}/sakura-9-${sha256.substring(0, 12)}.apk.download',
    );
    await partial.writeAsString('stale partial bytes');
    final update = AppUpdateInfo(
      versionName: '9.0.0',
      versionCode: 9,
      apkUrl: 'https://novel.kxhub.xyz/app3/app-release.apk',
      sha256: sha256,
      notes: const [],
    );
    var requestCount = 0;
    final service = AppUpdateService(
      temporaryDirectoryProvider: () async => testDir,
      httpClient: MockClient((request) async {
        requestCount++;
        if (requestCount == 1) {
          expect(request.headers['Range'], isNotEmpty);
          return http.Response('', 416, request: request);
        }
        expect(request.headers.containsKey('Range'), isFalse);
        return http.Response.bytes(
          apkBytes,
          200,
          request: request,
          headers: {'content-length': apkBytes.length.toString()},
        );
      }),
    );

    final apk = await service.downloadApk(update);

    expect(requestCount, 2);
    expect(await apk.readAsBytes(), apkBytes);
    expect(await partial.exists(), isFalse);
  });
}

http.Response _rangeResponse(List<int> bytes, http.Request request) {
  final range = request.headers['Range'];
  if (range == null) {
    return http.Response.bytes(
      bytes,
      200,
      request: request,
      headers: {'content-length': '${bytes.length}'},
    );
  }
  final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
  final start = int.parse(match!.group(1)!);
  final end = int.parse(match.group(2)!);
  final body = bytes.sublist(start, end + 1);
  return http.Response.bytes(
    body,
    206,
    request: request,
    headers: {
      'content-range': 'bytes $start-$end/${bytes.length}',
      'content-length': '${body.length}',
      'content-encoding': 'identity',
    },
  );
}

http.StreamedResponse _streamedRangeResponse(
  List<int> bytes,
  http.BaseRequest request, {
  int? returnedBodyEnd,
}) {
  final range = request.headers['Range']!;
  final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  final bodyEnd = returnedBodyEnd ?? end;
  final body = bytes.sublist(start, bodyEnd + 1);
  final expectedLength = end - start + 1;
  return http.StreamedResponse(
    Stream<List<int>>.value(body),
    206,
    contentLength: expectedLength,
    headers: {
      'content-range': 'bytes $start-$end/${bytes.length}',
      'content-length': '$expectedLength',
      'content-encoding': 'identity',
    },
    request: request,
  );
}
