import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:novel_app/models/manga.dart';
import 'package:novel_app/services/manga_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'normalizes each page and trims only adjacent pagination overlap',
    () async {
      final firstPage = Uri.parse(
        'https://reader.example/comic/chapter/demo/0_7.html?case=three-pages',
      );
      final secondPage = Uri.parse(
        'https://reader.example/comic/chapter/demo/0_7_2.html',
      );
      final thirdPage = Uri.parse(
        'https://reader.example/comic/chapter/demo/0_7_3.html',
      );
      final legacyCacheKey =
          'manga_chapter_images_cache_v3_${base64Url.encode(utf8.encode('$firstPage'))}';
      SharedPreferences.setMockInitialValues({
        legacyCacheKey: jsonEncode({
          'cachedAt': DateTime.now().millisecondsSinceEpoch,
          'images': ['https://static-tw.bzmgcn.com/scomic/demo/stale.jpg'],
        }),
      });

      final requests = <Uri>[];
      final fixtures = <String, String>{
        '$firstPage':
            '''
        <html><body>
          <img src="https://static-tw.bzmgcn.com/scomic/demo/001.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/002.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/003.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/004.jpg">
          <script>
            ["https://static-tw.baozimh.com/scomic/demo/001.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/002.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/003.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/004.jpg?t=retry"]
          </script>
          <a rel="next" href="$firstPage">Next page</a>
          <a class="pagination-next" href="javascript:;" data-url="/comic/chapter/demo/0_7_2.html">&#19979;&#19968;&#39029;</a>
          <a rel="next" href="/comic/chapter/demo/0_8.html">Next chapter</a>
        </body></html>
      ''',
        '$secondPage': '''
        <html><body>
          <img src="https://static-tw.bzmgcn.com/scomic/demo/003.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/004.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/005.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/006.jpg">
          <script>
            ["https://static-tw.baozimh.com/scomic/demo/003.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/004.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/005.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/006.jpg?t=retry"]
          </script>
          <a id="next-chapter" href="/comic/chapter/demo/0_7_3.html">Next page</a>
        </body></html>
      ''',
        '$thirdPage':
            '''
        <html><body>
          <img src="https://static-tw.bzmgcn.com/scomic/demo/005.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/006.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/007.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/008.jpg">
          <script>
            ["https://static-tw.baozimh.com/scomic/demo/005.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/006.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/007.jpg?t=retry",
             "https://static-tw.baozimh.com/scomic/demo/008.jpg?t=retry"]
          </script>
          <a rel="next" href="$firstPage">Next page</a>
        </body></html>
      ''',
      };
      final service = _serviceWithFixtures(fixtures, requests);

      final images = await service.fetchChapterImages(
        MangaChapter(title: 'Chapter 7', url: '$firstPage'),
      );

      expect(requests, [firstPage, secondPage, thirdPage]);
      expect(images, [
        'https://static-tw.bzmgcn.com/scomic/demo/001.jpg',
        'https://static-tw.bzmgcn.com/scomic/demo/002.jpg',
        'https://static-tw.bzmgcn.com/scomic/demo/003.jpg',
        'https://static-tw.bzmgcn.com/scomic/demo/004.jpg',
        'https://static-tw.bzmgcn.com/scomic/demo/005.jpg',
        'https://static-tw.bzmgcn.com/scomic/demo/006.jpg',
        'https://static-tw.bzmgcn.com/scomic/demo/007.jpg',
        'https://static-tw.bzmgcn.com/scomic/demo/008.jpg',
      ]);
    },
  );

  test('keeps one copy for a normal single-page chapter', () async {
    final page = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_8.html',
    );
    final requests = <Uri>[];
    final service = _serviceWithFixtures({
      '$page': '''
        <html><body>
          <amp-img src="https://static-tw.bzmgcn.com/scomic/demo/008.jpg"></amp-img>
          <button on="tap:AMP.setState({src: 'https://static-tw.baozimh.com/scomic/demo/008.jpg?t=' + random()})">Retry</button>
        </body></html>
      ''',
    }, requests);

    final images = await service.fetchChapterImages(
      MangaChapter(title: 'Chapter 8', url: '$page'),
    );

    expect(requests, [page]);
    expect(images, ['https://static-tw.bzmgcn.com/scomic/demo/008.jpg']);
  });

  test('collapses three DOM passes for a normal single-page chapter', () async {
    final page = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_9.html',
    );
    final requests = <Uri>[];
    final service = _serviceWithFixtures({
      '$page': '''
        <html><body>
          <img src="https://static-tw.bzmgcn.com/scomic/demo/009-1.jpg">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/009-2.jpg">
          <amp-img src="https://static-tw.bzmgcn.com/scomic/demo/009-1.jpg?t=retry-1"></amp-img>
          <amp-img src="https://static-tw.bzmgcn.com/scomic/demo/009-2.jpg?t=retry-1"></amp-img>
          <img src="https://static-tw.bzmgcn.com/scomic/demo/009-1.jpg?t=retry-2">
          <img src="https://static-tw.bzmgcn.com/scomic/demo/009-2.jpg?t=retry-2">
        </body></html>
      ''',
    }, requests);

    final images = await service.fetchChapterImages(
      MangaChapter(title: 'Chapter 9', url: '$page'),
    );

    expect(requests, [page]);
    expect(images, [
      'https://static-tw.bzmgcn.com/scomic/demo/009-1.jpg',
      'https://static-tw.bzmgcn.com/scomic/demo/009-2.jpg',
    ]);
  });

  test('stops when a false next page replays the same chapter', () async {
    final firstPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_10.html',
    );
    final falseSecondPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_10.html?page=2',
    );
    final requests = <Uri>[];
    final body = '''
      <html><body>
        <img src="https://static-tw.bzmgcn.com/scomic/demo/010-1.jpg">
        <img src="https://static-tw.bzmgcn.com/scomic/demo/010-2.jpg">
        <a rel="next" href="?page=2">Next page</a>
      </body></html>
    ''';
    final service = _serviceWithFixtures({
      '$firstPage': body,
      '$falseSecondPage': body,
    }, requests);

    final images = await service.fetchChapterImages(
      MangaChapter(title: 'Chapter 10', url: '$firstPage'),
    );

    expect(requests, [firstPage, falseSecondPage]);
    expect(images, [
      'https://static-tw.bzmgcn.com/scomic/demo/010-1.jpg',
      'https://static-tw.bzmgcn.com/scomic/demo/010-2.jpg',
    ]);
  });

  test('does not follow a next link that belongs to another chapter', () async {
    final firstPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_9.html?case=other-chapter',
    );
    final otherChapter = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_10.html',
    );
    final requests = <Uri>[];
    final service = _serviceWithFixtures({
      '$firstPage':
          '''
        <html><body>
          <img src="https://static-tw.bzmgcn.com/scomic/demo/009.jpg">
          <a rel="next" href="$otherChapter">Next page</a>
        </body></html>
      ''',
    }, requests);

    final images = await service.fetchChapterImages(
      MangaChapter(title: 'Chapter 9', url: '$firstPage'),
    );

    expect(requests, [firstPage]);
    expect(images, ['https://static-tw.bzmgcn.com/scomic/demo/009.jpg']);
  });

  test('does not cache a partial chapter when a later page fails', () async {
    final firstPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_11.html?case=failed-page',
    );
    final secondPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_11.html?page=2',
    );
    final requests = <Uri>[];
    final service = MangaService(
      siteUriProvider: () async => Uri.parse('https://reader.example/'),
      pageFetcher: (uri, {required timeout}) async {
        requests.add(uri);
        if (uri == firstPage) {
          return http.Response(
            '''
              <html><body>
                <img src="https://static-tw.bzmgcn.com/scomic/demo/011.jpg">
                <a rel="next" href="?page=2">Next page</a>
              </body></html>
            ''',
            200,
            request: http.Request('GET', uri),
          );
        }
        return http.Response('', 500, request: http.Request('GET', uri));
      },
    );

    await expectLater(
      service.fetchChapterImages(
        MangaChapter(title: 'Chapter 11', url: '$firstPage'),
      ),
      throwsException,
    );

    final prefs = await SharedPreferences.getInstance();
    final currentCacheKey =
        'manga_chapter_images_cache_v4_${base64Url.encode(utf8.encode('$firstPage'))}';
    expect(requests, [firstPage, secondPage]);
    expect(prefs.containsKey(currentCacheKey), isFalse);
  });

  test('rejects a later page redirected to another chapter', () async {
    final firstPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_12.html',
    );
    final secondPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_12_2.html',
    );
    final redirectedPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_13.html',
    );
    final requests = <Uri>[];
    final service = MangaService(
      siteUriProvider: () async => Uri.parse('https://reader.example/'),
      pageFetcher: (uri, {required timeout}) async {
        requests.add(uri);
        if (uri == firstPage) {
          return http.Response(
            '''
              <html><body>
                <img src="https://static-tw.bzmgcn.com/scomic/demo/012.jpg">
                <a rel="next" href="$secondPage">Next page</a>
              </body></html>
            ''',
            200,
            request: http.Request('GET', uri),
          );
        }
        return http.Response(
          '''
            <html><body>
              <img src="https://static-tw.bzmgcn.com/scomic/demo/013.jpg">
            </body></html>
          ''',
          200,
          request: http.Request('GET', redirectedPage),
        );
      },
    );

    await expectLater(
      service.fetchChapterImages(
        MangaChapter(title: 'Chapter 12', url: '$firstPage'),
      ),
      throwsA(isA<StateError>()),
    );

    final prefs = await SharedPreferences.getInstance();
    final currentCacheKey =
        'manga_chapter_images_cache_v4_${base64Url.encode(utf8.encode('$firstPage'))}';
    expect(requests, [firstPage, secondPage]);
    expect(prefs.containsKey(currentCacheKey), isFalse);
  });

  test('rejects a later page redirected back into a pagination loop', () async {
    final firstPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_14.html',
    );
    final secondPage = Uri.parse(
      'https://reader.example/comic/chapter/demo/0_14_2.html',
    );
    final requests = <Uri>[];
    final service = MangaService(
      siteUriProvider: () async => Uri.parse('https://reader.example/'),
      pageFetcher: (uri, {required timeout}) async {
        requests.add(uri);
        return http.Response(
          '''
            <html><body>
              <img src="https://static-tw.bzmgcn.com/scomic/demo/014.jpg">
              <a rel="next" href="$secondPage">Next page</a>
            </body></html>
          ''',
          200,
          request: http.Request('GET', firstPage),
        );
      },
    );

    await expectLater(
      service.fetchChapterImages(
        MangaChapter(title: 'Chapter 14', url: '$firstPage'),
      ),
      throwsA(isA<StateError>()),
    );

    final prefs = await SharedPreferences.getInstance();
    final currentCacheKey =
        'manga_chapter_images_cache_v4_${base64Url.encode(utf8.encode('$firstPage'))}';
    expect(requests, [firstPage, secondPage]);
    expect(prefs.containsKey(currentCacheKey), isFalse);
  });

  test('normalizes next-page links across current Baozi aliases', () async {
    final requestedFirstPage = Uri.parse(
      'https://cn.cnbzmg.com/comic/chapter/demo/0_15.html',
    );
    final redirectedFirstPage = Uri.parse(
      'https://www.twbzmg.com/comic/chapter/demo/0_15.html',
    );
    final advertisedSecondPage = Uri.parse(
      'https://cn.cnbzmg.com/comic/chapter/demo/0_15_2.html',
    );
    final normalizedSecondPage = Uri.parse(
      'https://www.twbzmg.com/comic/chapter/demo/0_15_2.html',
    );
    final requests = <Uri>[];
    final service = MangaService(
      siteUriProvider: () async => Uri.parse('https://cn.cnbzmg.com/'),
      pageFetcher: (uri, {required timeout}) async {
        requests.add(uri);
        if (uri == requestedFirstPage) {
          return http.Response(
            '''
              <html><body>
                <img src="https://static-tw.bzmgcn.com/scomic/demo/015-1.jpg">
                <a rel="next" href="$advertisedSecondPage">Next page</a>
              </body></html>
            ''',
            200,
            request: http.Request('GET', redirectedFirstPage),
          );
        }
        return http.Response(
          '''
            <html><body>
              <img src="https://static-tw.bzmgcn.com/scomic/demo/015-2.jpg">
            </body></html>
          ''',
          uri == normalizedSecondPage ? 200 : 404,
          request: http.Request('GET', uri),
        );
      },
    );

    final images = await service.fetchChapterImages(
      MangaChapter(title: 'Chapter 15', url: '$requestedFirstPage'),
    );

    expect(requests, [requestedFirstPage, normalizedSecondPage]);
    expect(images, [
      'https://static-tw.bzmgcn.com/scomic/demo/015-1.jpg',
      'https://static-tw.bzmgcn.com/scomic/demo/015-2.jpg',
    ]);
  });
}

MangaService _serviceWithFixtures(
  Map<String, String> fixtures,
  List<Uri> requests,
) {
  return MangaService(
    siteUriProvider: () async => Uri.parse('https://reader.example/'),
    pageFetcher: (uri, {required timeout}) async {
      requests.add(uri);
      final body = fixtures['$uri'];
      return http.Response(
        body ?? '',
        body == null ? 404 : 200,
        request: http.Request('GET', uri),
      );
    },
  );
}
