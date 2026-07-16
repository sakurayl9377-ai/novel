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
}
