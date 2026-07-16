import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/screens/manga_reader_screen.dart').readAsStringSync();
  });

  test('manga reader renders exactly one chapter', () {
    expect(source, contains("key: ValueKey('manga-chapter-"));
    expect(source, contains('itemCount: _images.length + 1'));
    expect(source, isNot(contains('ContinuousMangaView')));
    expect(source, isNot(contains('loadAdjacent')));
  });

  test('chapters can only change through explicit controls', () {
    expect(source, contains('await _loadChapter(_chapters[index], index);'));
    expect(source, contains('onPressed: canPrev ? () => _changeChapter(-1)'));
    expect(source, contains('onPressed: canNext ? () => _changeChapter(1)'));
    expect(source, contains('unawaited(_changeChapterTo(selected));'));
  });

  test('manual chapter changes always start from the chapter head', () {
    expect(source, contains('_scrollController.jumpTo(0);'));
    expect(
      source,
      isNot(
        contains(
          'await _loadChapter(\n          _chapters[index],\n          index,\n          initialPageIndex:',
        ),
      ),
    );
  });

  test('history persists the current single-chapter position', () {
    expect(source, contains('final location = isPaged'));
    expect(source, contains('_currentPagedPageIndex.toDouble()'));
    expect(source, contains('position!.pixels'));
    expect(source, contains('pageCount: _images.length'));
    expect(source, contains('chapterProgress: _chapterProgressPercent / 100'));
  });

  test('reader controls overlay content without resizing the viewport', () {
    expect(source, contains('return ReaderShell('));
    expect(source, contains('chromeVisible: _showBars'));
    expect(source, contains('topChrome: _buildReaderTopControls()'));
    expect(source, contains('bottomChrome: _buildReaderBottomControls'));
    expect(source, isNot(contains('bottomNavigationBar: _showBars')));
    expect(source, isNot(contains('appBar: _showBars')));
  });

  test('the visible page is warmed before the chapter is revealed', () {
    final warmIndex = source.indexOf('await _warmPageImage(');
    final revealIndex = source.indexOf('_images = images;');
    expect(warmIndex, greaterThan(0));
    expect(revealIndex, greaterThan(warmIndex));
  });

  test('reader supports bounded long-strip and paged pipelines', () {
    expect(source, contains('MangaReadingMode.longStrip'));
    expect(source, contains('MangaReadingMode.paged'));
    expect(source, contains('MangaPagedView('));
    expect(source, contains('_layoutIndex.indexAtOffset('));
    expect(source, contains('_prefetchRadius = 2'));
    expect(source, contains('_prewarmNextChapterFirstPage'));
  });

  test('page failures expose a page-level retry action', () {
    expect(source, contains('_buildRetryFailure(state.reLoadImage)'));
    expect(source, contains('onPressed: retry'));
    expect(source, contains("label: const Text('重试')"));
  });

  test('original quality keeps every warm and fallback decode bounded', () {
    expect(source, contains('_maxOriginalDecodeWidth = 4096'));
    expect(source, contains('MangaTiledImage('));
    expect(source, contains('useTiledDecoding:'));
    expect(source, isNot(contains('MangaImageQuality.original) return null')));
  });
}
