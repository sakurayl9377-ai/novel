import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/novel_reader/novel_text_layout.dart';

void main() {
  test('paragraph spacing and highlight preserve every source offset', () {
    const text = '　　第一段。\n\n　　第二段高亮内容。\n\n　　第三段。';
    final span = NovelTextLayout.buildSpan(
      text: text,
      style: const TextStyle(fontSize: 20, height: 1.7),
      paragraphSpacing: 1.1,
      highlightRange: const TextRange(start: 10, end: 16),
      highlightColor: Colors.amber,
    );

    expect(span.toPlainText(), text);
  });

  test('page beginning on a paragraph gap keeps the newline offset', () {
    const page = '\n　　下一段。';
    final span = NovelTextLayout.buildSpan(
      text: page,
      previousCodeUnit: 0x0A,
      globalStartOffset: 12,
      style: const TextStyle(fontSize: 20),
      paragraphSpacing: 0.8,
    );

    expect(span.toPlainText(), page);
  });

  test('cached gap offsets never retain old spacing or highlight styles', () {
    const text = '甲\n\n乙丙';
    NovelTextLayout.buildSpan(
      text: text,
      style: const TextStyle(fontSize: 20),
      paragraphSpacing: 0.2,
    );

    final span = NovelTextLayout.buildSpan(
      text: text,
      globalStartOffset: 50,
      style: const TextStyle(fontSize: 20),
      paragraphSpacing: 1.5,
      highlightRange: const TextRange(start: 53, end: 55),
      highlightColor: Colors.amber,
    );
    final children = span.children!.cast<TextSpan>();
    final gap = children.singleWhere(
      (child) => child.text == '\n' && child.style?.height == 1,
    );
    final highlighted = children
        .where((child) => child.style?.backgroundColor == Colors.amber)
        .map((child) => child.text)
        .join();

    expect(span.toPlainText(), text);
    expect(gap.style?.fontSize, 30);
    expect(highlighted, '乙丙');
  });

  test('paragraph layout cache never retains more than five texts', () {
    for (var index = 0; index < 12; index++) {
      NovelTextLayout.buildSpan(
        text: '第 $index 章\n\n正文 $index',
        style: const TextStyle(fontSize: 20),
        paragraphSpacing: 0.8,
      );
    }

    expect(NovelTextLayout.cachedTextCount, lessThanOrEqualTo(5));
  });

  test(
    'first-line indent uses non-whitespace advances without offset drift',
    () {
      const text = '\u3000\u3000正文首行。\n\n\u3000\u3000第二段正文。';
      final span = NovelTextLayout.buildSpan(
        text: text,
        style: const TextStyle(fontSize: 20, height: 1.6),
        paragraphSpacing: 0.8,
      );

      final indentSpans = span.children!
          .whereType<TextSpan>()
          .where((child) => child.semanticsLabel != null)
          .toList(growable: false);

      expect(span.toPlainText(), text);
      expect(span.toPlainText().length, text.length);
      expect(indentSpans, hasLength(2));
      expect(indentSpans.first.semanticsLabel, '\u3000\u3000');
      expect(indentSpans.first.text, isNot(contains('\u3000')));
      expect(indentSpans.first.style?.color, Colors.transparent);

      final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
        ..layout(maxWidth: 320);
      final bodyStart = painter.getOffsetForCaret(
        const TextPosition(offset: 2),
        Rect.zero,
      );
      expect(bodyStart.dx, greaterThanOrEqualTo(36));
    },
  );

  test('chapter text without indent markers is not shifted', () {
    const text = '正文首行。\n\n第二段正文。';
    final span = NovelTextLayout.buildSpan(
      text: text,
      style: const TextStyle(fontSize: 20),
      paragraphSpacing: 0.8,
    );

    expect(span.toPlainText(), text);
    expect(
      span.children!.whereType<TextSpan>().where(
        (child) => child.semanticsLabel != null,
      ),
      isEmpty,
    );
  });
}
