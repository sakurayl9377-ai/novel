import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/reading_progress.dart';

void main() {
  test('home bookshelf and history resolve the same latest position', () {
    final oldHome = ReadingProgress(
      novelId: 'builtin_bqg995_bqg_5678',
      chapterIndex: 8,
      charPosition: 0,
      lastReadAt: DateTime(2026, 7, 17, 9),
    );
    final oldShelf = ReadingProgress(
      novelId: 'old_bqg_source_bqg_5678',
      chapterIndex: 8,
      charPosition: 500,
      lastReadAt: DateTime(2026, 7, 17, 10),
    );
    final latestHistory = ReadingProgress(
      novelId: 'builtin_bqg995_bqg_5678',
      chapterIndex: 7,
      charPosition: 1200,
      lastReadAt: DateTime(2026, 7, 17, 11),
    );

    for (final entryInitial in [oldHome, oldShelf, latestHistory]) {
      final resolved = resolveNovelEntryProgress([
        entryInitial,
        oldShelf,
        latestHistory,
      ]);
      expect(resolved?.chapterIndex, 7);
      expect(resolved?.charPosition, 1200);
    }
  });

  test('latest position may move backward within the same chapter', () {
    final earlier = ReadingProgress(
      novelId: 'book',
      chapterIndex: 4,
      charPosition: 1600,
      lastReadAt: DateTime(2026, 7, 17, 10),
    );
    final latest = ReadingProgress(
      novelId: 'book',
      chapterIndex: 4,
      charPosition: 800,
      lastReadAt: DateTime(2026, 7, 17, 11),
    );

    expect(resolveNovelEntryProgress([earlier, latest]), same(latest));
  });
}
