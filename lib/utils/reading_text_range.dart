import 'dart:ui' show TextRange;

TextRange paragraphRangeForOffset(String text, int offset) {
  if (text.isEmpty || offset < 0) return TextRange.empty;

  var anchor = offset.clamp(0, text.length - 1).toInt();
  if (_isLineBreak(text[anchor])) {
    var next = anchor;
    while (next < text.length && _isLineBreak(text[next])) {
      next++;
    }
    if (next < text.length) {
      anchor = next;
    } else {
      var previous = anchor;
      while (previous >= 0 && _isLineBreak(text[previous])) {
        previous--;
      }
      if (previous < 0) return TextRange.empty;
      anchor = previous;
    }
  }

  var start = anchor;
  while (start > 0 && !_isLineBreak(text[start - 1])) {
    start--;
  }

  var end = anchor;
  while (end < text.length && !_isLineBreak(text[end])) {
    end++;
  }

  return TextRange(start: start, end: end);
}

bool _isLineBreak(String char) => char == '\n' || char == '\r';
