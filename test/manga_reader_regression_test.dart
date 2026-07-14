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
    expect(source, contains('final location = _currentPageLocation'));
    expect(source, contains('scrollOffset: position.pixels'));
    expect(source, contains('contentExtent: position.maxScrollExtent'));
    expect(source, contains('pageCount: _images.length'));
    expect(source, contains('chapterProgress: _chapterProgressPercent / 100'));
  });

  test('reader controls overlay content without resizing the viewport', () {
    expect(source, contains('if (_showBars) _buildTopControls()'));
    expect(source, contains('if (_showBars) _buildBottomControls'));
    expect(source, isNot(contains('bottomNavigationBar: _showBars')));
    expect(source, isNot(contains('appBar: _showBars')));
  });

  test('the visible page is warmed before the chapter is revealed', () {
    final warmIndex = source.indexOf('await _warmPageImage(');
    final revealIndex = source.indexOf('_images = images;');
    expect(warmIndex, greaterThan(0));
    expect(revealIndex, greaterThan(warmIndex));
  });
}
