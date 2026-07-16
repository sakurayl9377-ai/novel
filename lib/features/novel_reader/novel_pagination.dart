import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'novel_text_layout.dart';

@immutable
class NovelPageSlice {
  const NovelPageSlice({required this.startOffset, required this.endOffset});

  final int startOffset;
  final int endOffset;

  int get length => endOffset - startOffset;

  String textOf(String content) => content.substring(startOffset, endOffset);

  @override
  bool operator ==(Object other) {
    return other is NovelPageSlice &&
        other.startOffset == startOffset &&
        other.endOffset == endOffset;
  }

  @override
  int get hashCode => Object.hash(startOffset, endOffset);
}

@immutable
class NovelPaginationResult {
  const NovelPaginationResult({required this.pages, required this.textSize});

  final List<NovelPageSlice> pages;
  final int textSize;

  int pageForOffset(int offset) {
    if (pages.isEmpty || offset <= 0) return 0;
    final target = offset.clamp(0, textSize).toInt();
    var low = 0;
    var high = pages.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final page = pages[middle];
      if (target < page.startOffset) {
        high = middle - 1;
      } else if (target >= page.endOffset && middle < pages.length - 1) {
        low = middle + 1;
      } else {
        return middle;
      }
    }
    return low.clamp(0, pages.length - 1).toInt();
  }
}

/// TextPainter-backed pagination that only cuts at visual line boundaries.
abstract final class NovelPaginationEngine {
  static const int _maxCachedLayouts = 5;
  static final LinkedHashMap<_PaginationCacheKey, NovelPaginationResult>
  _layoutCache = LinkedHashMap<_PaginationCacheKey, NovelPaginationResult>();

  @visibleForTesting
  static int get cachedLayoutCount => _layoutCache.length;

  static NovelPaginationResult paginate({
    required String content,
    required double width,
    required double height,
    required TextStyle style,
    required double paragraphSpacing,
    TextDirection textDirection = TextDirection.ltr,
    TextAlign textAlign = TextAlign.start,
    TextScaler textScaler = TextScaler.noScaling,
    Locale? locale,
    double firstPageReservedHeight = 0,
  }) {
    if (content.isEmpty) {
      return const NovelPaginationResult(
        pages: <NovelPageSlice>[NovelPageSlice(startOffset: 0, endOffset: 0)],
        textSize: 0,
      );
    }
    final safeWidth = math.max(1.0, width);
    final safeHeight = math.max(1.0, height);
    final cacheKey = _PaginationCacheKey(
      content: content,
      width: safeWidth,
      height: safeHeight,
      style: style,
      paragraphSpacing: paragraphSpacing,
      textDirection: textDirection,
      textAlign: textAlign,
      textScaler: textScaler,
      locale: locale,
      firstPageReservedHeight: firstPageReservedHeight,
    );
    final cached = _layoutCache.remove(cacheKey);
    if (cached != null) {
      _layoutCache[cacheKey] = cached;
      return cached;
    }
    final painter = TextPainter(
      text: NovelTextLayout.buildSpan(
        text: content,
        style: style,
        paragraphSpacing: paragraphSpacing,
      ),
      textDirection: textDirection,
      textAlign: textAlign,
      textScaler: textScaler,
      locale: locale,
    )..layout(maxWidth: safeWidth);

    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) {
      return NovelPaginationResult(
        pages: <NovelPageSlice>[
          NovelPageSlice(startOffset: 0, endOffset: content.length),
        ],
        textSize: content.length,
      );
    }

    // Walk logical line boundaries directly. The previous implementation
    // converted every line metric back through a screen coordinate and then
    // queried its boundary, which doubled paragraph-engine work for long
    // chapters and blocked the UI isolate during first pagination.
    final lineStarts = <int>[];
    var probeOffset = 0;
    var previous = -1;
    for (var lineIndex = 0; lineIndex < metrics.length; lineIndex++) {
      var boundary = painter.getLineBoundary(
        TextPosition(
          offset: probeOffset.clamp(0, content.length),
          affinity: TextAffinity.downstream,
        ),
      );
      if (boundary.start <= previous && previous < content.length) {
        final nextProbe = math.max(probeOffset + 1, boundary.end);
        boundary = painter.getLineBoundary(
          TextPosition(
            offset: nextProbe.clamp(0, content.length),
            affinity: TextAffinity.downstream,
          ),
        );
      }
      var start = boundary.start.clamp(0, content.length).toInt();
      if (start <= previous) {
        start = _nextDistinctLineStart(painter, content.length, previous);
      }
      lineStarts.add(start);
      previous = start;
      probeOffset = math.max(start + 1, boundary.end).clamp(0, content.length);
    }

    final pageStarts = <int>[0];
    var firstLineOnPage = 0;
    var usedHeight = 0.0;
    for (var lineIndex = 0; lineIndex < metrics.length; lineIndex++) {
      final reserved = pageStarts.length == 1 ? firstPageReservedHeight : 0.0;
      final available = math.max(1.0, safeHeight - reserved);
      final lineHeight = math.max(1.0, metrics[lineIndex].height);
      final pageHasLine = lineIndex > firstLineOnPage;
      if (pageHasLine && usedHeight + lineHeight > available + 0.01) {
        final nextStart = lineStarts[lineIndex]
            .clamp(pageStarts.last + 1, content.length)
            .toInt();
        if (nextStart > pageStarts.last && nextStart < content.length) {
          pageStarts.add(nextStart);
        }
        firstLineOnPage = lineIndex;
        usedHeight = 0;
      }
      usedHeight += lineHeight;
    }

    final pages = <NovelPageSlice>[];
    for (var index = 0; index < pageStarts.length; index++) {
      final start = pageStarts[index];
      final end = index + 1 < pageStarts.length
          ? pageStarts[index + 1]
          : content.length;
      if (end >= start) {
        pages.add(NovelPageSlice(startOffset: start, endOffset: end));
      }
    }
    final result = NovelPaginationResult(
      pages: List<NovelPageSlice>.unmodifiable(pages),
      textSize: content.length,
    );
    _layoutCache[cacheKey] = result;
    while (_layoutCache.length > _maxCachedLayouts) {
      _layoutCache.remove(_layoutCache.keys.first);
    }
    return result;
  }

  static int _nextDistinctLineStart(
    TextPainter painter,
    int textLength,
    int previous,
  ) {
    var probeOffset = (previous + 1).clamp(0, textLength).toInt();
    while (probeOffset < textLength) {
      final boundary = painter.getLineBoundary(
        TextPosition(offset: probeOffset, affinity: TextAffinity.downstream),
      );
      if (boundary.start > previous) return boundary.start;
      final next = math.max(probeOffset + 1, boundary.end);
      if (next <= probeOffset) break;
      probeOffset = next.clamp(0, textLength).toInt();
    }
    return textLength;
  }
}

@immutable
class _PaginationCacheKey {
  const _PaginationCacheKey({
    required this.content,
    required this.width,
    required this.height,
    required this.style,
    required this.paragraphSpacing,
    required this.textDirection,
    required this.textAlign,
    required this.textScaler,
    required this.locale,
    required this.firstPageReservedHeight,
  });

  final String content;
  final double width;
  final double height;
  final TextStyle style;
  final double paragraphSpacing;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final TextScaler textScaler;
  final Locale? locale;
  final double firstPageReservedHeight;

  @override
  bool operator ==(Object other) {
    return other is _PaginationCacheKey &&
        other.content == content &&
        other.width == width &&
        other.height == height &&
        other.style == style &&
        other.paragraphSpacing == paragraphSpacing &&
        other.textDirection == textDirection &&
        other.textAlign == textAlign &&
        other.textScaler == textScaler &&
        other.locale == locale &&
        other.firstPageReservedHeight == firstPageReservedHeight;
  }

  @override
  int get hashCode => Object.hash(
    content,
    width,
    height,
    style,
    paragraphSpacing,
    textDirection,
    textAlign,
    textScaler,
    locale,
    firstPageReservedHeight,
  );
}
