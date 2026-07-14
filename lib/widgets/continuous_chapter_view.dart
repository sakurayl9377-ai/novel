import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/chapter.dart';

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
  });

  final List<Chapter> chapters;
  final int initialChapterIndex;
  final String initialContent;
  final int initialTextOffset;
  final Future<String> Function(int chapterIndex) loadChapterContent;
  final Widget Function(Chapter chapter, int chapterIndex, String content)
  sectionBuilder;
  final int? activeChapterIndex;
  final int? activeTextOffset;
  final void Function(int chapterIndex, String content, int charPosition)?
  onReadingPositionChanged;
  final void Function(int chapterIndex, String content, int charPosition)?
  onReadingPositionSettled;
  final VoidCallback? onTap;

  @override
  State<ContinuousChapterView> createState() => _ContinuousChapterViewState();
}

class _ContinuousChapterViewState extends State<ContinuousChapterView> {
  static const double _loadAheadExtent = 640;
  static const double _readingAnchorFraction = 0.38;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final Map<int, String> _contents = <int, String>{};
  final Map<int, GlobalKey> _sectionKeys = <int, GlobalKey>{};
  final Set<int> _loadingIndexes = <int>{};
  final Set<int> _failedIndexes = <int>{};

  bool _didRestoreInitialPosition = false;
  int? _lastReportedChapterIndex;
  int? _lastReportedCharPosition;

  List<int> get _loadedIndexes {
    final indexes = _contents.keys.toList()..sort();
    return indexes;
  }

  @override
  void initState() {
    super.initState();
    final initialIndex = _safeChapterIndex(widget.initialChapterIndex);
    _contents[initialIndex] = widget.initialContent;
    _sectionKeys[initialIndex] = GlobalKey();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreInitialPosition();
      _preloadNeighbours(initialIndex);
    });
  }

  @override
  void didUpdateWidget(covariant ContinuousChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
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
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  int _safeChapterIndex(int index) {
    if (widget.chapters.isEmpty) return 0;
    return index.clamp(0, widget.chapters.length - 1).toInt();
  }

  GlobalKey _keyFor(int chapterIndex) {
    return _sectionKeys.putIfAbsent(chapterIndex, GlobalKey.new);
  }

  void _preloadNeighbours(int chapterIndex) {
    unawaited(_loadChapter(chapterIndex - 1));
    unawaited(_loadChapter(chapterIndex + 1));
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
    if (mounted) setState(() {});

    final anchorIndex = _anchoredChapterIndex() ?? widget.initialChapterIndex;
    final beforeTop = _sectionTopFor(anchorIndex);
    final beforeOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;

    try {
      final content = await widget.loadChapterContent(chapterIndex);
      if (!mounted) return;
      if (content.isEmpty) {
        _failedIndexes.add(chapterIndex);
        return;
      }

      setState(() {
        _contents[chapterIndex] = content;
        _keyFor(chapterIndex);
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        // Inserting a previous chapter must not make the visible text jump.
        // Compensate only for the height inserted before the reading anchor.
        final afterTop = _sectionTopFor(anchorIndex);
        if (beforeTop != null && afterTop != null) {
          final delta = afterTop - beforeTop;
          if (delta.abs() >= 0.5) {
            final position = _scrollController.position;
            final target = (beforeOffset + delta).clamp(
              0.0,
              position.maxScrollExtent,
            );
            _scrollController.jumpTo(target);
          }
        }
        _loadNearEdges(_scrollController.position);
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
        (position.pixels +
                sectionTop +
                sectionHeight * ratio -
                position.viewportDimension * _readingAnchorFraction)
            .clamp(0.0, position.maxScrollExtent);
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

    final position = _scrollController.position;
    final ratio = (textOffset / content.length).clamp(0.0, 1.0);
    final target =
        (position.pixels +
                sectionTop +
                sectionHeight * ratio -
                position.viewportDimension * _readingAnchorFraction)
            .clamp(0.0, position.maxScrollExtent)
            .toDouble();
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  double? _sectionTopFor(int chapterIndex) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    final section = _sectionKeys[chapterIndex]?.currentContext
        ?.findRenderObject();
    if (viewport is! RenderBox || section is! RenderBox || !section.hasSize) {
      return null;
    }
    return section.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  double? _sectionHeightFor(int chapterIndex) {
    final section = _sectionKeys[chapterIndex]?.currentContext
        ?.findRenderObject();
    if (section is! RenderBox || !section.hasSize) return null;
    return section.size.height;
  }

  int? _anchoredChapterIndex() {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final anchor = viewport.size.height * _readingAnchorFraction;
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
        viewport is! RenderBox) {
      return;
    }

    final anchor = viewport.size.height * _readingAnchorFraction;
    final ratio = ((anchor - top) / height).clamp(0.0, 1.0);
    final charPosition = (content.length * ratio).round();
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

  void _loadNearEdges(ScrollMetrics metrics) {
    final loaded = _loadedIndexes;
    if (loaded.isEmpty) return;
    if (metrics.pixels <= _loadAheadExtent) {
      unawaited(_loadChapter(loaded.first - 1));
    }
    if (metrics.maxScrollExtent - metrics.pixels <= _loadAheadExtent) {
      unawaited(_loadChapter(loaded.last + 1));
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    _loadNearEdges(notification.metrics);
    if (notification is ScrollUpdateNotification) {
      _reportReadingPosition(settled: false);
    } else if (notification is ScrollEndNotification ||
        (notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle)) {
      _reportReadingPosition(settled: true);
    }
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: failed
            ? TextButton.icon(
                onPressed: () => unawaited(_loadChapter(target)),
                icon: const Icon(Icons.refresh),
                label: const Text('章节加载失败，点击重试'),
              )
            : SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: loading ? null : Colors.transparent,
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _loadedIndexes;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onTap,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: SizedBox.expand(
          key: _viewportKey,
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildEdgeLoader(before: true),
                for (final chapterIndex in loaded)
                  Container(
                    key: _keyFor(chapterIndex),
                    child: widget.sectionBuilder(
                      widget.chapters[chapterIndex],
                      chapterIndex,
                      _contents[chapterIndex]!,
                    ),
                  ),
                _buildEdgeLoader(before: false),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
