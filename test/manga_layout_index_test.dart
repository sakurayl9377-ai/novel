import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/manga_reader/manga_layout_index.dart';

void main() {
  test('layout index updates offsets without rescanning page extents', () {
    final index = MangaLayoutIndex(pageCount: 5, defaultExtent: 100);

    expect(index.totalExtent, 500);
    expect(index.offsetOf(3), 300);

    index.updateExtent(1, 250);

    expect(index.extentAt(1), 250);
    expect(index.offsetOf(3), 450);
    expect(index.totalExtent, 650);
  });

  test('layout index locates pages and within-page ratios', () {
    final index = MangaLayoutIndex(pageCount: 4, defaultExtent: 100)
      ..updateExtent(1, 200);

    expect(index.indexAtOffset(0), 0);
    expect(index.indexAtOffset(99), 0);
    expect(index.indexAtOffset(100), 1);
    expect(index.indexAtOffset(299), 1);
    expect(index.indexAtOffset(300), 2);
    expect(index.indexAtOffset(999), 3);

    final location = index.locationAt(200);
    expect(location.pageIndex, 1);
    expect(location.pageOffsetRatio, closeTo(0.5, 0.001));
  });

  test('empty layout index has a stable zero location', () {
    final index = MangaLayoutIndex(pageCount: 0, defaultExtent: 100);

    expect(index.totalExtent, 0);
    expect(index.indexAtOffset(30), 0);
    expect(index.locationAt(30).pageIndex, 0);
  });
}
