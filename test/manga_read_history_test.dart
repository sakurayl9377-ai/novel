import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/manga.dart';
import 'package:novel_app/models/manga_read_history.dart';

void main() {
  test('manga history derives progress from page position', () {
    const history = MangaReadHistory(
      mangaId: 'manga',
      title: 'Manga',
      coverUrl: '',
      chapterTitle: 'Chapter 2',
      chapterUrl: 'chapter-2',
      chapterIndex: 1,
      scrollOffset: 0,
      contentExtent: 0,
      updatedAtMs: 1,
      chapters: [],
      pageIndex: 4,
      pageOffsetRatio: 0.5,
      pageCount: 10,
    );

    expect(history.progress, closeTo(0.45, 0.001));
    final restored = MangaReadHistory.fromJson(history.toJson());
    expect(restored.pageCount, 10);
    expect(restored.progress, closeTo(0.45, 0.001));
  });

  test('explicit saved chapter progress takes precedence', () {
    const history = MangaReadHistory(
      mangaId: 'manga',
      title: 'Manga',
      coverUrl: '',
      chapterTitle: 'Chapter 2',
      chapterUrl: 'chapter-2',
      chapterIndex: 1,
      scrollOffset: 0,
      contentExtent: 0,
      updatedAtMs: 1,
      chapters: [],
      pageIndex: 1,
      pageCount: 10,
      chapterProgress: 0.73,
    );

    expect(history.progress, closeTo(0.73, 0.001));
    expect(
      MangaReadHistory.fromJson(history.toJson()).progress,
      closeTo(0.73, 0.001),
    );
  });

  test('sparse offline chapter metadata preserves its absolute index', () {
    const history = MangaReadHistory(
      mangaId: 'manga',
      title: 'Manga',
      coverUrl: '',
      chapterTitle: 'Chapter 8',
      chapterUrl: 'chapter-8',
      chapterIndex: 7,
      scrollOffset: 0,
      contentExtent: 0,
      updatedAtMs: 1,
      chapters: [MangaChapter(title: 'Chapter 8', url: 'chapter-8')],
    );

    expect(history.manga.chapters, hasLength(1));
    expect(history.sparseCatalogChapterIndexOverride, 7);
    expect(
      MangaReadHistory.fromJson(
        history.toJson(),
      ).sparseCatalogChapterIndexOverride,
      7,
    );
  });
}
