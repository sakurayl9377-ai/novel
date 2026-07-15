import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/app_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
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

  test('downloadApk reuses a verified downloaded APK', () async {
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
        expect(request.headers.containsKey('Range'), isFalse);
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
