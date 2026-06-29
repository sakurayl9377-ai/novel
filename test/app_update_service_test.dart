import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/app_update_service.dart';

void main() {
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
      apkUrl: 'http://example.com/app.apk',
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
}
