import 'dart:async';
import 'dart:collection';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/manga.dart';
import '../screens/manga_screen.dart';

class ContinuousMangaPosition {
  const ContinuousMangaPosition({
    required this.chapterIndex,
    required this.images,
    required this.pageIndex,
    required this.pageOffsetRatio,
    required this.progressPercent,
  });

  final int chapterIndex;
  final List<String> images;
  final int pageIndex;
  final double pageOffsetRatio;
  final int progressPercent;
}

class ContinuousMangaNavigationController {
  _ContinuousMangaViewState? _state;

  bool get isAttached => _state != null;

  Future<bool> goToChapterHead(int chapterIndex) {
    final state = _state;
    if (state == null) return Future<bool>.value(false);
    return state._goToChapterHead(chapterIndex);
  }

  void _attach(_ContinuousMangaViewState state) => _state = state;

  void _detach(_ContinuousMangaViewState state) {
    if (identical(_state, state)) _state = null;
  }
}

class ContinuousMangaView extends StatefulWidget {
  const ContinuousMangaView({
    super.key,
    required this.controller,
    required this.chapters,
    required this.initialChapterIndex,
    required this.initialImages,
    required this.loadChapterImages,
    required this.canLoadChapter,
    this.navigationController,
    this.initialPageAspectRatios = const <int, double>{},
    this.initialScrollProgress,
    this.initialPageIndex = 0,
    this.initialPageOffsetRatio = 0,
    this.onPositionChanged,
    this.onPositionSettled,
    this.pageBuilder,
  });

  final ScrollController controller;
  final List<MangaChapter> chapters;
  final int initialChapterIndex;
  final List<String> initialImages;
  final Map<int, double> initialPageAspectRatios;
  final Future<List<String>> Function(int chapterIndex) loadChapterImages;
  final bool Function(int chapterIndex) canLoadChapter;
  final ContinuousMangaNavigationController? navigationController;
  final double? initialScrollProgress;
  final int initialPageIndex;
  final double initialPageOffsetRatio;
  final ValueChanged<ContinuousMangaPosition>? onPositionChanged;
  final ValueChanged<ContinuousMangaPosition>? onPositionSettled;
  final Widget Function(
    BuildContext context,
    int chapterIndex,
    int pageIndex,
    String imageUrl,
  )?
  pageBuilder;

  @override
  State<ContinuousMangaView> createState() => _ContinuousMangaViewState();
}

class _ContinuousMangaViewState extends State<ContinuousMangaView> {
  static const double _defaultAspectRatio = 0.68;
  static const double _chapterHeaderHeight = 70;
  static const double _chapterBottomGap = 14;
  static const double _loadAheadExtent = 900;
  static const int _reportIntervalMs = 80;
  static const Duration _imageCacheMaxAge = Duration(days: 14);
  static const String _imageCacheName = 'manga_reader_images';

  final SplayTreeMap<int, List<String>> _loaded =
      SplayTreeMap<int, List<String>>();
  final Set<int> _loading = <int>{};
  final Map<(int, int), double> _aspectRatios = <(int, int), double>{};
  final Map<(int, int), double> _pageHeights = <(int, int), double>{};
  final Map<(int, int), double> _pendingAspectRatios = <(int, int), double>{};
  final Map<int, GlobalKey> _chapterHeaderKeys = <int, GlobalKey>{};
  Timer? _aspectRatioFlushTimer;

  double _viewportWidth = 390;
  bool _isUserScrolling = false;
  bool _maintainingScrollOffset = false;
  bool _allowPreviousChapterLoad = false;
  bool _revealPreviousEndingAfterLoad = false;
  bool _didRestore = false;
  int _activeChapterIndex = 0;
  int _lastReportAtMs = 0;
  int? _lastReportedChapter;
  int? _lastReportedPage;
  double? _lastReportedRatio;
  int _navigationGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.navigationController?._attach(this);
    _activeChapterIndex = _safeIndex(widget.initialChapterIndex);
    _loaded[_activeChapterIndex] = List<String>.from(widget.initialImages);
    for (final entry in widget.initialPageAspectRatios.entries) {
      if (entry.value.isFinite && entry.value > 0) {
        _aspectRatios[(_activeChapterIndex, entry.key)] = entry.value;
      }
    }
    widget.controller.addListener(_handleScrollChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreInitialPosition();
      unawaited(_loadAdjacent(_activeChapterIndex + 1, before: false));
    });
  }

  @override
  void dispose() {
    _navigationGeneration++;
    widget.navigationController?._detach(this);
    _aspectRatioFlushTimer?.cancel();
    widget.controller.removeListener(_handleScrollChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ContinuousMangaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.navigationController,
      widget.navigationController,
    )) {
      oldWidget.navigationController?._detach(this);
      widget.navigationController?._attach(this);
    }
  }

  int _safeIndex(int index) {
    if (widget.chapters.isEmpty) return 0;
    return index.clamp(0, widget.chapters.length - 1).toInt();
  }

  Future<bool> _goToChapterHead(int chapterIndex) async {
    if (chapterIndex < 0 ||
        chapterIndex >= widget.chapters.length ||
        !widget.canLoadChapter(chapterIndex)) {
      return false;
    }
    final generation = ++_navigationGeneration;
    var images = _loaded[chapterIndex];
    if (images == null) {
      try {
        images = await widget.loadChapterImages(chapterIndex);
      } catch (_) {
        return false;
      }
      if (!mounted || generation != _navigationGeneration || images.isEmpty) {
        return false;
      }
    }
    if (!mounted || generation != _navigationGeneration) return false;

    final firstLoaded = _loaded.isEmpty ? chapterIndex : _loaded.firstKey()!;
    final lastLoaded = _loaded.isEmpty ? chapterIndex : _loaded.lastKey()!;
    final isAdjacent =
        chapterIndex >= firstLoaded - 1 && chapterIndex <= lastLoaded + 1;
    _maintainingScrollOffset = true;
    setState(() {
      if (!isAdjacent) {
        _loaded.clear();
        _aspectRatios.clear();
        _pageHeights.clear();
        _pendingAspectRatios.clear();
      }
      _loaded[chapterIndex] = List<String>.from(images!);
      _activeChapterIndex = chapterIndex;
      _lastReportedChapter = null;
      _lastReportedPage = null;
      _lastReportedRatio = null;
    });

    await _afterNextFrame();
    if (!mounted ||
        generation != _navigationGeneration ||
        !widget.controller.hasClients) {
      _maintainingScrollOffset = false;
      return false;
    }
    final target = _chapterStart(chapterIndex).clamp(
      widget.controller.position.minScrollExtent,
      widget.controller.position.maxScrollExtent,
    );
    widget.controller.jumpTo(target);
    await _afterNextFrame();
    if (!mounted || generation != _navigationGeneration) return false;
    final headerContext = _chapterHeaderKeys[chapterIndex]?.currentContext;
    if (headerContext != null && headerContext.mounted) {
      await Scrollable.ensureVisible(
        headerContext,
        alignment: 0,
        duration: Duration.zero,
      );
      await _afterNextFrame();
      if (!mounted || generation != _navigationGeneration) return false;
    }
    _maintainingScrollOffset = false;
    _reportChapterHead(chapterIndex);
    unawaited(_loadAdjacent(chapterIndex + 1, before: false));
    _trimAround(chapterIndex);
    return true;
  }

  void _reportChapterHead(int chapterIndex) {
    final images = _loaded[chapterIndex];
    if (images == null || images.isEmpty) return;
    _lastReportedChapter = chapterIndex;
    _lastReportedPage = 0;
    _lastReportedRatio = 0;
    final value = ContinuousMangaPosition(
      chapterIndex: chapterIndex,
      images: images,
      pageIndex: 0,
      pageOffsetRatio: 0,
      progressPercent: 0,
    );
    widget.onPositionChanged?.call(value);
    widget.onPositionSettled?.call(value);
  }

  Future<void> _afterNextFrame() {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => completer.complete());
    WidgetsBinding.instance.scheduleFrame();
    return completer.future;
  }

  void _restoreInitialPosition() {
    if (_didRestore || !widget.controller.hasClients) return;
    final images = _loaded[_activeChapterIndex] ?? const <String>[];
    if (images.isEmpty) return;
    var pageIndex = widget.initialPageIndex.clamp(0, images.length - 1).toInt();
    var pageRatio = widget.initialPageOffsetRatio.clamp(0.0, 1.0).toDouble();
    final progress = widget.initialScrollProgress?.clamp(0.0, 1.0).toDouble();
    if (pageIndex == 0 && pageRatio == 0 && progress != null && progress > 0) {
      final pagePosition = progress * images.length;
      pageIndex = pagePosition.floor().clamp(0, images.length - 1);
      pageRatio = pagePosition - pageIndex;
    }
    final hasSavedPosition =
        pageIndex > 0 || pageRatio > 0 || (progress != null && progress > 0);
    final chapterStart = _chapterStart(_activeChapterIndex);
    final target = hasSavedPosition
        ? chapterStart +
              _chapterHeaderHeight +
              _pageStart(_activeChapterIndex, pageIndex) +
              _estimatedPageHeight(_activeChapterIndex, pageIndex) * pageRatio -
              widget.controller.position.viewportDimension * 0.35
        : chapterStart;
    widget.controller.jumpTo(
      target.clamp(0.0, widget.controller.position.maxScrollExtent),
    );
    _didRestore = true;
    _reportPosition(settled: true, force: true);
  }

  Future<void> _loadAdjacent(int chapterIndex, {required bool before}) async {
    if (chapterIndex < 0 ||
        chapterIndex >= widget.chapters.length ||
        _loaded.containsKey(chapterIndex) ||
        _loading.contains(chapterIndex) ||
        !widget.canLoadChapter(chapterIndex)) {
      return;
    }
    _loading.add(chapterIndex);
    try {
      final images = await widget.loadChapterImages(chapterIndex);
      if (!mounted ||
          images.isEmpty ||
          (chapterIndex - _activeChapterIndex).abs() > 2) {
        return;
      }
      final insertedExtent = before
          ? _chapterHeaderHeight +
                _chapterPageExtent(chapterIndex, images.length) +
                _chapterBottomGap
          : 0.0;
      final revealPreviousEnding = before && _revealPreviousEndingAfterLoad;
      if (revealPreviousEnding) _revealPreviousEndingAfterLoad = false;
      if (before) _maintainingScrollOffset = true;
      setState(() => _loaded[chapterIndex] = List<String>.from(images));
      if (before) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !widget.controller.hasClients) {
            _maintainingScrollOffset = false;
            return;
          }
          if (insertedExtent > 0) {
            final revealOffset = revealPreviousEnding
                ? widget.controller.position.viewportDimension * 0.65
                : 0.0;
            _correctScrollOffset(insertedExtent - revealOffset);
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _maintainingScrollOffset = false;
            if (!_flushPendingAspectRatios()) {
              _reportPosition(settled: !_isUserScrolling, force: true);
            }
          });
        });
      }
    } catch (_) {
      // Adjacent chapter loading is best-effort; the visible chapter remains.
    } finally {
      _loading.remove(chapterIndex);
    }
  }

  void _handleScrollChanged() {
    if (!widget.controller.hasClients) return;
    if (_maintainingScrollOffset) return;
    final position = widget.controller.position;
    if (_allowPreviousChapterLoad && position.pixels <= _loadAheadExtent) {
      unawaited(_loadAdjacent(_loaded.firstKey()! - 1, before: true));
    }
    if (position.maxScrollExtent - position.pixels <= _loadAheadExtent) {
      unawaited(_loadAdjacent(_loaded.lastKey()! + 1, before: false));
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastReportAtMs >= _reportIntervalMs) {
      _lastReportAtMs = nowMs;
      _reportPosition(settled: false);
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is UserScrollNotification) {
      _isUserScrolling = notification.direction != ScrollDirection.idle;
      if (notification.direction == ScrollDirection.forward) {
        _requestPreviousChapter(notification.metrics);
      }
      if (!_isUserScrolling && !_flushPendingAspectRatios()) {
        _reportPosition(settled: true, force: true);
      }
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _isUserScrolling = true;
      if ((notification.scrollDelta ?? 0) < 0) {
        _requestPreviousChapter(notification.metrics);
      }
    } else if (notification is OverscrollNotification &&
        notification.overscroll < 0) {
      _isUserScrolling = true;
      _requestPreviousChapter(notification.metrics);
    } else if (notification is ScrollEndNotification) {
      _isUserScrolling = false;
      if (!_flushPendingAspectRatios()) {
        _reportPosition(settled: true, force: true);
      }
    }
    return false;
  }

  void _requestPreviousChapter(ScrollMetrics metrics) {
    _allowPreviousChapterLoad = true;
    if (metrics.pixels <= 24) _revealPreviousEndingAfterLoad = true;
    if (metrics.pixels <= _loadAheadExtent && _loaded.isNotEmpty) {
      unawaited(_loadAdjacent(_loaded.firstKey()! - 1, before: true));
    }
  }

  void _reportPosition({required bool settled, bool force = false}) {
    if (_maintainingScrollOffset ||
        !widget.controller.hasClients ||
        _loaded.isEmpty) {
      return;
    }
    final anchor =
        widget.controller.offset +
        widget.controller.position.viewportDimension * 0.35;
    var cursor = 0.0;
    for (final entry in _loaded.entries) {
      final chapterIndex = entry.key;
      final images = entry.value;
      final chapterStart = cursor;
      cursor += _chapterHeaderHeight;
      for (var pageIndex = 0; pageIndex < images.length; pageIndex++) {
        final height = _estimatedPageHeight(chapterIndex, pageIndex);
        if (anchor <= cursor + height ||
            (chapterIndex == _loaded.lastKey() &&
                pageIndex == images.length - 1)) {
          final ratio = ((anchor - cursor) / height).clamp(0.0, 1.0).toDouble();
          final progress = images.isEmpty
              ? 0
              : (((pageIndex + ratio) / images.length) * 100)
                    .clamp(0.0, 100.0)
                    .round();
          final changed =
              force ||
              chapterIndex != _lastReportedChapter ||
              pageIndex != _lastReportedPage ||
              (_lastReportedRatio == null ||
                  (ratio - _lastReportedRatio!).abs() >= 0.02);
          if (!changed) return;
          _lastReportedChapter = chapterIndex;
          _lastReportedPage = pageIndex;
          _lastReportedRatio = ratio;
          final value = ContinuousMangaPosition(
            chapterIndex: chapterIndex,
            images: images,
            pageIndex: pageIndex,
            pageOffsetRatio: ratio,
            progressPercent: progress,
          );
          widget.onPositionChanged?.call(value);
          if (settled) widget.onPositionSettled?.call(value);
          if (_activeChapterIndex != chapterIndex) {
            _activeChapterIndex = chapterIndex;
            unawaited(_loadAdjacent(chapterIndex + 1, before: false));
            if (settled) _trimAround(chapterIndex);
          } else if (settled) {
            _trimAround(chapterIndex);
          }
          return;
        }
        cursor += height;
      }
      cursor += _chapterBottomGap;
      if (anchor < chapterStart) break;
    }
  }

  void _trimAround(int activeIndex) {
    final remove = _loaded.keys
        .where((index) => (index - activeIndex).abs() > 2)
        .toList();
    if (remove.isEmpty || !widget.controller.hasClients) return;
    final removedBefore = remove.any((index) => index < activeIndex);
    final removedBeforeExtent = remove
        .where((index) => index < activeIndex)
        .fold<double>(0, (extent, index) {
          final images = _loaded[index] ?? const <String>[];
          return extent +
              _chapterHeaderHeight +
              _chapterPageExtent(index, images.length) +
              _chapterBottomGap;
        });
    if (removedBefore) _maintainingScrollOffset = true;
    setState(() {
      for (final index in remove) {
        _loaded.remove(index);
        _aspectRatios.removeWhere((key, _) => key.$1 == index);
        _pageHeights.removeWhere((key, _) => key.$1 == index);
      }
    });
    if (!removedBefore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.controller.hasClients) {
        _maintainingScrollOffset = false;
        return;
      }
      _correctScrollOffset(-removedBeforeExtent);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maintainingScrollOffset = false;
        if (!_flushPendingAspectRatios()) {
          _reportPosition(settled: true, force: true);
        }
      });
    });
  }

  void _correctScrollOffset(double correction) {
    if (!widget.controller.hasClients || correction.abs() < 1) return;
    final position = widget.controller.position;
    final target = (position.pixels + correction).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final appliedCorrection = target - position.pixels;
    if (appliedCorrection.abs() < 1) return;
    if (_isUserScrolling) {
      position.correctBy(appliedCorrection);
      setState(() {});
    } else {
      widget.controller.jumpTo(target);
    }
  }

  double _chapterStart(int chapterIndex) {
    var offset = 0.0;
    for (final entry in _loaded.entries) {
      if (entry.key == chapterIndex) break;
      offset +=
          _chapterHeaderHeight +
          _chapterPageExtent(entry.key, entry.value.length) +
          _chapterBottomGap;
    }
    return offset;
  }

  double _chapterPageExtent(int chapterIndex, int pageCount) {
    var extent = 0.0;
    for (var i = 0; i < pageCount; i++) {
      extent += _estimatedPageHeight(chapterIndex, i);
    }
    return extent;
  }

  double _pageStart(int chapterIndex, int pageIndex) {
    var offset = 0.0;
    for (var i = 0; i < pageIndex; i++) {
      offset += _estimatedPageHeight(chapterIndex, i);
    }
    return offset;
  }

  double _estimatedPageHeight(int chapterIndex, int pageIndex) {
    final key = (chapterIndex, pageIndex);
    return _pageHeights[key] ??
        _viewportWidth / (_aspectRatios[key] ?? _defaultAspectRatio);
  }

  void _updateAspectRatio(int chapterIndex, int pageIndex, double ratio) {
    if (!ratio.isFinite || ratio <= 0) return;
    final key = (chapterIndex, pageIndex);
    final old = _aspectRatios[key];
    if (old != null && (old - ratio).abs() < 0.01) return;
    _pendingAspectRatios[key] = ratio;
    if (_isUserScrolling || _maintainingScrollOffset) return;
    _aspectRatioFlushTimer ??= Timer(const Duration(milliseconds: 60), () {
      _aspectRatioFlushTimer = null;
      if (!mounted || _isUserScrolling || _maintainingScrollOffset) return;
      _flushPendingAspectRatios();
    });
  }

  bool _flushPendingAspectRatios() {
    if (_pendingAspectRatios.isEmpty) return false;
    _aspectRatioFlushTimer?.cancel();
    _aspectRatioFlushTimer = null;
    final pending = Map<(int, int), double>.from(_pendingAspectRatios);
    _pendingAspectRatios.clear();
    _applyAspectRatios(pending, reportSettled: true);
    return true;
  }

  void _applyAspectRatios(
    Map<(int, int), double> ratios, {
    bool reportSettled = false,
  }) {
    if (!mounted || ratios.isEmpty) return;
    final entries = ratios.entries.toList()
      ..sort((a, b) {
        final chapterOrder = a.key.$1.compareTo(b.key.$1);
        return chapterOrder != 0 ? chapterOrder : a.key.$2.compareTo(b.key.$2);
      });
    final hasClients = widget.controller.hasClients;
    final beforeOffset = hasClients ? widget.controller.offset : 0.0;
    var correctedOffset = beforeOffset;
    var changed = false;
    for (final entry in entries) {
      final key = entry.key;
      if (!_loaded.containsKey(key.$1)) continue;
      final ratio = entry.value;
      final previousRatio = _aspectRatios[key];
      if (previousRatio != null && (previousRatio - ratio).abs() < 0.01) {
        continue;
      }
      final oldHeight = _estimatedPageHeight(key.$1, key.$2);
      final pageStart =
          _chapterStart(key.$1) +
          _chapterHeaderHeight +
          _pageStart(key.$1, key.$2);
      final newHeight = _viewportWidth / ratio;
      if (hasClients && pageStart < correctedOffset && oldHeight > 0) {
        final visibleFraction = pageStart + oldHeight <= correctedOffset
            ? 1.0
            : ((correctedOffset - pageStart) / oldHeight).clamp(0.0, 1.0);
        correctedOffset += (newHeight - oldHeight) * visibleFraction;
      }
      _aspectRatios[key] = ratio;
      _pageHeights[key] = newHeight;
      changed = true;
    }
    if (!changed) {
      if (reportSettled) _reportPosition(settled: true, force: true);
      return;
    }
    final needsOffsetCorrection =
        hasClients && (correctedOffset - beforeOffset).abs() >= 1;
    if (needsOffsetCorrection) _maintainingScrollOffset = true;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.controller.hasClients) {
        _maintainingScrollOffset = false;
        return;
      }
      if (needsOffsetCorrection) {
        _correctScrollOffset(correctedOffset - beforeOffset);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _maintainingScrollOffset = false;
          if (reportSettled) {
            _reportPosition(settled: true, force: true);
          }
        });
        return;
      }
      if (reportSettled) _reportPosition(settled: true, force: true);
    });
  }

  void _updatePageHeight(int chapterIndex, int pageIndex, double height) {
    if (!height.isFinite || height <= 0) return;
    final key = (chapterIndex, pageIndex);
    final old = _pageHeights[key];
    if (old == null || (old - height).abs() < 1) {
      _pageHeights[key] = height;
      return;
    }
    _pageHeights[key] = height;
  }

  List<_ContinuousMangaItem> _items() {
    final items = <_ContinuousMangaItem>[];
    for (final entry in _loaded.entries) {
      items.add(_ContinuousMangaItem.header(entry.key));
      for (var page = 0; page < entry.value.length; page++) {
        items.add(
          _ContinuousMangaItem.page(entry.key, page, entry.value[page]),
        );
      }
      items.add(_ContinuousMangaItem.gap(entry.key));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        final items = _items();
        return NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: ListView.builder(
            controller: widget.controller,
            padding: EdgeInsets.zero,
            scrollCacheExtent: const ScrollCacheExtent.viewport(3),
            itemCount: items.length,
            itemBuilder: (context, itemIndex) {
              final item = items[itemIndex];
              if (item.type == _ContinuousMangaItemType.header) {
                final chapter = widget.chapters[item.chapterIndex];
                return SizedBox(
                  key: _chapterHeaderKeys.putIfAbsent(
                    item.chapterIndex,
                    GlobalKey.new,
                  ),
                  height: _chapterHeaderHeight,
                  child: ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Text(
                        chapter.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              }
              if (item.type == _ContinuousMangaItemType.gap) {
                return const SizedBox(height: _chapterBottomGap);
              }
              final chapter = widget.chapters[item.chapterIndex];
              final key = (item.chapterIndex, item.pageIndex);
              final customPage = widget.pageBuilder?.call(
                context,
                item.chapterIndex,
                item.pageIndex,
                item.url,
              );
              if (customPage != null) {
                return KeyedSubtree(
                  key: ValueKey('${chapter.url}|${item.url}'),
                  child: customPage,
                );
              }
              return _ContinuousMangaImage(
                key: ValueKey('${chapter.url}|${item.url}'),
                url: item.url,
                referer: chapter.url,
                pageIndex: item.pageIndex,
                aspectRatio: _aspectRatios[key] ?? _defaultAspectRatio,
                onAspectRatioChanged: (ratio) => _updateAspectRatio(
                  item.chapterIndex,
                  item.pageIndex,
                  ratio,
                ),
                onHeightChanged: (height) => _updatePageHeight(
                  item.chapterIndex,
                  item.pageIndex,
                  height,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

enum _ContinuousMangaItemType { header, page, gap }

class _ContinuousMangaItem {
  const _ContinuousMangaItem._(
    this.type,
    this.chapterIndex,
    this.pageIndex,
    this.url,
  );

  const _ContinuousMangaItem.header(int chapterIndex)
    : this._(_ContinuousMangaItemType.header, chapterIndex, -1, '');
  const _ContinuousMangaItem.page(int chapterIndex, int pageIndex, String url)
    : this._(_ContinuousMangaItemType.page, chapterIndex, pageIndex, url);
  const _ContinuousMangaItem.gap(int chapterIndex)
    : this._(_ContinuousMangaItemType.gap, chapterIndex, -1, '');

  final _ContinuousMangaItemType type;
  final int chapterIndex;
  final int pageIndex;
  final String url;
}

class _ContinuousMangaImage extends StatefulWidget {
  const _ContinuousMangaImage({
    super.key,
    required this.url,
    required this.referer,
    required this.pageIndex,
    required this.aspectRatio,
    required this.onAspectRatioChanged,
    required this.onHeightChanged,
  });

  final String url;
  final String referer;
  final int pageIndex;
  final double aspectRatio;
  final ValueChanged<double> onAspectRatioChanged;
  final ValueChanged<double> onHeightChanged;

  @override
  State<_ContinuousMangaImage> createState() => _ContinuousMangaImageState();
}

class _ContinuousMangaImageState extends State<_ContinuousMangaImage> {
  double _lastHeight = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxWidth / widget.aspectRatio;
        if ((_lastHeight - height).abs() >= 1) {
          _lastHeight = height;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onHeightChanged(height);
          });
        }
        return SizedBox(
          width: double.infinity,
          height: height,
          child: ColoredBox(
            color: Colors.white,
            child: ExtendedImage.network(
              widget.url,
              cache: true,
              retries: 3,
              timeLimit: const Duration(seconds: 15),
              cacheMaxAge: _ContinuousMangaViewState._imageCacheMaxAge,
              imageCacheName: _ContinuousMangaViewState._imageCacheName,
              width: double.infinity,
              height: height,
              fit: BoxFit.contain,
              alignment: Alignment.topCenter,
              headers: mangaImageHeaders(referer: widget.referer),
              clearMemoryCacheIfFailed: true,
              filterQuality: FilterQuality.low,
              loadStateChanged: (state) {
                if (state.extendedImageLoadState == LoadState.completed) {
                  final image = state.extendedImageInfo?.image;
                  if (image != null && image.width > 0 && image.height > 0) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        widget.onAspectRatioChanged(image.width / image.height);
                      }
                    });
                  }
                  return state.completedWidget;
                }
                if (state.extendedImageLoadState == LoadState.failed) {
                  return _ContinuousMangaPlaceholder(
                    message: '第 ${widget.pageIndex + 1} 页加载失败',
                  );
                }
                return const _ContinuousMangaPlaceholder();
              },
            ),
          ),
        );
      },
    );
  }
}

class _ContinuousMangaPlaceholder extends StatelessWidget {
  const _ContinuousMangaPlaceholder({this.message = ''});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF4F4F4),
      child: Center(
        child: message.isEmpty
            ? const SizedBox.shrink()
            : Text(
                message,
                style: const TextStyle(color: Colors.black45, fontSize: 12),
              ),
      ),
    );
  }
}
