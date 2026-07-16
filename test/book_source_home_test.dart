import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/book_source_service.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:novel_app/models/novel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

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

  testWidgets('detail and catalog share one book metadata request', (
    tester,
  ) async {
    await _initStorage(tester);
    var bookRequests = 0;
    var catalogRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/book') {
        bookRequests++;
        return http.Response(
          jsonEncode({
            'id': '990001',
            'dirid': 'catalog-990001',
            'title': '并行加载测试',
            'author': '测试作者',
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path == '/api/booklist') {
        catalogRequests++;
        return http.Response(
          jsonEncode({
            'list': ['第一章', '第二章', '第三章'],
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('not found', 404, request: request);
    });
    final service = BookSourceService(httpClient: client);
    final novel = Novel(
      id: 'builtin_bqg995_bqg_990001',
      title: '并行加载测试',
      chapterUrl: 'https://www.bqg475.cc/#/book/990001/',
      sourceId: 'builtin_bqg995',
    );

    final result = await tester.runAsync(
      () => Future.wait([
        service.fetchBookDetail(novel),
        service.getChapterList(novel),
      ]),
    );

    expect((result![0] as Novel).author, '测试作者');
    expect((result[1] as List).length, 3);
    expect(bookRequests, 1);
    expect(catalogRequests, 1);
  });

  testWidgets('catalog cache isolates the same novel id across sources', (
    tester,
  ) async {
    await _initStorage(tester);
    var catalogRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/book') {
        final id = request.url.queryParameters['id'] ?? '';
        return http.Response(
          jsonEncode({'id': id, 'dirid': 'catalog-$id', 'title': 'Book $id'}),
          200,
          request: request,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path == '/api/booklist') {
        catalogRequests++;
        final id = request.url.queryParameters['id'] ?? '';
        return http.Response(
          jsonEncode({
            'list': [id == 'catalog-111' ? '来源甲章节' : '来源乙章节'],
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('not found', 404, request: request);
    });
    final service = BookSourceService(httpClient: client);
    final sourceA = Novel(
      id: 'same-catalog-id',
      title: '来源甲',
      sourceId: 'source-a',
      chapterUrl: 'https://www.bqg475.cc/#/book/111/',
    );
    final sourceB = Novel(
      id: 'same-catalog-id',
      title: '来源乙',
      sourceId: 'source-b',
      chapterUrl: 'https://www.bqg475.cc/#/book/222/',
    );

    final catalogs = await tester.runAsync(
      () async => <List<dynamic>>[
        await service.getChapterList(sourceA),
        await service.getChapterList(sourceB),
        await service.getChapterList(sourceA),
      ],
    );

    expect((catalogs![0].single as dynamic).title, '来源甲章节');
    expect((catalogs[1].single as dynamic).title, '来源乙章节');
    expect((catalogs[2].single as dynamic).title, '来源甲章节');
    expect(catalogRequests, 2);
  });

  test(
    'provisional catalog makes the requested chapter immediately readable',
    () {
      final service = BookSourceService();
      final novel = Novel(
        id: 'builtin_bqg995_bqg_990002',
        title: '快速阅读测试',
        chapterUrl: 'https://www.bqg475.cc/#/book/990002/',
      );

      final chapters = service.buildProvisionalChapterList(
        novel,
        throughIndex: 8,
      );

      expect(chapters, hasLength(9));
      expect(chapters[8].index, 8);
      expect(chapters[8].url, endsWith('/990002/9.html'));
    },
  );
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
