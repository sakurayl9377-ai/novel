import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'continuous reading avoids rebuilding the whole page while dragging',
    () {
      final reader = File('lib/screens/reading_screen.dart').readAsStringSync();
      final continuous = File(
        'lib/widgets/continuous_chapter_view.dart',
      ).readAsStringSync();

      expect(
        reader,
        contains('final shouldRebuild = chapterChanged || settled;'),
      );
      expect(continuous, contains('_liveReportIntervalMs = 80'));
      expect(continuous, contains('_reportLiveReadingPosition()'));
      expect(continuous, contains('SplayTreeMap<int, String>'));
      expect(continuous, contains('RepaintBoundary('));
    },
  );
}
