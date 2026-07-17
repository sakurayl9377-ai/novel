import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../models/chapter.dart';

int estimateTextOffsetFromSection({
  required int contentLength,
  required double sectionTop,
  required double sectionHeight,
  required double viewportAnchor,
}) {
  if (contentLength <= 0 || sectionHeight <= 0) return 0;
  final ratio = ((viewportAnchor - sectionTop) / sectionHeight).clamp(0.0, 1.0);
  return (contentLength * ratio).round().clamp(0, contentLength).toInt();
}

class ContinuousChapterViewController {
  _ContinuousChapterViewState? _state;

  Future<bool> moveByViewport(int direction) async {
    return await _state?._moveByViewport(direction) ?? false;
  }

  ({int chapterIndex, String content, int charPosition})? captureAnchor() =>
      _state?._captureAnchor();

  void _attach(_ContinuousChapterViewState state) => _state = state;

  void _detach(_ContinuousChapterViewState state) {
    if (identical(_state, state)) _state = null;
  }
}

/// A scroll reader which keeps neighbouring chapters in one continuous list.
///
/// It deliberately never changes the scroll position to jump to another
/// chapter.  Previous and following chapters are loaded before the reader
/// reaches an edge, so readers can simply keep scrolling in either direction.
class ContinuousChapterView extends StatefulWidget {
  const ContinuousChapterView({
    super.key,
    required this.chapters,
    required this.initialChapterIndex,
    required this.initialContent,
    required this.initialTextOffset,
    required this.loadChapterContent,
    required this.sectionBuilder,
    this.activeChapterIndex,
    this.activeTextOffset,
    this.onReadingPositionChanged,
    this.onReadingPositionSettled,
    this.onTap,
    this.autoReadPixelsPerSecond = 0,
    this.controller,
    this.layoutKey,
  });

  final List<Chapter> chapters;
  final int initialChapterIndex;
  final String initialContent;
  final int initialTextOffset;
  final Future<String> Function(int chapterIndex) loadChapterContent;
  final Widget Function(
    Chapter chapter,
    int chapterIndex,
    String content,
    Key textKey,
  )
  sectionBuilder;
  final int? activeChapterIndex;
  final int? activeTextOffset;
  final void Function(int chapterIndex, String content, int charPosition)?
  onReadingPositionChanged;
  final void Function(int chapterIndex, String content, int charPosition)?
  onReadingPositionSettled;
  final VoidCallback? onTap;
  final double autoReadPixelsPerSecond;
  final ContinuousChapterViewController? controller;
  final Object? layoutKey;

  @override
  State<ContinuousChapterView> createState() => _ContinuousChapterViewState();
}

class _ContinuousChapterViewState extends State<ContinuousChapterView> {
  static const double _loadAheadExtent = 640;
  static const double _sliverCacheExtent = 280;
  static const double _readingAnchorFraction = 0.38;
  static const int _liveReportIntervalMs = 80;
  static const int _retainedChapterRadius = 2;
  static const int _maxRetainedChapters = _retainedChapterRadius * 2 + 1;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final SplayTreeMap<int, String> _contents = SplayTreeMap<int, String>();
  final Map<int, GlobalKey> _sectionKeys = <int, GlobalKey>{};
  final Map<int, GlobalKey> _textKeys = <int, GlobalKey>{};
  final Map<int, double> _sectionExtents = <int, double>{};
  final Set<int> _loadingIndexes = <int>{};
  final Set<int> _failedIndexes = <int>{};

  bool _didRestoreInitialPosition = false;
  bool _isUserScrollGesture = false;
  bool _allowPreviousChapterLoad = false;
  bool _revealPreviousEndingAfterLoad = false;
  bool _postLayoutEdgeCheckScheduled = false;
  int? _lastReportedChapterIndex;
  int? _lastReportedCharPosition;
  int _lastLiveReportAtMs = 0;
  late final Ticker _autoReadTicker;
  Duration _lastAutoReadElapsed = Duration.zero;

  Iterable<int> get _loadedIndexes => _contents.keys;

  ({int chapterIndex, String content, int charPosition})? _captureAnchor() {
    if (!_scrollController.hasClients) return null;
    final chapterIndex = _anchoredChapterIndex();
    if (chapterIndex == null) return null;
    final content = _contents[chapterIndex];
    if (content == null || content.isEmpty) return null;
    final anchor =
        _scrollController.position.viewportDimension * _readingAnchorFraction;
    final top = _sectionTopFor(chapterIndex);
    final height = _sectionHeightFor(chapterIndex);
    final charPosition =
        _textOffsetAtViewportAnchor(chapterIndex, content, anchor) ??
        (top != null && height != null
            ? estimateTextOffsetFromSection(
                contentLength: content.length,
                sectionTop: top,
                sectionHeight: height,
                viewportAnchor: anchor,
              )
            : (_lastReportedCharPosition ?? 0));
    return (
      chapterIndex: chapterIndex,
      content: content,
      charPosition: charPosition.clamp(0, content.length).toInt(),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _autoReadTicker = Ticker(_handleAutoReadTick);
    final initialIndex = _safeChapterIndex(widget.initialChapterIndex);
    _contents[initialIndex] = widget.initialContent;
    _sectionKeys[initialIndex] = GlobalKey();
    _textKeys[initialIndex] = GlobalKey();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreInitialPosition();
      // A fresh chapter should start cleanly at its own heading.  The
      // previous chapter is loaded only after the reader intentionally swipes
      // upward toward it; otherwise its ending appears above every new start.
      _preloadNextChapter(initialIndex);
      _syncAutoReadTicker();
    });
  }

  @override
  void didUpdateWidget(covariant ContinuousChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    // A new reader session is represented by a different key.  This branch
    // only keeps the current content in sync while the same session is alive.
    final initialIndex = _safeChapterIndex(widget.initialChapterIndex);
    if (_contents.length == 1 &&
        _contents.containsKey(initialIndex) &&
        oldWidget.initialContent != widget.initialContent) {
      _contents[initialIndex] = widget.initialContent;
    }
    if (oldWidget.activeChapterIndex != widget.activeChapterIndex ||
        oldWidget.activeTextOffset != widget.activeTextOffset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToActiveText();
      });
    }
    if (oldWidget.autoReadPixelsPerSecond != widget.autoReadPixelsPerSecond) {
      _syncAutoReadTicker();
    }
    if (oldWidget.layoutKey != widget.layoutKey) {
      _preserveAnchorAcrossLayoutChange();
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _autoReadTicker.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<bool> _moveByViewport(int direction) async {
    if (direction == 0 || !_scrollController.hasClients) return false;
    final position = _scrollController.position;
    if (direction < 0 && position.pixels <= position.minScrollExtent + 1) {
      _allowPreviousChapterLoad = true;
      _revealPreviousEndingAfterLoad = true;
      final first = _contents.isEmpty ? 0 : _contents.firstKey()!;
      await _loadChapter(first - 1);
      await WidgetsBinding.instance.endOfFrame;
    } else if (direction > 0 &&
        position.pixels >= position.maxScrollExtent - 1) {
      final last = _contents.isEmpty ? 0 : _contents.lastKey()!;
      await _loadChapter(last + 1);
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || !_scrollController.hasClients) return false;
    final updated = _scrollController.position;
    final target =
        (updated.pixels + updated.viewportDimension * 0.88 * direction.sign)
            .clamp(updated.minScrollExtent, updated.maxScrollExtent)
            .toDouble();
    if ((target - updated.pixels).abs() < 1) return false;
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    _reportReadingPosition(settled: true);
    return true;
  }

  void _preserveAnchorAcrossLayoutChange() {
    if (!_scrollController.hasClients) return;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final chapterIndex = _anchoredChapterIndex();
    if (viewport is! RenderBox || chapterIndex == null) return;
    final content = _contents[chapterIndex];
    if (content == null || content.isEmpty) return;
    final anchor =
        _scrollController.position.viewportDimension * _readingAnchorFraction;
    final textOffset = _textOffsetAtViewportAnchor(
      chapterIndex,
      content,
      anchor,
    );
    if (textOffset == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target = _scrollTargetForTextOffset(
        chapterIndex,
        content,
        textOffset,
        position,
      );
      if (target == null || (target - position.pixels).abs() < 0.5) return;
      _scrollController.jumpTo(target);
      _reportReadingPosition(settled: true);
    });
  }

  void _syncAutoReadTicker() {
    final shouldRun = widget.autoReadPixelsPerSecond > 0;
    if (shouldRun && !_autoReadTicker.isActive) {
      _lastAutoReadElapsed = Duration.zero;
      _autoReadTicker.start();
    } else if (!shouldRun && _autoReadTicker.isActive) {
      _autoReadTicker.stop();
      _lastAutoReadElapsed = Duration.zero;
      if (_scrollController.hasClients) {
        _reportReadingPosition(settled: true);
      }
    }
  }

  void _handleAutoReadTick(Duration elapsed) {
    if (!mounted ||
        widget.autoReadPixelsPerSecond <= 0 ||
        _isUserScrollGesture ||
        !_scrollController.hasClients) {
      _lastAutoReadElapsed = elapsed;
      return;
    }
    if (_lastAutoReadElapsed == Duration.zero) {
      _lastAutoReadElapsed = elapsed;
      return;
    }
    final deltaSeconds =
        (elapsed - _lastAutoReadElapsed).inMicroseconds / 1000000.0;
    _lastAutoReadElapsed = elapsed;
    if (deltaSeconds <= 0 || deltaSeconds > 0.25) return;

    final position = _scrollController.position;
    final target =
        (position.pixels + widget.autoReadPixelsPerSecond * deltaSeconds)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
    if ((target - position.pixels).abs() < 0.05) return;
    _scrollController.jumpTo(target);
    _reportLiveReadingPosition();
    _loadNearEdges(position);
  }

  int _safeChapterIndex(int index) {
    if (widget.chapters.isEmpty) return 0;
    return index.clamp(0, widget.chapters.length - 1).toInt();
  }

  GlobalKey _keyFor(int chapterIndex) {
    return _sectionKeys.putIfAbsent(chapterIndex, GlobalKey.new);
  }

  GlobalKey _textKeyFor(int chapterIndex) {
    return _textKeys.putIfAbsent(chapterIndex, GlobalKey.new);
  }

  void _preloadNextChapter(int chapterIndex) {
    unawaited(_loadChapter(chapterIndex + 1));
  }

  bool _isAdjacentToLoadedWindow(int chapterIndex) {
    if (_contents.isEmpty) return false;
    return chapterIndex == _contents.firstKey()! - 1 ||
        chapterIndex == _contents.lastKey()! + 1;
  }

  Set<int> _indexesToEvict({
    required int anchorIndex,
    required int incomingIndex,
  }) {
    final retained = <int>{..._contents.keys, incomingIndex};
    final evicted = retained
        .where(
          (index) =>
              index < anchorIndex - _retainedChapterRadius ||
              index > anchorIndex + _retainedChapterRadius,
        )
        .toSet();
    retained.removeAll(evicted);

    while (retained.length > _maxRetainedChapters) {
      final first = retained.reduce((a, b) => a < b ? a : b);
      final last = retained.reduce((a, b) => a > b ? a : b);
      final firstDistance = (anchorIndex - first).abs();
      final lastDistance = (last - anchorIndex).abs();
      final removeFirst =
          first != anchorIndex &&
          (last == anchorIndex ||
              firstDistance > lastDistance ||
              (firstDistance == lastDistance && incomingIndex > anchorIndex));
      final removed = removeFirst ? first : last;
      retained.remove(removed);
      evicted.add(removed);
    }
    return evicted;
  }

  void _removeChapterState(Iterable<int> chapterIndexes) {
    for (final index in chapterIndexes) {
      _contents.remove(index);
      _sectionKeys.remove(index);
      _textKeys.remove(index);
      _failedIndexes.remove(index);
    }
  }

  Future<void> _loadChapter(int chapterIndex) async {
    if (chapterIndex < 0 ||
        chapterIndex >= widget.chapters.length ||
        _contents.containsKey(chapterIndex) ||
        _loadingIndexes.contains(chapterIndex)) {
      return;
    }

    _loadingIndexes.add(chapterIndex);
    _failedIndexes.remove(chapterIndex);
    final requestAnchorIndex =
        _anchoredChapterIndex() ??
        _safeChapterIndex(widget.initialChapterIndex);
    if (mounted) setState(() {});

    try {
      final content = await widget.loadChapterContent(chapterIndex);
      if (!mounted) return;
      if (content.isEmpty) {
        _failedIndexes.add(chapterIndex);
        return;
      }

      // The reader may have moved while an asynchronous request was in
      // flight.  Discard stale results instead of creating a gap in the
      // continuous chapter window.
      if (!_isAdjacentToLoadedWindow(chapterIndex)) return;

      // Keep the anchor that initiated the asynchronous edge load. Recomputing
      // it after the request completes can reject a valid previous chapter if
      // the retained slivers shifted while the user was still dragging.
      final anchorIndex = requestAnchorIndex
          .clamp(
            chapterIndex - _retainedChapterRadius,
            chapterIndex + _retainedChapterRadius,
          )
          .toInt();
      final beforeTop = _sectionTopFor(anchorIndex);
      final beforeOffset = _scrollController.hasClients
          ? _scrollController.offset
          : 0.0;
      final revealPreviousEnding =
          chapterIndex < anchorIndex && _revealPreviousEndingAfterLoad;
      if (revealPreviousEnding) {
        _revealPreviousEndingAfterLoad = false;
      }
      final evictedIndexes = _indexesToEvict(
        anchorIndex: anchorIndex,
        incomingIndex: chapterIndex,
      );
      final removedBeforeAnchorExtent = evictedIndexes
          .where((index) => index < anchorIndex)
          .fold<double>(
            0,
            (extent, index) => extent + (_sectionExtents[index] ?? 0),
          );

      setState(() {
        _contents[chapterIndex] = content;
        _keyFor(chapterIndex);
        _textKeyFor(chapterIndex);
        _removeChapterState(evictedIndexes);
      });

      var compensatedOffset = beforeOffset;
      if (removedBeforeAnchorExtent > 0 && _scrollController.hasClients) {
        final position = _scrollController.position;
        compensatedOffset = (beforeOffset - removedBeforeAnchorExtent)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
        if ((compensatedOffset - position.pixels).abs() >= 0.5) {
          _scrollController.jumpTo(compensatedOffset);
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        // Inserting a previous chapter must not make the visible text jump.
        // Compensate only for the height inserted before the reading anchor.
        final position = _scrollController.position;
        if (revealPreviousEnding) {
          final previousTop = _sectionTopFor(chapterIndex);
          final previousHeight = _sectionHeightFor(chapterIndex);
          if (previousTop != null && previousHeight != null) {
            final target =
                (position.pixels +
                        previousTop +
                        previousHeight -
                        position.viewportDimension * 0.65)
                    .clamp(0.0, position.maxScrollExtent)
                    .toDouble();
            _scrollController.jumpTo(target);
          }
        } else {
          final afterTop = _sectionTopFor(anchorIndex);
          if (beforeTop != null && afterTop != null) {
            final delta = afterTop - beforeTop;
            if (delta.abs() >= 0.5) {
              final target = (compensatedOffset + delta)
                  .clamp(0.0, position.maxScrollExtent)
                  .toDouble();
              _scrollController.jumpTo(target);
            }
          }
        }
        _loadNearEdges(_scrollController.position);
        if (revealPreviousEnding) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _reportReadingPosition(settled: true);
          });
        }
      });
    } catch (_) {
      if (mounted) _failedIndexes.add(chapterIndex);
    } finally {
      _loadingIndexes.remove(chapterIndex);
      if (mounted) setState(() {});
    }
  }

  void _restoreInitialPosition() {
    if (_didRestoreInitialPosition ||
        !_scrollController.hasClients ||
        widget.initialTextOffset <= 0) {
      _didRestoreInitialPosition = true;
      return;
    }

    final initialIndex = _safeChapterIndex(widget.initialChapterIndex);
    final sectionTop = _sectionTopFor(initialIndex);
    final sectionHeight = _sectionHeightFor(initialIndex);
    final content = _contents[initialIndex];
    if (sectionTop == null || sectionHeight == null || content == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreInitialPosition();
      });
      return;
    }

    final position = _scrollController.position;
    final ratio = (widget.initialTextOffset / content.length).clamp(0.0, 1.0);
    final target =
        _scrollTargetForTextOffset(
          initialIndex,
          content,
          widget.initialTextOffset,
          position,
        ) ??
        (position.pixels +
                sectionTop +
                sectionHeight * ratio -
                position.viewportDimension * _readingAnchorFraction)
            .clamp(0.0, position.maxScrollExtent)
            .toDouble();
    _scrollController.jumpTo(target);
    _didRestoreInitialPosition = true;
  }

  void _scrollToActiveText() {
    final chapterIndex = widget.activeChapterIndex;
    final textOffset = widget.activeTextOffset;
    if (chapterIndex == null ||
        textOffset == null ||
        !_scrollController.hasClients) {
      return;
    }
    final content = _contents[chapterIndex];
    final sectionTop = _sectionTopFor(chapterIndex);
    final sectionHeight = _sectionHeightFor(chapterIndex);
    if (content == null ||
        content.isEmpty ||
        sectionTop == null ||
        sectionHeight == null) {
      return;
    }

    if (_isUserScrollGesture) return;
    final position = _scrollController.position;
    final ratio = (textOffset / content.length).clamp(0.0, 1.0);
    final target =
        _scrollTargetForTextOffset(
          chapterIndex,
          content,
          textOffset,
          position,
        ) ??
        (position.pixels +
                sectionTop +
                sectionHeight * ratio -
                position.viewportDimension * _readingAnchorFraction)
            .clamp(0.0, position.maxScrollExtent)
            .toDouble();
    if ((target - position.pixels).abs() < 2) return;
    unawaited(
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  double? _sectionTopFor(int chapterIndex) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final section = _renderObjectFor(_sectionKeys[chapterIndex]);
    if (viewport is! RenderBox || section is! RenderBox || !section.hasSize) {
      return null;
    }
    return section.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  double? _sectionHeightFor(int chapterIndex) {
    final section = _renderObjectFor(_sectionKeys[chapterIndex]);
    if (section is! RenderBox || !section.hasSize) {
      return _sectionExtents[chapterIndex];
    }
    final height = section.size.height;
    _sectionExtents[chapterIndex] = height;
    return height;
  }

  RenderParagraph? _textRenderFor(int chapterIndex) {
    final render = _renderObjectFor(_textKeys[chapterIndex]);
    return render is RenderParagraph && render.hasSize ? render : null;
  }

  RenderObject? _renderObjectFor(GlobalKey? key) {
    final context = key?.currentContext;
    if (context == null) return null;
    var isActive = true;
    assert(() {
      isActive = context is Element && context.debugIsActive;
      return true;
    }());
    return isActive ? context.findRenderObject() : null;
  }

  double? _scrollTargetForTextOffset(
    int chapterIndex,
    String content,
    int textOffset,
    ScrollPosition position,
  ) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final paragraph = _textRenderFor(chapterIndex);
    if (viewport is! RenderBox || paragraph == null || content.isEmpty) {
      return null;
    }

    final safeOffset = textOffset.clamp(0, content.length).toInt();
    final paragraphTop = paragraph
        .localToGlobal(Offset.zero, ancestor: viewport)
        .dy;
    final caret = paragraph.getOffsetForCaret(
      TextPosition(offset: safeOffset),
      Rect.zero,
    );
    return (position.pixels +
            paragraphTop +
            caret.dy -
            position.viewportDimension * _readingAnchorFraction)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
  }

  int? _textOffsetAtViewportAnchor(
    int chapterIndex,
    String content,
    double anchor,
  ) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final paragraph = _textRenderFor(chapterIndex);
    if (viewport is! RenderBox || paragraph == null || content.isEmpty) {
      return null;
    }

    final paragraphTop = paragraph
        .localToGlobal(Offset.zero, ancestor: viewport)
        .dy;
    final maxY = paragraph.size.height > 0.5
        ? paragraph.size.height - 0.5
        : 0.0;
    final localY = (anchor - paragraphTop).clamp(0.0, maxY).toDouble();
    return paragraph
        .getPositionForOffset(Offset(0, localY))
        .offset
        .clamp(0, content.length)
        .toInt();
  }

  int? _anchoredChapterIndex() {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !_scrollController.hasClients) return null;
    final anchor =
        _scrollController.position.viewportDimension * _readingAnchorFraction;
    int? closestIndex;
    var closestDistance = double.infinity;

    for (final chapterIndex in _loadedIndexes) {
      final top = _sectionTopFor(chapterIndex);
      final height = _sectionHeightFor(chapterIndex);
      if (top == null || height == null || height <= 0) continue;
      final bottom = top + height;
      if (top <= anchor && bottom > anchor) return chapterIndex;

      final distance = top > anchor ? top - anchor : anchor - bottom;
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = chapterIndex;
      }
    }
    return closestIndex;
  }

  void _reportReadingPosition({required bool settled}) {
    final chapterIndex = _anchoredChapterIndex();
    if (chapterIndex == null) return;
    final content = _contents[chapterIndex];
    final top = _sectionTopFor(chapterIndex);
    final height = _sectionHeightFor(chapterIndex);
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (content == null ||
        top == null ||
        height == null ||
        viewport is! RenderBox ||
        !_scrollController.hasClients) {
      return;
    }

    final anchor =
        _scrollController.position.viewportDimension * _readingAnchorFraction;
    final charPosition =
        _textOffsetAtViewportAnchor(chapterIndex, content, anchor) ??
        estimateTextOffsetFromSection(
          contentLength: content.length,
          sectionTop: top,
          sectionHeight: height,
          viewportAnchor: anchor,
        );
    final changed =
        chapterIndex != _lastReportedChapterIndex ||
        charPosition != _lastReportedCharPosition;
    if (changed) {
      _lastReportedChapterIndex = chapterIndex;
      _lastReportedCharPosition = charPosition;
      widget.onReadingPositionChanged?.call(
        chapterIndex,
        content,
        charPosition,
      );
    }
    if (settled) {
      widget.onReadingPositionSettled?.call(
        chapterIndex,
        content,
        charPosition,
      );
    }
  }

  void _reportLiveReadingPosition() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastLiveReportAtMs < _liveReportIntervalMs) return;
    _lastLiveReportAtMs = nowMs;
    _reportReadingPosition(settled: false);
  }

  void _loadNearEdges(ScrollMetrics metrics) {
    final loaded = _loadedIndexes;
    if (loaded.isEmpty) return;
    final anchorIndex =
        _anchoredChapterIndex() ??
        _safeChapterIndex(widget.initialChapterIndex);
    final previousIndex = loaded.first - 1;
    if (_allowPreviousChapterLoad &&
        metrics.pixels <= _loadAheadExtent &&
        previousIndex >= anchorIndex - _retainedChapterRadius) {
      unawaited(_loadChapter(previousIndex));
    }
    final nextIndex = loaded.last + 1;
    if (metrics.maxScrollExtent - metrics.pixels <= _loadAheadExtent &&
        nextIndex <= anchorIndex + _retainedChapterRadius) {
      unawaited(_loadChapter(nextIndex));
    }
  }

  void _requestPreviousFromUserGesture(ScrollMetrics metrics) {
    _allowPreviousChapterLoad = true;
    if (metrics.pixels <= 24) {
      _revealPreviousEndingAfterLoad = true;
    }
  }

  void _schedulePostLayoutEdgeCheck() {
    if (_postLayoutEdgeCheckScheduled) return;
    _postLayoutEdgeCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _postLayoutEdgeCheckScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      _loadNearEdges(_scrollController.position);
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    // Slivers can update their estimated extent while the viewport is in
    // performLayout. Geometry reads (localToGlobal/RenderBox.size) are not
    // legal in that phase, so wait until the render tree is stable.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _schedulePostLayoutEdgeCheck();
      return false;
    }

    // Only a real finger drag is allowed to change the active chapter and
    // saved reading position. Layout changes, chapter prefetch correction,
    // and TTS follow-scroll all dispatch scroll notifications too.
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.idle) {
        if (_isUserScrollGesture) {
          _reportReadingPosition(settled: true);
        }
        _isUserScrollGesture = false;
      } else {
        _isUserScrollGesture = true;
        if (notification.direction == ScrollDirection.forward) {
          _requestPreviousFromUserGesture(notification.metrics);
        }
      }
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _isUserScrollGesture = true;
      if ((notification.scrollDelta ?? 0) < 0) {
        _requestPreviousFromUserGesture(notification.metrics);
      }
      _reportLiveReadingPosition();
    } else if (notification is OverscrollNotification &&
        notification.overscroll < 0) {
      _isUserScrollGesture = true;
      _requestPreviousFromUserGesture(notification.metrics);
    } else if (notification is ScrollEndNotification &&
        (_isUserScrollGesture || notification.dragDetails != null)) {
      _reportReadingPosition(settled: true);
      _isUserScrollGesture = false;
    }
    _loadNearEdges(notification.metrics);
    return false;
  }

  Widget _buildEdgeLoader({required bool before}) {
    final loaded = _loadedIndexes;
    if (loaded.isEmpty) return const SizedBox.shrink();
    final target = before ? loaded.first - 1 : loaded.last + 1;
    if (target < 0 ||
        target >= widget.chapters.length ||
        _contents.containsKey(target)) {
      return const SizedBox(height: 12);
    }

    final loading = _loadingIndexes.contains(target);
    final failed = _failedIndexes.contains(target);
    if (!loading && !failed) return const SizedBox(height: 12);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: failed
            ? TextButton.icon(
                onPressed: () => unawaited(_loadChapter(target)),
                icon: const Icon(Icons.refresh),
                label: const Text('章节加载失败，点击重试'),
              )
            : const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );
  }

  int? _findSliverChildIndex(Key key, List<int> loadedIndexes) {
    if (key == const ValueKey<String>('continuous-edge-before')) return 0;
    if (key == const ValueKey<String>('continuous-edge-after')) {
      return loadedIndexes.length + 1;
    }
    for (var index = 0; index < loadedIndexes.length; index++) {
      if (identical(_sectionKeys[loadedIndexes[index]], key)) {
        return index + 1;
      }
    }
    return null;
  }

  Widget? _buildSliverChild(
    BuildContext context,
    int index,
    List<int> loadedIndexes,
  ) {
    if (index == 0) {
      return KeyedSubtree(
        key: const ValueKey<String>('continuous-edge-before'),
        child: _buildEdgeLoader(before: true),
      );
    }
    if (index == loadedIndexes.length + 1) {
      return KeyedSubtree(
        key: const ValueKey<String>('continuous-edge-after'),
        child: _buildEdgeLoader(before: false),
      );
    }

    final chapterIndex = loadedIndexes[index - 1];
    final content = _contents[chapterIndex];
    if (content == null) return null;
    return RepaintBoundary(
      key: _keyFor(chapterIndex),
      child: widget.sectionBuilder(
        widget.chapters[chapterIndex],
        chapterIndex,
        content,
        _textKeyFor(chapterIndex),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loadedIndexes = _loadedIndexes.toList(growable: false);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onTap,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: SizedBox.expand(
          key: _viewportKey,
          child: CustomScrollView(
            controller: _scrollController,
            // Keep the legacy pixel cache behavior until the new viewport cache
            // API preserves chapter reload anchoring on every supported engine.
            // ignore: deprecated_member_use
            cacheExtent: _sliverCacheExtent,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        _buildSliverChild(context, index, loadedIndexes),
                    childCount: loadedIndexes.length + 2,
                    findChildIndexCallback: (key) =>
                        _findSliverChildIndex(key, loadedIndexes),
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: false,
                    addSemanticIndexes: false,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
