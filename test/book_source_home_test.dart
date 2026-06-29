import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/book_source_service.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('fetchHome uses the current BQG domain and parses API data', (
    tester,
  ) async {
    await _initStorage(tester);
    final requestedHosts = <String>[];
    final client = MockClient((request) async {
      requestedHosts.add(request.url.host);
      expect(request.url.host, 'www.bqg475.cc');
      expect(request.url.path, '/api/index');
      return http.Response(
        jsonEncode({
          'hotlist': [
            {
              'id': '2530',
              'title': '万相之王',
              'author': '天蚕土豆',
              'intro': '天地间有万相。',
            },
          ],
          'toplist': [
            {'id': '1152', 'title': '九星霸体诀', 'author': '平凡魔术师'},
          ],
        }),
        200,
        request: request,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final home = await tester.runAsync(
      () => BookSourceService(httpClient: client).fetchHome(forceRefresh: true),
    );

    expect(home, isNotNull);
    expect(home!.isEmpty, isFalse);
    expect(home.featured.single.title, '万相之王');
    expect(home.sections.single.items.single.title, '九星霸体诀');
    expect(home.featured.single.coverUrl, contains('www.bqg475.cc/bookimg/'));
    expect(requestedHosts, ['www.bqg475.cc']);
  });
}

Future<void> _initStorage(WidgetTester tester) async {
  final testDir = Directory.systemTemp.createTempSync('novel_home_test_');
  addTearDown(() {
    if (testDir.existsSync()) {
      testDir.deleteSync(recursive: true);
    }
  });
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return testDir.path;
      }
      return null;
    },
  );
  SharedPreferences.setMockInitialValues({});
  await tester.runAsync(() => StorageService().init());
}
