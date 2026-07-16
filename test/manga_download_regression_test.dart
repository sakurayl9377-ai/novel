import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manga downloads use the persistent manager and open local pages', () {
    final detail = File(
      'lib/screens/manga_detail_screen.dart',
    ).readAsStringSync();
    final downloads = File(
      'lib/screens/local_library_screens.dart',
    ).readAsStringSync();
    final manager = File(
      'lib/services/download_manager_service.dart',
    ).readAsStringSync();

    expect(detail, contains('enqueueMangaChapter('));
    expect(detail, isNot(contains('_cacheMangaImage(')));
    expect(manager, contains("_mangaManifestFileName = 'chapter.json'"));
    expect(manager, contains('validateMangaOfflineArchive('));
    expect(manager, contains('withDownloadIdleTimeout(response.stream)'));
    expect(downloads, contains('loadMangaPagePaths(item)'));
    expect(downloads, contains('chapterImageLoader: (_) async => pages'));
    expect(
      downloads,
      contains('historyChapterIndexOverride: item.chapterIndex'),
    );
    expect(manager, contains('return _downloadMangaPage('));
    expect(manager, contains('return _downloadProbed('));
  });

  test(
    'manga image memory work stays near the viewport and is downsampled',
    () {
      final home = File('lib/screens/manga_screen.dart').readAsStringSync();
      final reader = File(
        'lib/screens/manga_reader_screen.dart',
      ).readAsStringSync();

      expect(home, contains('_maxPrecachedCovers = 8'));
      expect(home, contains('ResizeImage.resizeIfNeeded('));
      expect(home, contains('MangaCover(imageUrl: item.imageUrl)'));
      expect(reader, contains('_prefetchRadius = 2'));
      expect(reader, contains('_maxTrackedPrefetchPages'));
      expect(reader, contains('cacheWidth: widget.cacheWidth'));
      expect(reader, contains('clearMemoryCacheWhenDispose: true'));
      expect(
        reader,
        contains('scrollCacheExtent: const ScrollCacheExtent.viewport(1)'),
      );
    },
  );
}
