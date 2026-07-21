import 'dart:ui' show TextRange;

TextRange paragraphRangeForOffset(String text, int offset) {
  if (text.isEmpty || offset < 0) return TextRange.empty;

  var anchor = offset.clamp(0, text.length - 1).toInt();
  if (isReadingTextLineBreakCodeUnit(text.codeUnitAt(anchor))) {
    var next = anchor;
    while (next < text.length &&
        isReadingTextLineBreakCodeUnit(text.codeUnitAt(next))) {
      next++;
    }
    if (next < text.length) {
      anchor = next;
    } else {
      var previous = anchor;
      while (previous >= 0 &&
          isReadingTextLineBreakCodeUnit(text.codeUnitAt(previous))) {
        previous--;
      }
      if (previous < 0) return TextRange.empty;
      anchor = previous;
    }
  }

  var start = anchor;
  while (start > 0 &&
      !isReadingTextLineBreakCodeUnit(text.codeUnitAt(start - 1))) {
    start--;
  }

  var end = anchor;
  while (end < text.length &&
      !isReadingTextLineBreakCodeUnit(text.codeUnitAt(end))) {
    end++;
  }

  while (start < end &&
      isReadingTextEdgeWhitespaceCodeUnit(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start &&
      isReadingTextEdgeWhitespaceCodeUnit(text.codeUnitAt(end - 1))) {
    end--;
  }

  return TextRange(start: start, end: end);
}

int readingParagraphStartForOffset(String text, int offset) {
  final range = paragraphRangeForOffset(text, offset);
  if (range.isValid && !range.isCollapsed) return range.start;
  return skipReadingTextEdgeWhitespace(text, offset);
}

bool isReadingTextLineBreakCodeUnit(int code) =>
    code == 0x0a ||
    code == 0x0d ||
    code == 0x85 ||
    code == 0x2028 ||
    code == 0x2029;

bool isReadingTextEdgeWhitespaceCodeUnit(int code) {
  return code <= 0x20 ||
      code == 0x7f ||
      code == 0x85 ||
      code == 0xa0 ||
      code == 0x1680 ||
      code == 0x180e ||
      (code >= 0x2000 && code <= 0x200f) ||
      code == 0x2028 ||
      code == 0x2029 ||
      code == 0x202f ||
      code == 0x205f ||
      code == 0x2060 ||
      code == 0x3000 ||
      code == 0xfeff;
}

int skipReadingTextEdgeWhitespace(String text, int offset) {
  var start = offset.clamp(0, text.length).toInt();
  while (start < text.length &&
      isReadingTextEdgeWhitespaceCodeUnit(text.codeUnitAt(start))) {
    start++;
  }
  return start;
}
