import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/manga_image_service.dart';

void main() {
  test('collapses a chapter sequence repeated through alternate CDN URLs', () {
    final firstPass = List.generate(
      4,
      (index) => 'https://static-tw.baozimh.com/chapter/demo/$index.jpg?w=900',
    );
    final secondPass = List.generate(
      4,
      (index) => 'https://static-tw.bzmgcn.com/chapter/demo/$index.jpg?q=100',
    );

    expect(
      normalizeMangaChapterImageSequence([...firstPass, ...secondPass]),
      firstPass,
    );
  });

  test('migrates current bzcdn chapter URLs to the stable asset host', () {
    expect(
      normalizeMangaChapterImageSequence([
        'https://s2.bzcdn.net/scomic/demo/0/1-iirg/1.jpg',
      ]),
      ['https://static-tw.bzmgcn.com/scomic/demo/0/1-iirg/1.jpg'],
    );
  });

  test('keeps an intentional repeated frame inside a non-repeated chapter', () {
    final images = [
      'https://static-tw.bzmgcn.com/chapter/demo/0.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/1.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/0.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/2.jpg',
    ];

    expect(normalizeMangaChapterImageSequence(images), images);
  });

  test('does not fold two different halves with the same length', () {
    final images = List.generate(
      8,
      (index) => 'https://static-tw.bzmgcn.com/chapter/demo/$index.jpg',
    );

    expect(normalizeMangaChapterImageSequence(images), images);
  });

  test('collapses three complete passes with retry URL representations', () {
    final firstPass = List.generate(
      2,
      (index) => 'https://static-tw.bzmgcn.com/chapter/demo/$index.jpg',
    );
    final secondPass = List.generate(
      2,
      (index) =>
          'https://static-tw.bzmgcn.com/chapter/demo/$index.jpg?t=retry-1',
    );
    final thirdPass = List.generate(
      2,
      (index) =>
          'https://static-tw.bzmgcn.com/chapter/demo/$index.jpg?t=retry-2',
    );

    expect(
      normalizeMangaChapterImageSequence([
        ...firstPass,
        ...secondPass,
        ...thirdPass,
      ]),
      firstPass,
    );
  });

  test('keeps a short exact repeated scene', () {
    final images = [
      'https://static-tw.bzmgcn.com/chapter/demo/0.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/1.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/0.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/1.jpg',
    ];

    expect(normalizeMangaChapterImageSequence(images), images);
  });

  test('keeps a three-frame scene repeated with the same URLs', () {
    final scene = List.generate(
      3,
      (index) => 'https://static-tw.bzmgcn.com/chapter/demo/$index.jpg',
    );

    expect(normalizeMangaChapterImageSequence([...scene, ...scene]), [
      ...scene,
      ...scene,
    ]);
  });

  test('recognizes three retry passes even when content is periodic', () {
    List<String> pass(int pass) => [
      'https://static-tw.bzmgcn.com/chapter/demo/0.jpg?pass=$pass',
      'https://static-tw.bzmgcn.com/chapter/demo/1.jpg?pass=$pass',
      'https://static-tw.bzmgcn.com/chapter/demo/0.jpg?pass=$pass',
      'https://static-tw.bzmgcn.com/chapter/demo/1.jpg?pass=$pass',
    ];

    final firstPass = pass(0);
    expect(
      normalizeMangaChapterImageSequence([
        ...firstPass,
        ...pass(1),
        ...pass(2),
      ]),
      firstPass,
    );
  });

  test('normalizes each page before trimming its pagination overlap', () {
    final chapterImages = <String>[];
    final firstPage = List.generate(
      5,
      (index) => 'https://static-tw.bzmgcn.com/chapter/demo/$index.jpg',
    );
    final firstPageRetryUrls = List.generate(
      5,
      (index) =>
          'https://static-tw.baozimh.com/chapter/demo/$index.jpg?t=retry',
    );
    final secondPage = List.generate(
      5,
      (index) => 'https://static-tw.bzmgcn.com/chapter/demo/${index + 3}.jpg',
    );
    final secondPageRetryUrls = List.generate(
      5,
      (index) =>
          'https://static-tw.baozimh.com/chapter/demo/${index + 3}.jpg?t=retry',
    );

    expect(
      appendMangaChapterImagePage(chapterImages, [
        ...firstPage,
        ...firstPageRetryUrls,
      ]),
      5,
    );
    expect(
      appendMangaChapterImagePage(chapterImages, [
        ...secondPage,
        ...secondPageRetryUrls,
      ]),
      3,
    );
    expect(
      chapterImages.map(mangaImageIdentity),
      List.generate(8, (index) => '/chapter/demo/$index.jpg'),
    );
  });

  test('keeps a single matching frame across a pagination boundary', () {
    final chapterImages = [
      'https://static-tw.bzmgcn.com/chapter/demo/0.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/1.jpg',
    ];
    final nextPage = [
      'https://static-tw.bzmgcn.com/chapter/demo/1.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/2.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/3.jpg',
    ];

    expect(appendMangaChapterImagePage(chapterImages, nextPage), 3);
    expect(chapterImages, [
      'https://static-tw.bzmgcn.com/chapter/demo/0.jpg',
      'https://static-tw.bzmgcn.com/chapter/demo/1.jpg',
      ...nextPage,
    ]);
  });

  test('stops a complete one-image page replay', () {
    final chapterImages = ['https://static-tw.bzmgcn.com/chapter/demo/0.jpg'];

    expect(
      appendMangaChapterImagePage(chapterImages, [
        'https://static-tw.bzmgcn.com/chapter/demo/0.jpg?t=retry',
      ]),
      0,
    );
    expect(chapterImages, ['https://static-tw.bzmgcn.com/chapter/demo/0.jpg']);
  });
}
