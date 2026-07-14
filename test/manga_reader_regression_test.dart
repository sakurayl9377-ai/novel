import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manga history persists page count for page-based progress', () {
    final source = File(
      'lib/screens/manga_reader_screen.dart',
    ).readAsStringSync();

    expect(source, contains('pageCount: _images.length'));
    expect(source, contains('chapterProgress: _chapterProgressPercent / 100'));
  });

  test('continuous reader owns chapter restore and position history', () {
    final source = File(
      'lib/screens/manga_reader_screen.dart',
    ).readAsStringSync();

    expect(source, contains('ContinuousMangaView('));
    expect(source, contains('onPositionSettled:'));
    expect(source, contains('scrollOffset: 0'));
    expect(source, contains('pageIndex: _continuousPageIndex'));
  });

  test(
    'manga chapter transitions are single-flight and image states are scoped',
    () {
      final source = File(
        'lib/screens/manga_reader_screen.dart',
      ).readAsStringSync();

      expect(source, contains('bool _isChangingChapter = false;'));
      expect(source, contains('chapterLoadGeneration: chapterLoadGeneration'));
      expect(source, isNot(contains('void _handleScrollChanged()')));
    },
  );

  test('reader controls overlay content without resizing the viewport', () {
    final source = File(
      'lib/screens/manga_reader_screen.dart',
    ).readAsStringSync();

    expect(source, contains('if (_showBars) _buildTopControls()'));
    expect(source, contains('if (_showBars) _buildBottomControls'));
    expect(
      source,
      contains('Positioned.fill(\n            child: GestureDetector('),
    );
    expect(source, isNot(contains('bottomNavigationBar: _showBars')));
    expect(source, isNot(contains('appBar: _showBars')));
  });

  test('progress updates do not rebuild the entire reader screen', () {
    final source = File(
      'lib/screens/manga_reader_screen.dart',
    ).readAsStringSync();

    expect(source, contains('ValueNotifier<int> _chapterProgressNotifier'));
    expect(source, contains('ValueListenableBuilder<int>'));
    expect(source, contains('if (chapterChanged) {\n        setState(apply);'));
  });

  test('explicit chapter navigation always starts from the chapter head', () {
    final source = File(
      'lib/screens/manga_reader_screen.dart',
    ).readAsStringSync();

    expect(source, contains('await _loadChapter(_chapters[index], index);'));
    expect(
      source,
      isNot(
        contains(
          'await _loadChapter(\n          _chapters[index],\n          index,\n          initialPageIndex:',
        ),
      ),
    );
  });

  test(
    'the visible manga page is warmed before leaving the loading screen',
    () {
      final source = File(
        'lib/screens/manga_reader_screen.dart',
      ).readAsStringSync();

      final warmIndex = source.indexOf('await _preloadPageImage(');
      final revealIndex = source.indexOf(
        'setState(() {\n        _images = images;',
      );
      expect(warmIndex, greaterThan(0));
      expect(revealIndex, greaterThan(warmIndex));
      expect(source, contains('.timeout(const Duration(seconds: 3))'));
    },
  );
}
