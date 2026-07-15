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
    expect(source, isNot(contains('_sentenceRangeForOffset(')));
  });
}
