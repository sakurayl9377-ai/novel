import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/models/reading_progress.dart';
import 'package:novel_app/providers/bookshelf_provider.dart';

void main() {
  test('home entry restores bookshelf intra-chapter progress by identity', () {
    final shelfNovel = Novel(
      id: 'old_bqg_source_bqg_5678',
      title: '测试小说',
      sourceId: 'old_bqg_source',
      chapterUrl: 'https://fallback.example/book/5678/',
    );
    final homeNovel = Novel(
      id: 'builtin_bqg995_bqg_5678',
      title: '测试小说',
      sourceId: 'builtin_bqg995',
      chapterUrl: 'https://www.bqg475.cc/#/book/5678/',
    );
    final progress = ReadingProgress(
      novelId: shelfNovel.id,
      chapterIndex: 20,
      charPosition: 1500,
      scrollPosition: 0.5,
    );

    final restored = findBookshelfProgressForNovel(
      homeNovel,
      [shelfNovel],
      {shelfNovel.id: progress},
    );

    expect(restored?.chapterIndex, 20);
    expect(restored?.charPosition, 1500);
    expect(restored?.scrollPosition, 0.5);
  });

  test('title fallback never crosses novel source families', () {
    final shelfNovel = Novel(
      id: 'legacy-light-novel',
      title: '同名作品！',
      sourceId: 'builtin_wenku8',
      chapterUrl: 'https://www.wenku8.cc/wap/article/readbook.php',
    );
    final bqgNovel = Novel(
      id: 'legacy-web-novel',
      title: '同名作品',
      sourceId: 'builtin_bqg995',
    );
    final progress = ReadingProgress(
      novelId: shelfNovel.id,
      chapterIndex: 5,
      charPosition: 300,
    );

    expect(
      findBookshelfProgressForNovel(
        bqgNovel,
        [shelfNovel],
        {shelfNovel.id: progress},
      ),
      isNull,
    );
  });
}
