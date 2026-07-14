import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(source, isNot(contains('bottomNavigationBar: _showBars')));
    expect(source, isNot(contains('appBar: _showBars')));
  });
}
