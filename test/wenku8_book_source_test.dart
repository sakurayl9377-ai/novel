import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/book_source_service.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('Wenku8 search, detail, paged catalog and content are adapted', (
    tester,
  ) async {
    await _initStorage(tester);
    var searchRequests = 0;
    var homeRequests = 0;
    var catalogRequests = 0;
    var contentRequests = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/wap/') {
        homeRequests++;
        return _response(request, '''
<wml><card title="轻小说文库"><p>
【今日热榜】<a href="/wap/article/toplist.php?sort=dayvisit">更多..</a><br/>
<a href="/wap/article/articleinfo.php?id=98765">文学少女</a><br/>
【最近更新】<a href="/wap/article/toplist.php?sort=lastupdate">更多..</a><br/>
<a href="/wap/article/articleinfo.php?id=98766">新作品</a><br/>
</p></card></wml>
''');
      }
      if (request.url.path.endsWith('/wenku8/toplist')) {
        expect(request.url.queryParameters['sort'], 'lastupdate');
        expect(request.url.queryParameters['pages'], '3');
        return _response(request, '''
{"sort":"lastupdate","pagesFetched":1,"totalPages":2,"items":[
  {"bookId":"98766","title":"新作品"},
  {"bookId":"98767","title":"第二本"},
  {"bookId":"98768","title":"第三本"},
  {"bookId":"98769","title":"第四本"},
  {"bookId":"98770","title":"第五本"},
  {"bookId":"98771","title":"第六本"},
  {"bookId":"98772","title":"第七本"},
  {"bookId":"98773","title":"第八本"}
]}
''');
      }
      if (request.url.path == '/wap/article/search.php') {
        searchRequests++;
        expect(request.method, 'POST');
        expect(request.bodyFields, {
          'action': 'search',
          'searchtype': 'articlename',
          'searchkey': '文学少女',
        });
        return _response(request, '''
<wml><card title="搜索结果"><p>
<a href="articleinfo.php?id=98765">《文学少女》野村美月</a><br/>
</p></card></wml>
''');
      }
      if (request.url.path == '/wap/article/articleinfo.php') {
        return _response(request, '''
<wml><card title="文学少女"><p>
<b>文学少女</b><br/>
<img src="http://img.wenku8.com/image/98/98765/98765s.jpg" />
作者:<anchor>野村美月</anchor><br/>
状态:已完成<br/>
[作品简介]<br/>一段轻小说简介。<br/>
<p align="center">页脚</p>
</p></card></wml>
''');
      }
      if (request.url.path == '/wap/article/readbook.php') {
        catalogRequests++;
        final page = request.url.queryParameters['page'] ?? '1';
        if (page == '1') {
          return _response(request, '''
<wml><card title="文学少女"><p>
〖第一卷〗<br/>
<a href="readchapter.php?aid=98765&amp;cid=101">序章</a><br/>
[1/2]<br/>
</p></card></wml>
''');
        }
        return _response(request, '''
<wml><card title="文学少女"><p>
〖第二卷〗<br/>
<a href="readchapter.php?aid=98765&amp;cid=202">第一章</a><br/>
[2/2]<br/>
</p></card></wml>
''');
      }
      if (request.url.path == '/wap/article/readchapter.php') {
        contentRequests++;
        final page = request.url.queryParameters['page'] ?? '1';
        if (page == '1') {
          return _response(request, '''
<wml><card title="序章"><p>
导航<br/>
《文学少女》序章<br/>
<a href="readchapter.php?aid=98765&amp;cid=101&amp;page=2">下页</a>[1/2]<br/>
&nbsp;&nbsp;第一页正文。<br/>
<br/>
第一页第二段。<br/>
<a href="readchapter.php?aid=98765&amp;cid=101&amp;page=2">下页</a>[1/2]<br/>
页脚
</p></card></wml>
''');
        }
        return _response(request, '''
<wml><card title="序章"><p>
导航<br/>
《文学少女》序章<br/>
<a href="readchapter.php?aid=98765&amp;cid=101&amp;page=1">上页</a>[2/2]<br/>
第二页正文。<br/>
<a href="readchapter.php?aid=98765&amp;cid=101&amp;page=1">上页</a>[2/2]<br/>
页脚
</p></card></wml>
''');
      }
      return http.Response('not found', 404, request: request);
    });

    final service = BookSourceService(httpClient: client);
    await service.addSource(BookSourceService.wenku8Source);

    final home = await tester.runAsync(
      () => service.fetchHome(
        forceRefresh: true,
        sourceId: BookSourceService.wenku8Source.id,
      ),
    );
    expect(home, isNotNull);
    expect(home!.featured.single.title, '文学少女');
    expect(home.sections.single.hasMore, isTrue);
    expect(home.sections.single.category.url, contains('sort=lastupdate'));
    final moreItems = await tester.runAsync(
      () => service.fetchCategory(home.sections.single.category),
    );
    expect(moreItems, isNotNull);
    expect(moreItems, hasLength(8));
    expect(moreItems!.first.title, '新作品');

    final results = await tester.runAsync(
      () => service.searchBooks(
        '文学少女',
        sourceId: BookSourceService.wenku8Source.id,
      ),
    );
    expect(results, isNotNull);
    expect(results, hasLength(1));
    expect(results!.single.title, '文学少女');
    expect(results.single.author, '野村美月');
    expect(results.single.sourceId, BookSourceService.wenku8Source.id);

    final detail = await tester.runAsync(
      () => service.fetchBookDetail(results.single),
    );
    expect(detail!.description, '一段轻小说简介。');
    expect(detail.status, '已完成');
    expect(detail.coverUrl, contains('/novel-covers/wenku8/98765'));

    final chapters = await tester.runAsync(
      () => service.getChapterList(detail),
    );
    expect(chapters, isNotNull);
    expect(chapters, hasLength(2));
    expect(chapters![0].title, '第一卷 · 序章');
    expect(chapters[1].title, '第二卷 · 第一章');

    final content = await tester.runAsync(
      () => service.getChapterContent(
        chapters.first,
        BookSourceService.wenku8Source,
      ),
    );
    expect(content, contains('第一页正文。'));
    expect(content, contains('第一页第二段。'));
    expect(content, contains('第二页正文。'));
    expect(searchRequests, 1);
    expect(homeRequests, 1);
    expect(catalogRequests, 2);
    expect(contentRequests, 2);
  });
}

http.Response _response(http.BaseRequest request, String body) {
  return http.Response(
    body,
    200,
    request: request,
    headers: {'content-type': 'text/vnd.wap.wml; charset=utf-8'},
  );
}

Future<void> _initStorage(WidgetTester tester) async {
  final testDir = Directory.systemTemp.createTempSync('wenku8_source_test_');
  addTearDown(() {
    if (testDir.existsSync()) testDir.deleteSync(recursive: true);
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
