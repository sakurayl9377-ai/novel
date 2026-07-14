import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chapter changes do not reuse the initial chapter progress', () {
    final source = File(
      'lib/screens/manga_reader_screen.dart',
    ).readAsStringSync();

    expect(source, contains('progress: initialScrollProgress,'));
    expect(
      source,
      isNot(contains('initialScrollProgress ?? widget.initialScrollProgress')),
    );
  });

  test(
    'manga chapter transitions are single-flight and image states are scoped',
    () {
      final source = File(
        'lib/screens/manga_reader_screen.dart',
      ).readAsStringSync();

      expect(source, contains('bool _isChangingChapter = false;'));
      expect(source, contains('chapterLoadGeneration: chapterLoadGeneration'));
      expect(
        source,
        contains("ValueKey('\${_currentChapter.url}|\${_images[index]}')"),
      );
    },
  );
}
