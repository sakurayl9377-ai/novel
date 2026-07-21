import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/novel_reader/novel_text_layout.dart';
import 'package:novel_app/utils/reading_text_range.dart';

void main() {
  test('TTS offsets map to a whole paragraph across sentence boundaries', () {
    const content = '　　第一句。第二句！\n\n　　下一段。';
    final first = paragraphRangeForOffset(content, content.indexOf('第二句'));
    final separator = paragraphRangeForOffset(content, content.indexOf('\n'));

    expect(content.substring(first.start, first.end), '第一句。第二句！');
    expect(content.substring(separator.start, separator.end), '下一段。');
  });

  test('paragraph highlight excludes indentation but keeps punctuation', () {
    const content = '　　正文，包含标点。　\n\n下一段';

    final range = paragraphRangeForOffset(content, content.indexOf('包含'));

    expect(range.start, content.indexOf('正文'));
    expect(content.substring(range.start, range.end), '正文，包含标点。');
  });

  test(
    'rendered highlight leaves indentation and trailing space unpainted',
    () {
      const content = '　　正文，包含标点。　';
      const highlight = Color(0x44ff9800);
      final range = paragraphRangeForOffset(content, content.indexOf('包含'));

      final span = NovelTextLayout.buildSpan(
        text: content,
        style: const TextStyle(fontSize: 18),
        paragraphSpacing: 0.8,
        highlightRange: range,
        highlightColor: highlight,
      );
      final children = span.children!.cast<TextSpan>();
      final indent = children.where((child) => child.semanticsLabel == '　　');
      final paintedText = children
          .where((child) => child.style?.backgroundColor == highlight)
          .map((child) => child.text)
          .join();

      expect(indent, hasLength(1));
      expect(indent.single.style?.backgroundColor, isNull);
      expect(paintedText, '正文，包含标点。');
      expect(children.last.text, '　');
      expect(children.last.style?.backgroundColor, isNull);
    },
  );

  test('paragraph edges trim the complete supported Unicode space set', () {
    const edgeSpaces = <int>[
      0x00a0,
      0x1680,
      0x180e,
      0x2000,
      0x2001,
      0x2002,
      0x2003,
      0x2004,
      0x2005,
      0x2006,
      0x2007,
      0x2008,
      0x2009,
      0x200a,
      0x202f,
      0x205f,
      0x2060,
      0x3000,
      0xfeff,
    ];

    for (final code in edgeSpaces) {
      final space = String.fromCharCode(code);
      final content = '$space正文，保留标点。$space';
      final range = paragraphRangeForOffset(content, content.indexOf('保留'));

      expect(
        content.substring(range.start, range.end),
        '正文，保留标点。',
        reason: 'U+${code.toRadixString(16).padLeft(4, '0')}',
      );
      expect(readingParagraphStartForOffset(content, content.length), 1);
      expect(skipReadingTextEdgeWhitespace(content, 0), 1);
    }
  });

  test('Unicode line and paragraph separators create paragraph boundaries', () {
    const content = '第一段。\u2028\u2029\u00a0第二段！';

    final range = paragraphRangeForOffset(content, content.indexOf('第二'));

    expect(content.substring(range.start, range.end), '第二段！');
    expect(
      readingParagraphStartForOffset(content, content.indexOf('二')),
      range.start,
    );
  });

  test('reader follows the stable paragraph start instead of every word', () {
    final source = File('lib/screens/reading_screen.dart').readAsStringSync();
    final selectableSource = File(
      'lib/features/novel_reader/selectable_novel_text.dart',
    ).readAsStringSync();

    expect(source, contains('activeTtsParagraph.start'));
    expect(source, contains('paragraphRangeForOffset('));
    expect(source, contains('captureLeadingVisibleAnchor()'));
    expect(selectableSource, contains("label: '从本段听'"));
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
