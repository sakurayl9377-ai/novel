import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'manga_tile_decoder.dart';

typedef MangaTileErrorBuilder =
    Widget Function(BuildContext context, Object error, VoidCallback retry);
typedef MangaTilePlaceholderBuilder =
    Widget Function(BuildContext context, int? tileIndex);
typedef MangaTileSourcePredicate = bool Function(MangaTileSourceInfo source);
typedef MangaTileFallbackBuilder =
    Widget Function(
      BuildContext context,
      MangaTileSourceInfo? source,
      Object? error,
    );

@immutable
class MangaTileSlice {
  const MangaTileSlice({
    required this.index,
    required this.displayHeight,
    required this.sourceRect,
  });

  final int index;
  final double displayHeight;
  final MangaSourceRect sourceRect;
}

/// Creates adjacent full-width source regions with bounded display/source
/// heights. Rounding boundaries rather than individual heights ensures that no
/// source row is skipped or decoded twice.
@visibleForTesting
List<MangaTileSlice> buildMangaTileSlices({
  required MangaTileSourceInfo source,
  required double displayWidth,
  required double tileExtent,
  int maxSourceTileHeight = 32768,
}) {
  if (!displayWidth.isFinite || displayWidth <= 0) {
    throw ArgumentError.value(displayWidth, 'displayWidth');
  }
  if (!tileExtent.isFinite || tileExtent <= 0) {
    throw ArgumentError.value(tileExtent, 'tileExtent');
  }
  if (maxSourceTileHeight <= 0) {
    throw ArgumentError.value(maxSourceTileHeight, 'maxSourceTileHeight');
  }

  final displayHeight = displayWidth * source.height / source.width;
  final displayTileCount = (displayHeight / tileExtent).ceil();
  final sourceTileCount = (source.height / maxSourceTileHeight).ceil();
  final tileCount = math.max(1, math.max(displayTileCount, sourceTileCount));
  final result = <MangaTileSlice>[];

  for (var index = 0; index < tileCount; index++) {
    final displayStart = displayHeight * index / tileCount;
    final displayEnd = index == tileCount - 1
        ? displayHeight
        : displayHeight * (index + 1) / tileCount;
    final sourceStart = (source.height * index / tileCount).round();
    final sourceEnd = index == tileCount - 1
        ? source.height
        : (source.height * (index + 1) / tileCount).round();
    result.add(
      MangaTileSlice(
        index: index,
        displayHeight: displayEnd - displayStart,
        sourceRect: MangaSourceRect(
          x: 0,
          y: sourceStart,
          width: source.width,
          height: math.max(1, sourceEnd - sourceStart),
        ),
      ),
    );
  }
  return result;
}

/// Displays one tall manga source as disk-backed, lazily decoded regions.
///
/// This widget deliberately does not own a [ScrollController]. Each fixed-size
/// placeholder observes the nearest ancestor [Scrollable], requests its tile
/// shortly before it enters the viewport, and evicts decoded Flutter images
/// once they are far away. It can therefore be inserted into the reader's
/// existing single-chapter list without creating a nested scroll view.
class MangaTiledImage extends StatefulWidget {
  const MangaTiledImage({
    super.key,
    required this.source,
    this.referer,
    this.cacheKey,
    this.decoder,
    this.tileExtent = 512,
    this.preloadExtent = 900,
    this.evictionExtent = 2400,
    this.resolutionScale = 1,
    this.compressionQuality = 92,
    this.initialAspectRatio = 0.7,
    this.backgroundColor = const Color(0xFFF1F1F1),
    this.placeholderBuilder,
    this.errorBuilder,
    this.shouldUseTiling,
    this.fallbackBuilder,
    this.onSourceInfo,
    this.semanticLabel,
    this.maxTileCount = 512,
  }) : assert(tileExtent > 0),
       assert(preloadExtent >= 0),
       assert(evictionExtent >= preloadExtent),
       assert(resolutionScale > 0),
       assert(compressionQuality >= 70 && compressionQuality <= 100),
       assert(initialAspectRatio > 0),
       assert(maxTileCount > 0);

  final String source;
  final String? referer;
  final String? cacheKey;
  final MangaTileDecoder? decoder;
  final double tileExtent;
  final double preloadExtent;
  final double evictionExtent;
  final double resolutionScale;
  final int compressionQuality;
  final double initialAspectRatio;
  final Color backgroundColor;
  final MangaTilePlaceholderBuilder? placeholderBuilder;
  final MangaTileErrorBuilder? errorBuilder;
  final MangaTileSourcePredicate? shouldUseTiling;
  final MangaTileFallbackBuilder? fallbackBuilder;
  final ValueChanged<MangaTileSourceInfo>? onSourceInfo;
  final String? semanticLabel;
  final int maxTileCount;

  @override
  State<MangaTiledImage> createState() => _MangaTiledImageState();
}

class _MangaTiledImageState extends State<MangaTiledImage> {
  MangaTileSourceInfo? _sourceInfo;
  Object? _prepareError;
  Object? _tileError;
  var _prepareGeneration = 0;
  ScrollableState? _scrollable;
  var _visibilityCheckScheduled = false;
  var _activeStart = -1;
  var _activeEnd = -1;
  var _retainedStart = -1;
  var _retainedEnd = -1;
  var _layoutTileCount = 0;
  var _layoutDisplayHeight = 0.0;

  MangaTileDecoder get _decoder =>
      widget.decoder ?? MangaTileDecoderService.instance;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context);
    if (!identical(next, _scrollable)) {
      _scrollable?.position.removeListener(_scheduleVisibilityCheck);
      _scrollable = next;
      _scrollable?.position.addListener(_scheduleVisibilityCheck);
    }
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant MangaTiledImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged =
        oldWidget.source != widget.source ||
        oldWidget.referer != widget.referer ||
        oldWidget.cacheKey != widget.cacheKey ||
        oldWidget.decoder != widget.decoder;
    if (!sourceChanged) return;
    final previous = _sourceInfo;
    _sourceInfo = null;
    _prepareError = null;
    _tileError = null;
    _resetVisibilityRanges();
    _prepare(
      sourceToRelease: previous,
      releaseDecoder: oldWidget.decoder ?? MangaTileDecoderService.instance,
    );
  }

  @override
  void dispose() {
    ++_prepareGeneration;
    _scrollable?.position.removeListener(_scheduleVisibilityCheck);
    final info = _sourceInfo;
    if (info != null) unawaited(_decoder.releaseSource(info.sourceId));
    super.dispose();
  }

  Future<void> _prepare({
    MangaTileSourceInfo? sourceToRelease,
    MangaTileDecoder? releaseDecoder,
  }) async {
    final generation = ++_prepareGeneration;
    final decoder = _decoder;
    final previous = sourceToRelease ?? _sourceInfo;
    if (previous != null) {
      _sourceInfo = null;
      try {
        await (releaseDecoder ?? decoder).releaseSource(previous.sourceId);
      } catch (_) {
        // A detached native channel must not prevent a bounded fallback.
      }
      if (!mounted || generation != _prepareGeneration) return;
    }
    if (mounted &&
        (_sourceInfo != null || _prepareError != null || _tileError != null)) {
      setState(() {
        _sourceInfo = null;
        _prepareError = null;
        _tileError = null;
      });
    }
    try {
      final info = await decoder.prepareSource(
        MangaTileSourceRequest(
          source: widget.source,
          referer: widget.referer,
          cacheKey: widget.cacheKey,
        ),
      );
      if (!mounted || generation != _prepareGeneration) {
        await decoder.releaseSource(info.sourceId);
        return;
      }
      setState(() => _sourceInfo = info);
      _resetVisibilityRanges();
      _scheduleVisibilityCheck();
      try {
        widget.onSourceInfo?.call(info);
      } catch (_) {
        // Geometry observers must not invalidate a successfully prepared
        // native source.
      }
    } catch (error) {
      if (!mounted || generation != _prepareGeneration) return;
      setState(() => _prepareError = error);
    }
  }

  void _resetVisibilityRanges() {
    _activeStart = -1;
    _activeEnd = -1;
    _retainedStart = -1;
    _retainedEnd = -1;
    _layoutTileCount = 0;
    _layoutDisplayHeight = 0;
  }

  void _scheduleVisibilityCheck() {
    if (_visibilityCheckScheduled || !mounted) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (mounted) _evaluateVisibility();
    });
  }

  void _evaluateVisibility() {
    final tileCount = _layoutTileCount;
    final displayHeight = _layoutDisplayHeight;
    if (tileCount <= 0 || displayHeight <= 0) return;

    final imageBox = context.findRenderObject();
    if (imageBox is! RenderBox || !imageBox.hasSize) return;
    final scrollable = _scrollable;
    if (scrollable == null) {
      _applyVisibilityRanges(
        active: (0, math.min(2, tileCount - 1)),
        retained: (0, math.min(4, tileCount - 1)),
      );
      return;
    }
    final viewportContext = scrollable.position.context.notificationContext;
    final viewportBox = viewportContext?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return;

    final viewportOrigin = viewportBox.localToGlobal(Offset.zero);
    final viewportBottomGlobal = viewportOrigin.dy + viewportBox.size.height;
    final localViewportTop = imageBox.globalToLocal(viewportOrigin).dy;
    final localViewportBottom = imageBox
        .globalToLocal(Offset(viewportOrigin.dx, viewportBottomGlobal))
        .dy;
    final windowStart = math.min(localViewportTop, localViewportBottom);
    final windowEnd = math.max(localViewportTop, localViewportBottom);
    final active = _rangeForLocalWindow(
      windowStart - widget.preloadExtent,
      windowEnd + widget.preloadExtent,
      tileCount: tileCount,
      displayHeight: displayHeight,
    );
    final retained = _rangeForLocalWindow(
      windowStart - widget.evictionExtent,
      windowEnd + widget.evictionExtent,
      tileCount: tileCount,
      displayHeight: displayHeight,
    );
    _applyVisibilityRanges(active: active, retained: retained);
  }

  (int, int) _rangeForLocalWindow(
    double start,
    double end, {
    required int tileCount,
    required double displayHeight,
  }) {
    if (end <= 0 || start >= displayHeight) return (-1, -1);
    final extent = displayHeight / tileCount;
    final first = (math.max(0.0, start) / extent).floor().clamp(
      0,
      tileCount - 1,
    );
    final boundedEnd = math.min(displayHeight, end);
    final last = ((math.max(0.0, boundedEnd - 0.001)) / extent).floor().clamp(
      first,
      tileCount - 1,
    );
    return (first, last);
  }

  void _applyVisibilityRanges({
    required (int, int) active,
    required (int, int) retained,
  }) {
    if (_activeStart == active.$1 &&
        _activeEnd == active.$2 &&
        _retainedStart == retained.$1 &&
        _retainedEnd == retained.$2) {
      return;
    }
    setState(() {
      _activeStart = active.$1;
      _activeEnd = active.$2;
      _retainedStart = retained.$1;
      _retainedEnd = retained.$2;
    });
  }

  bool _containsRange(int index, int start, int end) =>
      start >= 0 && index >= start && index <= end;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (!width.isFinite || width <= 0) {
          return _buildError(
            context,
            const MangaTileDecoderException(
              code: 'INVALID_LAYOUT',
              message: 'Tiled manga image requires a bounded width',
            ),
          );
        }
        final error = _prepareError;
        if (error != null) return _buildFallbackOrError(context, null, error);

        final info = _sourceInfo;
        if (info == null) {
          return SizedBox(
            width: width,
            height: width / widget.initialAspectRatio,
            child: _buildPlaceholder(context, null),
          );
        }
        final tileError = _tileError;
        if (tileError != null) {
          return _buildFallbackOrError(context, info, tileError);
        }
        final shouldUseTiling = widget.shouldUseTiling?.call(info) ?? true;
        if (!shouldUseTiling) {
          final fallbackBuilder = widget.fallbackBuilder;
          if (fallbackBuilder != null) {
            return fallbackBuilder(context, info, null);
          }
          return _buildError(
            context,
            const MangaTileDecoderException(
              code: 'TILING_NOT_REQUIRED',
              message: 'This image does not require tiled decoding',
            ),
          );
        }
        if (info.width > 32768) {
          return _buildFallbackOrError(
            context,
            info,
            const MangaTileDecoderException(
              code: 'SOURCE_TOO_WIDE',
              message: 'This image is too wide for bounded region decoding',
            ),
          );
        }

        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final targetWidth = (width * devicePixelRatio * widget.resolutionScale)
            .ceil()
            .clamp(64, 2048);
        final displayHeight = width * info.height / info.width;
        final boundedTileExtent = math.max(
          widget.tileExtent,
          displayHeight / widget.maxTileCount,
        );
        final slices = buildMangaTileSlices(
          source: info,
          displayWidth: width,
          tileExtent: boundedTileExtent,
        );
        _layoutTileCount = slices.length;
        _layoutDisplayHeight = displayHeight;
        _scheduleVisibilityCheck();
        Widget result = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final slice in slices)
              SizedBox(
                key: ValueKey(
                  'manga-tile-slot-${info.sourceId}-${slice.index}-$targetWidth',
                ),
                width: width,
                height: slice.displayHeight,
                child: _LazyMangaTile(
                  decoder: _decoder,
                  sourceInfo: info,
                  slice: slice,
                  targetWidth: targetWidth,
                  quality: widget.compressionQuality,
                  active: _containsRange(slice.index, _activeStart, _activeEnd),
                  retain: _containsRange(
                    slice.index,
                    _retainedStart,
                    _retainedEnd,
                  ),
                  backgroundColor: widget.backgroundColor,
                  placeholderBuilder: widget.placeholderBuilder,
                  errorBuilder: widget.errorBuilder,
                  onFatalError: _handleTileError,
                ),
              ),
          ],
        );
        final semanticLabel = widget.semanticLabel;
        if (semanticLabel != null && semanticLabel.isNotEmpty) {
          result = Semantics(image: true, label: semanticLabel, child: result);
        }
        return result;
      },
    );
  }

  Widget _buildPlaceholder(BuildContext context, int? index) {
    return widget.placeholderBuilder?.call(context, index) ??
        ColoredBox(
          color: widget.backgroundColor,
          child: const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
  }

  Widget _buildError(BuildContext context, Object error) {
    return widget.errorBuilder?.call(context, error, _prepare) ??
        ColoredBox(
          color: widget.backgroundColor,
          child: Center(
            child: IconButton(
              tooltip: '重试加载图片',
              onPressed: _prepare,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
        );
  }

  Widget _buildFallbackOrError(
    BuildContext context,
    MangaTileSourceInfo? source,
    Object error,
  ) {
    return widget.fallbackBuilder?.call(context, source, error) ??
        _buildError(context, error);
  }

  void _handleTileError(Object error) {
    if (!mounted || _tileError != null || widget.fallbackBuilder == null) {
      return;
    }
    setState(() => _tileError = error);
  }
}

class _LazyMangaTile extends StatefulWidget {
  const _LazyMangaTile({
    required this.decoder,
    required this.sourceInfo,
    required this.slice,
    required this.targetWidth,
    required this.quality,
    required this.active,
    required this.retain,
    required this.backgroundColor,
    required this.placeholderBuilder,
    required this.errorBuilder,
    required this.onFatalError,
  });

  final MangaTileDecoder decoder;
  final MangaTileSourceInfo sourceInfo;
  final MangaTileSlice slice;
  final int targetWidth;
  final int quality;
  final bool active;
  final bool retain;
  final Color backgroundColor;
  final MangaTilePlaceholderBuilder? placeholderBuilder;
  final MangaTileErrorBuilder? errorBuilder;
  final ValueChanged<Object>? onFatalError;

  @override
  State<_LazyMangaTile> createState() => _LazyMangaTileState();
}

class _LazyMangaTileState extends State<_LazyMangaTile> {
  FileImage? _image;
  Object? _error;
  var _loading = false;
  var _requestGeneration = 0;
  var _activitySyncScheduled = false;
  var _fileDecodeErrorReported = false;

  @override
  void initState() {
    super.initState();
    _scheduleActivitySync();
  }

  @override
  void didUpdateWidget(covariant _LazyMangaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final requestChanged =
        oldWidget.sourceInfo.sourceId != widget.sourceInfo.sourceId ||
        oldWidget.slice.sourceRect != widget.slice.sourceRect ||
        oldWidget.targetWidth != widget.targetWidth ||
        oldWidget.quality != widget.quality ||
        oldWidget.decoder != widget.decoder;
    if (requestChanged) _resetDecodedImage();
    _scheduleActivitySync();
  }

  @override
  void dispose() {
    ++_requestGeneration;
    final image = _image;
    if (image != null) unawaited(image.evict());
    super.dispose();
  }

  void _resetDecodedImage() {
    ++_requestGeneration;
    final image = _image;
    _image = null;
    _error = null;
    _loading = false;
    _fileDecodeErrorReported = false;
    if (image != null) unawaited(image.evict());
  }

  void _scheduleActivitySync() {
    if (_activitySyncScheduled || !mounted) return;
    _activitySyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activitySyncScheduled = false;
      if (mounted) _syncActivity();
    });
  }

  void _syncActivity() {
    if (widget.active) {
      unawaited(_loadIfNeeded());
      return;
    }
    if (!widget.retain && (_image != null || _loading)) {
      final image = _image;
      ++_requestGeneration;
      setState(() {
        _image = null;
        _loading = false;
      });
      if (image != null) unawaited(image.evict());
    }
  }

  Future<void> _loadIfNeeded() async {
    if (!widget.active || _loading || _image != null || _error != null) return;
    final generation = ++_requestGeneration;
    setState(() => _loading = true);
    try {
      final tile = await widget.decoder.decodeTile(
        MangaTileRequest(
          sourceId: widget.sourceInfo.sourceId,
          sourceRect: widget.slice.sourceRect,
          targetWidth: widget.targetWidth,
          quality: widget.quality,
        ),
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _image = FileImage(File(tile.path));
        _loading = false;
        _error = null;
        _fileDecodeErrorReported = false;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loading = false;
        _error = error;
      });
      widget.onFatalError?.call(error);
    }
  }

  void _retry() {
    ++_requestGeneration;
    final image = _image;
    setState(() {
      _image = null;
      _error = null;
      _loading = false;
      _fileDecodeErrorReported = false;
    });
    if (image != null) unawaited(image.evict());
    _loadIfNeeded();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return widget.errorBuilder?.call(context, error, _retry) ??
          ColoredBox(
            color: widget.backgroundColor,
            child: Center(
              child: IconButton(
                tooltip: '重试当前图片分块',
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ),
          );
    }
    final image = _image;
    if (image == null) {
      return widget.placeholderBuilder?.call(context, widget.slice.index) ??
          ColoredBox(color: widget.backgroundColor);
    }
    return Image(
      image: image,
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) {
        if (!_fileDecodeErrorReported) {
          _fileDecodeErrorReported = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onFatalError?.call(error);
          });
        }
        return widget.errorBuilder?.call(context, error, _retry) ??
            ColoredBox(
              color: widget.backgroundColor,
              child: Center(
                child: IconButton(
                  tooltip: '重试当前图片分块',
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
            );
      },
    );
  }
}
