import 'dart:collection';

import 'package:flutter/material.dart';

/// Builds reader text spans without changing the canonical character offsets.
///
/// Paragraph spacing is represented by styling the second newline in the
/// formatter's `\n\n` separator. Leading ideographic-space markers are painted
/// as transparent CJK glyphs instead of whitespace, so SkParagraph cannot trim
/// the first-line indent at a visual line boundary. Both substitutions keep a
/// one-code-unit-for-one-code-unit mapping with the persisted chapter text,
/// which keeps bookmarks, TTS and reading progress stable while typography
/// changes.
abstract final class NovelTextLayout {
  // Match the continuous reader's five-chapter working set. Keeping more
  // String keys here would retain chapters after the viewport evicts them.
  static const int _maxGapCacheEntries = 5;
  static final LinkedHashMap<String, _NovelTextMarkers> _markerCache =
      LinkedHashMap<String, _NovelTextMarkers>();

  static const int _lineFeed = 0x0A;
  static const int _ideographicSpace = 0x3000;
  // A normal CJK glyph has a stable one-em advance and, unlike whitespace,
  // cannot be discarded at the beginning of a visual line. It is transparent
  // in the rendered style and exposes the original spaces to semantics.
  static const String _indentAdvanceGlyph = '\u56FD';

  @visibleForTesting
  static int get cachedTextCount => _markerCache.length;

  static TextSpan buildSpan({
    required String text,
    required TextStyle style,
    required double paragraphSpacing,
    int globalStartOffset = 0,
    int? previousCodeUnit,
    TextRange highlightRange = TextRange.empty,
    Color? highlightColor,
  }) {
    if (text.isEmpty) return TextSpan(style: style, text: '');

    final gapFontSize = ((style.fontSize ?? 18) * paragraphSpacing)
        .clamp(1.0, 36.0)
        .toDouble();
    final markers = _markersFor(text);
    final gapOffsets = <int>{...markers.paragraphGapOffsets};
    if (previousCodeUnit == _lineFeed && text.codeUnitAt(0) == _lineFeed) {
      gapOffsets.add(0);
    }
    final boundaries = <int>{0, text.length};
    for (final offset in gapOffsets) {
      boundaries
        ..add(offset)
        ..add((offset + 1).clamp(0, text.length));
    }
    for (final range in markers.indentRanges) {
      boundaries
        ..add(range.start)
        ..add(range.end);
    }
    if (highlightRange.isValid) {
      boundaries
        ..add((highlightRange.start - globalStartOffset).clamp(0, text.length))
        ..add((highlightRange.end - globalStartOffset).clamp(0, text.length));
    }
    final ordered = boundaries.toList()..sort();
    final children = <InlineSpan>[];
    var indentRangeIndex = 0;
    for (var index = 0; index < ordered.length - 1; index++) {
      final start = ordered[index];
      final end = ordered[index + 1];
      if (end <= start) continue;
      while (indentRangeIndex < markers.indentRanges.length &&
          markers.indentRanges[indentRangeIndex].end <= start) {
        indentRangeIndex++;
      }
      final isIndent =
          indentRangeIndex < markers.indentRanges.length &&
          markers.indentRanges[indentRangeIndex].start <= start &&
          end <= markers.indentRanges[indentRangeIndex].end;
      final isGap = gapOffsets.contains(start) && end == start + 1;
      final isHighlighted = _isHighlighted(
        globalStartOffset + start,
        highlightRange,
      );
      var segmentStyle = isGap
          ? style.copyWith(fontSize: gapFontSize, height: 1)
          : style;
      if (isHighlighted && highlightColor != null) {
        segmentStyle = segmentStyle.copyWith(backgroundColor: highlightColor);
      }
      if (isIndent) {
        segmentStyle = _transparentAdvanceStyle(segmentStyle);
      }
      final sourceSegment = text.substring(start, end);
      children.add(
        TextSpan(
          text: isIndent
              ? List<String>.filled(
                  end - start,
                  _indentAdvanceGlyph,
                  growable: false,
                ).join()
              : sourceSegment,
          // Accessibility and toPlainText still see the canonical source
          // markers, while the paragraph engine lays out non-whitespace glyphs.
          semanticsLabel: isIndent ? sourceSegment : null,
          style: segmentStyle,
        ),
      );
    }
    return TextSpan(style: style, children: children);
  }

  static _NovelTextMarkers _markersFor(String text) {
    final cached = _markerCache.remove(text);
    if (cached != null) {
      _markerCache[text] = cached;
      return cached;
    }

    final gapOffsets = <int>[];
    var searchFrom = 0;
    while (searchFrom < text.length - 1) {
      final separator = text.indexOf('\n\n', searchFrom);
      if (separator < 0) break;
      gapOffsets.add(separator + 1);
      searchFrom = separator + 2;
    }

    final indentRanges = <TextRange>[];
    var paragraphStart = 0;
    while (paragraphStart < text.length) {
      var indentEnd = paragraphStart;
      while (indentEnd < text.length &&
          indentEnd < paragraphStart + 2 &&
          text.codeUnitAt(indentEnd) == _ideographicSpace) {
        indentEnd++;
      }
      if (indentEnd > paragraphStart) {
        indentRanges.add(TextRange(start: paragraphStart, end: indentEnd));
      }

      final nextLineBreak = text.indexOf('\n', paragraphStart);
      if (nextLineBreak < 0) break;
      paragraphStart = nextLineBreak + 1;
      while (paragraphStart < text.length &&
          text.codeUnitAt(paragraphStart) == _lineFeed) {
        paragraphStart++;
      }
    }

    final immutable = _NovelTextMarkers(
      paragraphGapOffsets: List<int>.unmodifiable(gapOffsets),
      indentRanges: List<TextRange>.unmodifiable(indentRanges),
    );
    _markerCache[text] = immutable;
    while (_markerCache.length > _maxGapCacheEntries) {
      _markerCache.remove(_markerCache.keys.first);
    }
    return immutable;
  }

  static TextStyle _transparentAdvanceStyle(TextStyle style) {
    if (style.foreground != null) {
      return style.copyWith(
        foreground: Paint()..color = Colors.transparent,
        shadows: const <Shadow>[],
        decoration: TextDecoration.none,
      );
    }
    return style.copyWith(
      color: Colors.transparent,
      shadows: const <Shadow>[],
      decoration: TextDecoration.none,
    );
  }

  static bool _isHighlighted(int offset, TextRange range) {
    return range.isValid && offset >= range.start && offset < range.end;
  }
}

@immutable
class _NovelTextMarkers {
  const _NovelTextMarkers({
    required this.paragraphGapOffsets,
    required this.indentRanges,
  });

  final List<int> paragraphGapOffsets;
  final List<TextRange> indentRanges;
}
