import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/utils/reading_text_range.dart';

void main() {
  test('TTS offsets map to a whole paragraph across sentence boundaries', () {
    const content = '　　第一句。第二句！\n\n　　下一段。';
    final first = paragraphRangeForOffset(content, content.indexOf('第二句'));
    final separator = paragraphRangeForOffset(content, content.indexOf('\n'));

    expect(content.substring(first.start, first.end), '　　第一句。第二句！');
    expect(content.substring(separator.start, separator.end), '　　下一段。');
  });

  test('reader follows the stable paragraph start instead of every word', () {
    final source = File('lib/screens/reading_screen.dart').readAsStringSync();

    expect(source, contains('activeTtsParagraph.start'));
    expect(source, contains('paragraphRangeForOffset('));
    expect(source, contains('context.select<TtsProvider, (bool, int, int)>'));
    expect(source, contains('Selector<TtsProvider, (bool, bool)>'));
    expect(source, isNot(contains('Consumer<TtsProvider>')));
    expect(source, isNot(contains('_sentenceRangeForOffset(')));
  });

  test(
    'expanded TTS controls own the bottom surface and expose exit actions',
    () {
      final source = File('lib/screens/reading_screen.dart').readAsStringSync();

      expect(
        source,
        contains('bottomChrome: _showTtsPanel ? null : _buildBottomChrome()'),
      );
      expect(source, contains("ValueKey('novel-tts-panel-close')"));
      expect(source, contains("label: const Text('收起')"));
      expect(source, contains("label: '结束朗读'"));
      expect(source, contains('_buildSleepTimerControl(ttsProvider, isNight)'));
      expect(source, contains("'全书'"));
    },
  );
}
