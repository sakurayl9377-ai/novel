import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' as crypto;
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../features/manga_reader/manga_layout_index.dart';
import '../features/manga_reader/manga_page_pipeline.dart';
import '../features/manga_reader/manga_paged_view.dart';
import '../features/manga_reader/manga_reader_preferences.dart';
import '../features/manga_reader/manga_tile_decoder.dart';
import '../features/manga_reader/manga_tiled_image.dart';
import '../features/reader_core/reader_core.dart';
import '../models/manga.dart';
import '../models/manga_read_history.dart';
import '../models/local_library.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/app_telemetry_service.dart';
import '../services/bounded_task_scheduler.dart';
import '../services/download_manager_service.dart';
import '../services/manga_service.dart';
import '../services/manga_image_service.dart';
import '../services/storage_service.dart';
import '../utils/auth_gate.dart';
import 'comment_thread_screen.dart';

class MangaReaderScreen extends StatefulWidget {
  static const routeName = '/manga/reader';

  const MangaReaderScreen({
    super.key,
    required this.manga,
    required this.chapter,
    required this.chapterIndex,
    this.initialScrollOffset = 0,
    this.initialScrollProgress,
    this.initialPageIndex = 0,
    this.initialPageOffsetRatio = 0,
    this.chapterImageLoader,
    this.canLoadChapterOverride,
    this.warmVisiblePage = true,
    this.historyChapterIndexOverride,
    this.historyChaptersOverride,
    this.mangaPageBuilder,
  });

  final Manga manga;
  final MangaChapter chapter;
  final int chapterIndex;
  final double initialScrollOffset;
  final double? initialScrollProgress;
  final int initialPageIndex;
  final double initialPageOffsetRatio;
  final Future<List<String>> Function(MangaChapter chapter)? chapterImageLoader;
  final bool Function(int chapterIndex)? canLoadChapterOverride;
  final bool warmVisiblePage;
  final int? historyChapterIndexOverride;
  final List<MangaChapter>? historyChaptersOverride;
  final Widget Function(
    BuildContext context,
    int chapterIndex,
    int pageIndex,
    String imageUrl,
  )?
  mangaPageBuilder;

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends State<MangaReaderScreen>
    with WidgetsBindingObserver {
  final MangaService _service = MangaService();
  final StorageService _storageService = StorageService();
  final ScrollController _scrollController = ScrollController();
  final BoundedTaskScheduler _imagePrefetchScheduler = BoundedTaskScheduler(
    maxConcurrent: 2,
  );

  Timer? _saveTimer;
  int _chapterLoadGeneration = 0;
  late MangaChapter _currentChapter;
  late int _currentIndex;
  List<String> _images = [];
  final Map<int, double> _pageAspectRatios = {};
  final Map<int, double> _pageHeights = {};
  final Set<int> _prefetchedPages = {};
  final Set<int> _splitWidePages = {};
  final Set<int> _forcePairedPages = {};
  final Set<int> _forceSinglePages = {};
  final Set<int> _swappedSpreadStarts = {};
  final Set<int> _zoomedLongStripPages = {};
  final Set<int> _safePageBreakAfterIndexes = {};
  final Set<int> _pageBreakAnalysisPending = {};
  final Set<int> _analyzedPageBreakIndexes = {};
  final ValueNotifier<int> _chapterProgress = ValueNotifier<int>(0);
  final ValueNotifier<int> _pageGeometryVersion = ValueNotifier<int>(0);
  final MangaPagePipeline _pagePipeline = const MangaPagePipeline();
  final MangaLayoutIndex _layoutIndex = MangaLayoutIndex(
    pageCount: 0,
    defaultExtent: 1,
  );
  Timer? _aspectRatioSaveTimer;
  Timer? _pageGeometryRefreshTimer;
  double _viewportWidth = 0;
  int _chapterProgressPercent = 0;
  int _currentPagedPageIndex = 0;
  int _currentPagedLastPageIndex = 0;
  int _scrollCorrectionGeneration = 0;
  bool _hasUserScrolledSinceChapterLoad = false;
  bool _isChangingChapter = false;
  bool _isLoading = true;
  bool _showBars = true;
  late MangaReaderPreferences _preferences;
  String? _errorMessage;
  late final AppTelemetryScreenTrace _telemetryTrace;

  static const double _defaultPageAspectRatio = 0.68;
  static const String _imageCacheName = 'manga_reader_images';
  static const Duration _imageCacheMaxAge = Duration(days: 14);
  static const int _prefetchRadius = 2;
  static const int _pagedPrefetchRadius = 6;
  static const int _maxTrackedPrefetchPages = _pagedPrefetchRadius * 2 + 1;
  static const int _maxPendingImagePrefetches = 12;
  static const int _maxAutoDecodeWidth = 2048;
  static const int _maxHighDecodeWidth = 3072;
  static const int _maxOriginalDecodeWidth = 4096;

  List<MangaChapter> get _chapters => widget.manga.chapters;

  Future<List<String>> _fetchChapterImages(MangaChapter chapter) {
    return widget.chapterImageLoader?.call(chapter) ??
        _service.fetchChapterImages(chapter);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      _preferences = MangaReaderPreferences.decode(
        _storageService.getString(MangaReaderPreferences.storageKey),
      );
    } catch (_) {
      _preferences = const MangaReaderPreferences();
    }
    unawaited(_syncPageOrientation(_preferences));
    _scrollController.addListener(_handleScrollChanged);
    _telemetryTrace = AppTelemetryService.instance.openScreen(
      'manga_reader',
      metadata: {
        'contentId': widget.manga.id,
        'chapterId': widget.chapter.id,
        'startChapter': widget.chapterIndex,
        'historyRestore':
            widget.initialScrollOffset > 0 ||
            (widget.initialScrollProgress ?? 0) > 0 ||
            widget.initialPageIndex > 0,
      },
    );
    _currentChapter = widget.chapter;
    _currentIndex = widget.chapterIndex;
    if (_currentIndex < 0 || _currentIndex >= _chapters.length) {
      _currentIndex = _chapters.indexWhere(
        (chapter) => chapter.url == _currentChapter.url,
      );
    }
    if (_currentIndex < 0) _currentIndex = 0;
    unawaited(
      _loadChapter(
        _currentChapter,
        _currentIndex,
        initialScrollOffset: widget.initialScrollOffset,
        initialScrollProgress: widget.initialScrollProgress,
        initialPageIndex: widget.initialPageIndex,
        initialPageOffsetRatio: widget.initialPageOffsetRatio,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    WidgetsBinding.instance.removeObserver(this);
    _chapterLoadGeneration++;
    _evictTrackedPrefetches();
    _saveTimer?.cancel();
    _aspectRatioSaveTimer?.cancel();
    _pageGeometryRefreshTimer?.cancel();
    unawaited(_saveAspectRatioCache());
    unawaited(_saveHistory());
    _scrollController.removeListener(_handleScrollChanged);
    _scrollController.dispose();
    _chapterProgress.dispose();
    _pageGeometryVersion.dispose();
    _telemetryTrace.close(
      metadata: {
        'chapterIndex': _currentIndex,
        'pageCount': _images.length,
        'progressPercent': _chapterProgressPercent,
      },
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    unawaited(_saveHistory());
  }

  Future<void> _loadChapter(
    MangaChapter chapter,
    int index, {
    double initialScrollOffset = 0,
    double? initialScrollProgress,
    int initialPageIndex = 0,
    double initialPageOffsetRatio = 0,
  }) async {
    final stopwatch = Stopwatch()..start();
    final loadGeneration = ++_chapterLoadGeneration;
    // A denied attempt to open a later chapter should leave the current
    // chapter visible instead of replacing it with an error page.
    final canOpen = await _ensureChapterUnlocked(
      index,
      showError: _images.isEmpty,
    );
    if (!canOpen || !_isCurrentChapterLoad(loadGeneration)) return;

    _saveTimer?.cancel();
    _scrollCorrectionGeneration++;
    _hasUserScrolledSinceChapterLoad = false;
    final hadVisibleChapter = _images.isNotEmpty;
    if (hadVisibleChapter) await _saveHistory();
    _aspectRatioSaveTimer?.cancel();
    if (_pageAspectRatios.isNotEmpty) await _saveAspectRatioCache();
    if (!_isCurrentChapterLoad(loadGeneration)) return;
    _evictTrackedPrefetches();
    if (!hadVisibleChapter) {
      setState(() {
        _currentChapter = chapter;
        _currentIndex = index;
        _images = [];
        _pageAspectRatios.clear();
        _pageHeights.clear();
        _prefetchedPages.clear();
        _splitWidePages.clear();
        _forcePairedPages.clear();
        _forceSinglePages.clear();
        _swappedSpreadStarts.clear();
        _zoomedLongStripPages.clear();
        _safePageBreakAfterIndexes.clear();
        _pageBreakAnalysisPending.clear();
        _analyzedPageBreakIndexes.clear();
        _chapterProgressPercent = 0;
        _chapterProgress.value = 0;
        _currentPagedPageIndex = 0;
        _currentPagedLastPageIndex = 0;
        _isLoading = true;
        _errorMessage = null;
        _showBars = true;
      });
    }

    try {
      final cachedRatiosFuture = _loadAspectRatioCache(chapter.url);
      final images = await _fetchChapterImages(chapter);
      final cachedRatios = await cachedRatiosFuture;
      if (!_isCurrentChapterLoad(loadGeneration)) return;
      if (images.isEmpty) {
        AppTelemetryService.instance.trackEvent(
          'content_load',
          screen: 'manga_reader',
          durationMs: stopwatch.elapsedMilliseconds,
          success: false,
          metadata: {
            'contentType': 'manga',
            'chapterIndex': index,
            'reason': 'empty_images',
          },
        );
        if (hadVisibleChapter) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('章节图片解析失败，请稍后重试')));
          }
        } else {
          setState(() {
            _isLoading = false;
            _errorMessage = '章节图片解析失败，请稍后重试';
          });
        }
        return;
      }
      if (widget.warmVisiblePage) {
        final visiblePageIndex = initialPageIndex
            .clamp(0, images.length - 1)
            .toInt();
        try {
          await _warmPageImage(
            images[visiblePageIndex],
            chapter.url,
          ).timeout(const Duration(seconds: 3));
        } catch (_) {
          // Keep the stable loading screen for at most three seconds, then let
          // the page-level retry and placeholder handle a slow image.
        }
      }
      if (!_isCurrentChapterLoad(loadGeneration)) return;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      final restoredPageIndex = initialPageIndex
          .clamp(0, images.length - 1)
          .toInt();
      setState(() {
        _currentChapter = chapter;
        _currentIndex = index;
        _images = images;
        _pageAspectRatios.clear();
        _pageAspectRatios.addAll(cachedRatios);
        _pageHeights.clear();
        _prefetchedPages.clear();
        _splitWidePages.clear();
        _forcePairedPages.clear();
        _forceSinglePages.clear();
        _swappedSpreadStarts.clear();
        _zoomedLongStripPages.clear();
        _safePageBreakAfterIndexes.clear();
        _pageBreakAnalysisPending.clear();
        _analyzedPageBreakIndexes.clear();
        _chapterProgressPercent = 0;
        _chapterProgress.value = 0;
        _currentPagedPageIndex = restoredPageIndex;
        _currentPagedLastPageIndex = restoredPageIndex;
        _resetLayoutIndex(images.length);
        _isLoading = false;
        _errorMessage = null;
        _showBars = true;
      });
      AppTelemetryService.instance.trackEvent(
        'content_load',
        screen: 'manga_reader',
        durationMs: stopwatch.elapsedMilliseconds,
        success: true,
        metadata: {
          'contentType': 'manga',
          'chapterIndex': index,
          'pageCount': images.length,
          'cachedRatios': cachedRatios.length,
        },
      );
      _refreshChapterProgress();
      _restoreScroll(
        initialScrollOffset,
        progress: initialScrollProgress,
        pageIndex: initialPageIndex,
        pageOffsetRatio: initialPageOffsetRatio,
      );
      _startSaveTimer();
      unawaited(_saveHistory());
      if (widget.mangaPageBuilder == null) {
        unawaited(
          _preloadInitialPages(
            images,
            chapter.url,
            chapterLoadGeneration: loadGeneration,
            initialPageIndex: initialPageIndex,
          ),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_isCurrentChapterLoad(loadGeneration)) return;
          _prefetchNearCurrentLocation();
        });
        unawaited(_prewarmNextChapterFirstPage(loadGeneration));
      }
    } catch (error) {
      if (!_isCurrentChapterLoad(loadGeneration)) return;
      AppTelemetryService.instance.trackEvent(
        'content_load',
        screen: 'manga_reader',
        durationMs: stopwatch.elapsedMilliseconds,
        success: false,
        metadata: {
          'contentType': 'manga',
          'chapterIndex': index,
          'errorType': error.runtimeType.toString(),
        },
      );
      if (hadVisibleChapter) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('章节加载失败，请稍后重试')));
        }
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = '章节加载失败，请稍后重试';
        });
      }
    }
  }

  bool _isCurrentChapterLoad(int generation) {
    return mounted && generation == _chapterLoadGeneration;
  }

  void _restoreScroll(
    double offset, {
    double? progress,
    int pageIndex = 0,
    double pageOffsetRatio = 0,
  }) {
    if (_images.isEmpty) return;
    final normalizedProgress = progress?.clamp(0.0, 1.0).toDouble();
    final normalizedPageIndex = pageIndex.clamp(0, _images.length - 1).toInt();
    final normalizedPageRatio = pageOffsetRatio.clamp(0.0, 1.0).toDouble();
    if (offset <= 0 &&
        (normalizedProgress == null || normalizedProgress <= 0) &&
        normalizedPageIndex <= 0 &&
        normalizedPageRatio <= 0) {
      return;
    }

    if (_preferences.readingMode == MangaReadingMode.paged) {
      final restoredPage =
          normalizedPageIndex == 0 &&
              normalizedPageRatio == 0 &&
              normalizedProgress != null &&
              normalizedProgress > 0
          ? (normalizedProgress * _images.length).floor().clamp(
              0,
              _images.length - 1,
            )
          : normalizedPageIndex;
      _currentPagedPageIndex = restoredPage;
      _currentPagedLastPageIndex = restoredPage;
      _refreshChapterProgress();
      _prefetchNearCurrentLocation();
      return;
    }

    void jump() {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final maxOffset = position.maxScrollExtent;
      var target = offset;
      if (normalizedPageIndex > 0 || normalizedPageRatio > 0) {
        target =
            _pageStartForIndex(normalizedPageIndex) +
            _estimatedPageHeight(normalizedPageIndex) * normalizedPageRatio;
      } else if (normalizedProgress != null && maxOffset > 0) {
        target = maxOffset * normalizedProgress;
      }
      _scrollController.jumpTo(target.clamp(0.0, maxOffset).toDouble());
      _refreshChapterProgress();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
  }

  void _handleScrollChanged() {
    if (_preferences.readingMode != MangaReadingMode.longStrip) return;
    _refreshChapterProgress();
  }

  void _refreshChapterProgress() {
    if (!mounted) return;
    final nextPercent = _currentChapterProgressPercent();
    if (nextPercent == _chapterProgressPercent) return;
    _chapterProgressPercent = nextPercent;
    _chapterProgress.value = nextPercent;
  }

  int _currentChapterProgressPercent() {
    if (_images.isEmpty) return 0;
    if (_preferences.readingMode == MangaReadingMode.paged) {
      return (((_currentPagedLastPageIndex + 1) / _images.length) * 100)
          .clamp(0.0, 100.0)
          .round();
    }
    if (!_scrollController.hasClients) return 0;
    final position = _scrollController.position;
    final maxOffset = position.maxScrollExtent;
    if (maxOffset <= 0) return position.pixels > 0 ? 100 : 0;
    return ((position.pixels / maxOffset) * 100).clamp(0.0, 100.0).round();
  }

  int? _targetDecodeWidth([double? requestedLogicalWidth]) {
    final logicalWidth =
        requestedLogicalWidth ?? (_viewportWidth > 0 ? _viewportWidth : 390.0);
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final pixelRatio = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
    final scale = switch (_preferences.imageQuality) {
      MangaImageQuality.auto => 1.0,
      MangaImageQuality.high => 1.5,
      MangaImageQuality.original => 2.0,
    };
    final maxWidth = switch (_preferences.imageQuality) {
      MangaImageQuality.auto => _maxAutoDecodeWidth,
      MangaImageQuality.high => _maxHighDecodeWidth,
      MangaImageQuality.original => _maxOriginalDecodeWidth,
    };
    return (logicalWidth * pixelRatio * scale)
        .ceil()
        .clamp(1, maxWidth)
        .toInt();
  }

  ImageProvider _pageImageProvider(String source, String referer) {
    return _mangaPageImageProvider(
      source,
      referer: referer,
      cacheWidth: _targetDecodeWidth(),
      cacheName: _imageCacheName,
      cacheMaxAge: _imageCacheMaxAge,
    );
  }

  void _evictTrackedPrefetches() {
    if (_prefetchedPages.isEmpty || _images.isEmpty) {
      _prefetchedPages.clear();
      return;
    }
    final indexes = _prefetchedPages.toList(growable: false);
    _prefetchedPages.clear();
    for (final index in indexes) {
      if (index < 0 || index >= _images.length) continue;
      unawaited(
        _pageImageProvider(_images[index], _currentChapter.url).evict(),
      );
    }
  }

  void _evictDistantPrefetches(Set<int> retainedIndexes) {
    final evicted = _prefetchedPages
        .where((index) => !retainedIndexes.contains(index))
        .toList(growable: false);
    _prefetchedPages.removeAll(evicted);
    for (final index in evicted) {
      if (index < 0 || index >= _images.length) continue;
      unawaited(
        _pageImageProvider(_images[index], _currentChapter.url).evict(),
      );
    }
  }

  Future<void> _warmPageImage(String url, String referer) async {
    final provider = _pageImageProvider(url, referer);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final completer = Completer<void>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    try {
      await completer.future.timeout(const Duration(seconds: 12));
    } finally {
      stream.removeListener(listener);
    }
  }

  Future<void> _preloadInitialPages(
    List<String> images,
    String referer, {
    required int chapterLoadGeneration,
    int initialPageIndex = 0,
  }) async {
    if (images.isEmpty) return;
    final anchor = initialPageIndex.clamp(0, images.length - 1).toInt();
    final indexes = <int>[];
    for (final delta in const [0, 1, -1]) {
      final index = anchor + delta;
      if (index >= 0 && index < images.length && !indexes.contains(index)) {
        indexes.add(index);
      }
    }
    try {
      // The visible/restore target always gets the first network slot. Only
      // after it settles are neighboring pages allowed to use the queue.
      await _preloadPageImage(
        anchor,
        images[anchor],
        referer,
        chapterLoadGeneration: chapterLoadGeneration,
        priority: 1000,
      ).timeout(const Duration(seconds: 5));
      for (final index in indexes.where((index) => index != anchor)) {
        unawaited(
          _preloadPageImage(
            index,
            images[index],
            referer,
            chapterLoadGeneration: chapterLoadGeneration,
            priority: 100 - (index - anchor).abs(),
          ),
        );
      }
    } catch (_) {
      // A slow first page should not block opening the chapter indefinitely.
    }
  }

  Future<void> _preloadPageImage(
    int index,
    String url,
    String referer, {
    int? chapterLoadGeneration,
    int priority = 0,
  }) {
    final generation = chapterLoadGeneration ?? _chapterLoadGeneration;
    if (!_isCurrentChapterLoad(generation) || referer != _currentChapter.url) {
      return Future<void>.value();
    }
    if (_imagePrefetchScheduler.pendingCount >= _maxPendingImagePrefetches &&
        priority < 1000) {
      return Future<void>.value();
    }
    if (!_prefetchedPages.add(index)) return Future<void>.value();
    return _imagePrefetchScheduler.schedule(
      () => _loadPageImage(index, url, referer, generation),
      priority: priority,
    );
  }

  Future<void> _prewarmNextChapterFirstPage(int loadGeneration) async {
    final nextIndex = _currentIndex + 1;
    if (nextIndex >= _chapters.length ||
        !_canSilentlyWarmChapter(nextIndex) ||
        !_isCurrentChapterLoad(loadGeneration)) {
      return;
    }
    try {
      await _imagePrefetchScheduler.schedule(() async {
        if (!_isCurrentChapterLoad(loadGeneration)) return;
        final chapter = _chapters[nextIndex];
        final images = await _fetchChapterImages(chapter);
        if (!_isCurrentChapterLoad(loadGeneration) || images.isEmpty) return;
        await _warmPageImage(images.first, chapter.url);
      }, priority: -100);
    } catch (_) {
      // Next-chapter warming is deliberately best effort and never changes
      // the currently visible, stable chapter.
    }
  }

  bool _canSilentlyWarmChapter(int chapterIndex) {
    final override = widget.canLoadChapterOverride;
    if (override != null) return override(chapterIndex);
    if (chapterIndex == 0) return true;
    try {
      return context.read<InteractionAuthProvider>().isLoggedIn;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadPageImage(
    int index,
    String url,
    String referer,
    int chapterLoadGeneration,
  ) async {
    if (!_isCurrentChapterLoad(chapterLoadGeneration) ||
        referer != _currentChapter.url ||
        !_prefetchedPages.contains(index)) {
      return;
    }
    final provider = _pageImageProvider(url, referer);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final completer = Completer<void>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, synchronousCall) {
        if (!_isCurrentChapterLoad(chapterLoadGeneration) ||
            referer != _currentChapter.url ||
            !_prefetchedPages.contains(index)) {
          if (!completer.isCompleted) completer.complete();
          return;
        }
        final image = imageInfo.image;
        final width = image.width.toDouble();
        final height = image.height.toDouble();
        if (width > 0 && height > 0) {
          unawaited(_analyzeSafePageBreak(index, image));
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_isCurrentChapterLoad(chapterLoadGeneration) &&
                referer == _currentChapter.url) {
              _updatePageAspectRatio(index, width / height);
            }
          });
        }
        if (!completer.isCompleted) completer.complete();
      },
      onError: (exception, stackTrace) {
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    try {
      await completer.future.timeout(const Duration(seconds: 12));
    } catch (_) {
      // Keep the default page ratio if a single page is slow or broken.
    } finally {
      stream.removeListener(listener);
      if (!_prefetchedPages.contains(index)) {
        await provider.evict();
      }
    }
  }

  Future<void> _analyzeSafePageBreak(int index, ui.Image image) async {
    if (_analyzedPageBreakIndexes.contains(index) ||
        !_pageBreakAnalysisPending.add(index)) {
      return;
    }
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null || image.width <= 0 || image.height <= 0) return;
      final bytes = data.buffer.asUint8List();
      final sampledRows = image.height.clamp(8, 32);
      var sampled = 0;
      var nearWhite = 0;
      for (var y = image.height - sampledRows; y < image.height; y += 2) {
        for (var x = 0; x < image.width; x += 6) {
          final offset = (y * image.width + x) * 4;
          if (offset + 2 >= bytes.length) continue;
          sampled += 1;
          if (bytes[offset] >= 242 &&
              bytes[offset + 1] >= 242 &&
              bytes[offset + 2] >= 242) {
            nearWhite += 1;
          }
        }
      }
      if (sampled == 0 || nearWhite / sampled < 0.96) return;
      if (_safePageBreakAfterIndexes.add(index) && mounted) {
        _pageGeometryRefreshTimer?.cancel();
        _pageGeometryRefreshTimer = Timer(
          const Duration(milliseconds: 120),
          () {
            if (mounted) _pageGeometryVersion.value += 1;
          },
        );
      }
    } catch (_) {
      // Pixel analysis is best effort; unknown seams remain unbroken.
    } finally {
      _pageBreakAnalysisPending.remove(index);
      _analyzedPageBreakIndexes.add(index);
    }
  }

  void _prefetchNearCurrentLocation() {
    if (_images.isEmpty) return;
    final currentIndex = _preferences.readingMode == MangaReadingMode.paged
        ? _currentPagedPageIndex.clamp(0, _images.length - 1)
        : _layoutIndex.indexAtOffset(
            _scrollController.hasClients
                ? _scrollController.offset +
                      _scrollController.position.viewportDimension * 0.5
                : 0,
          );
    final radius = _preferences.readingMode == MangaReadingMode.paged
        ? _pagedPrefetchRadius
        : _prefetchRadius;
    final retainedIndexes = <int>{
      for (
        var index = currentIndex - radius;
        index <= currentIndex + radius;
        index++
      )
        if (index >= 0 && index < _images.length) index,
    };
    _evictDistantPrefetches(retainedIndexes);
    assert(_prefetchedPages.length <= _maxTrackedPrefetchPages);
    final deltas = <int>[0];
    for (var distance = 1; distance <= radius; distance++) {
      deltas
        ..add(distance)
        ..add(-distance);
    }
    for (final delta in deltas) {
      final index = currentIndex + delta;
      if (!retainedIndexes.contains(index)) continue;
      unawaited(
        _preloadPageImage(
          index,
          _images[index],
          _currentChapter.url,
          priority: 50 - delta.abs(),
        ),
      );
    }
  }

  // Kept as a named entry point for existing navigation regressions and
  // notification callbacks; the lookup itself is now logarithmic.
  void _prefetchNearScrollOffset() => _prefetchNearCurrentLocation();

  void _updatePageAspectRatio(int index, double aspectRatio) {
    if (aspectRatio <= 0 || !aspectRatio.isFinite) return;
    final old = _pageAspectRatios[index];
    if (old != null && (old - aspectRatio).abs() < 0.01) return;
    if (!mounted) return;
    final crossedWideBoundary =
        ((old ?? _defaultPageAspectRatio) < _pagePipeline.widePageRatio) !=
        (aspectRatio < _pagePipeline.widePageRatio);
    final oldSegmentCount = _pagePipeline.segmentCountForAspectRatio(
      old ?? _defaultPageAspectRatio,
    );
    final newSegmentCount = _pagePipeline.segmentCountForAspectRatio(
      aspectRatio,
    );
    _pageAspectRatios[index] = aspectRatio;
    if (_viewportWidth > 0) {
      _updatePageHeight(index, _viewportWidth / aspectRatio);
    }
    if (_preferences.readingMode == MangaReadingMode.paged &&
        (crossedWideBoundary || oldSegmentCount != newSegmentCount)) {
      _pageGeometryRefreshTimer?.cancel();
      _pageGeometryRefreshTimer = Timer(const Duration(milliseconds: 120), () {
        if (mounted) _pageGeometryVersion.value += 1;
      });
    }
    _aspectRatioSaveTimer?.cancel();
    _aspectRatioSaveTimer = Timer(
      const Duration(milliseconds: 800),
      () => unawaited(_saveAspectRatioCache()),
    );
  }

  void _updatePageHeight(int index, double height) {
    if (height <= 0 || !height.isFinite) return;
    final oldHeight = _layoutIndex.extentAt(index);
    if ((oldHeight - height).abs() < 1) {
      _pageHeights[index] = height;
      return;
    }

    final pageStart = _pageStartForIndex(index);
    final delta = height - oldHeight;
    _pageHeights[index] = height;
    _layoutIndex.updateExtent(index, height);
    if (!_scrollController.hasClients ||
        pageStart >= _scrollController.offset) {
      return;
    }
    final position = _scrollController.position;
    final currentOffset = position.pixels;
    final correctionGeneration = _scrollCorrectionGeneration;
    final chapterUrl = _currentChapter.url;
    final correction = pageStart + oldHeight <= currentOffset
        ? delta
        : delta * ((currentOffset - pageStart) / oldHeight).clamp(0.0, 1.0);
    if (correction.abs() < 1) return;
    final target = (currentOffset + correction).clamp(
      0.0,
      position.maxScrollExtent,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          _hasUserScrolledSinceChapterLoad ||
          correctionGeneration != _scrollCorrectionGeneration ||
          chapterUrl != _currentChapter.url ||
          (_scrollController.offset - currentOffset).abs() >= 1) {
        return;
      }
      _scrollController.jumpTo(target.toDouble());
    });
  }

  String _aspectRatioCacheKey(String chapterUrl) {
    final digest = crypto.sha256.convert(utf8.encode(chapterUrl));
    return 'manga_page_ratios_v1_$digest';
  }

  Future<Map<int, double>> _loadAspectRatioCache(String chapterUrl) async {
    final raw = _storageService.getString(_aspectRatioCacheKey(chapterUrl));
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final result = <int, double>{};
      for (final entry in decoded.entries) {
        final index = int.tryParse(entry.key.toString());
        final ratio = (entry.value as num?)?.toDouble();
        if (index == null || ratio == null || ratio <= 0 || !ratio.isFinite) {
          continue;
        }
        result[index] = ratio;
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  Future<void> _saveAspectRatioCache() async {
    if (_pageAspectRatios.isEmpty) return;
    await _storageService.setString(
      _aspectRatioCacheKey(_currentChapter.url),
      jsonEncode({
        for (final entry in _pageAspectRatios.entries)
          entry.key.toString(): entry.value,
      }),
    );
  }

  double _estimatedPageHeight(int index) {
    return _layoutIndex.extentAt(index);
  }

  double _pageStartForIndex(int index) {
    return _layoutIndex.offsetOf(index);
  }

  void _resetLayoutIndex(int pageCount) {
    final width = _viewportWidth > 0 ? _viewportWidth : 390.0;
    _layoutIndex.reset(
      pageCount: pageCount,
      defaultExtent: width / _defaultPageAspectRatio,
    );
    for (var index = 0; index < pageCount; index++) {
      final aspectRatio = _pageAspectRatios[index];
      if (aspectRatio != null && aspectRatio > 0) {
        _layoutIndex.updateExtent(index, width / aspectRatio);
      }
    }
    for (final entry in _pageHeights.entries) {
      _layoutIndex.updateExtent(entry.key, entry.value);
    }
  }

  void _syncViewportWidth(double width) {
    if (width <= 0 || (_viewportWidth - width).abs() < 1) return;
    final preserveLocation =
        _viewportWidth > 0 &&
        _preferences.readingMode == MangaReadingMode.longStrip &&
        _scrollController.hasClients &&
        _images.isNotEmpty;
    final location = preserveLocation
        ? _layoutIndex.locationAt(_scrollController.offset)
        : null;
    final chapterUrl = _currentChapter.url;
    _viewportWidth = width;
    _pageHeights.clear();
    _resetLayoutIndex(_images.length);
    if (location == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          chapterUrl != _currentChapter.url ||
          !_scrollController.hasClients) {
        return;
      }
      final target =
          _pageStartForIndex(location.pageIndex) +
          _estimatedPageHeight(location.pageIndex) * location.pageOffsetRatio;
      _scrollController.jumpTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_saveHistory());
    });
  }

  Future<void> _saveHistory() async {
    if (_images.isEmpty) return;
    final isPaged = _preferences.readingMode == MangaReadingMode.paged;
    if (!isPaged && !_scrollController.hasClients) return;
    final position = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final location = isPaged
        ? (pageIndex: _currentPagedPageIndex, pageOffsetRatio: 0.0)
        : _currentPageLocation(position!.pixels);
    await _storageService.saveMangaReadHistory(
      MangaReadHistory(
        mangaId: widget.manga.id,
        title: widget.manga.title,
        coverUrl: widget.manga.coverUrl,
        chapterTitle: _currentChapter.title,
        chapterUrl: _currentChapter.url,
        chapterIndex: widget.historyChapterIndexOverride ?? _currentIndex,
        scrollOffset: isPaged
            ? _currentPagedPageIndex.toDouble()
            : position!.pixels,
        contentExtent: isPaged
            ? (_images.length - 1).clamp(0, _images.length).toDouble()
            : position!.maxScrollExtent,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        chapters: widget.historyChaptersOverride ?? widget.manga.chapters,
        pageIndex: location.pageIndex,
        pageOffsetRatio: location.pageOffsetRatio,
        pageCount: _images.length,
        chapterProgress: _chapterProgressPercent / 100,
      ),
    );
  }

  ({int pageIndex, double pageOffsetRatio}) _currentPageLocation(
    double scrollOffset,
  ) {
    final location = _layoutIndex.locationAt(scrollOffset);
    return (
      pageIndex: location.pageIndex,
      pageOffsetRatio: location.pageOffsetRatio,
    );
  }

  void _changeChapter(int offset) {
    final target = _currentIndex + offset;
    if (target < 0 || target >= _chapters.length) return;
    unawaited(_changeChapterTo(target));
  }

  Future<void> _changeChapterTo(int index) async {
    if (index < 0 ||
        index >= _chapters.length ||
        index == _currentIndex ||
        _isChangingChapter ||
        _isLoading) {
      return;
    }
    setState(() => _isChangingChapter = true);
    try {
      await _loadChapter(_chapters[index], index);
    } finally {
      if (mounted) setState(() => _isChangingChapter = false);
    }
  }

  Future<void> _showChapterSheet() async {
    setState(() => _showBars = true);
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppTheme.nightCard
          : Colors.white,
      builder: (context) {
        return SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '章节目录',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = _chapters[index];
                    final selected = index == _currentIndex;
                    return ListTile(
                      title: Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: selected
                          ? const Icon(
                              Icons.check,
                              color: AppTheme.primaryColor,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, index),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (selected == null || selected == _currentIndex) return;
    unawaited(_changeChapterTo(selected));
  }

  Future<bool> _ensureChapterUnlocked(
    int chapterIndex, {
    bool showError = false,
  }) async {
    final override = widget.canLoadChapterOverride;
    if (override != null) return override(chapterIndex);
    final canOpen = await ensureLoggedInForContent(
      context,
      allowed: chapterIndex == 0,
      title: '登录后继续阅读',
      message: '未登录可试看漫画第一章，登录后可继续阅读后续章节。',
    );
    if (!canOpen && showError && mounted) {
      setState(() {
        _isLoading = false;
        _images = [];
        _errorMessage = '登录后可继续阅读后续章节。';
        _showBars = true;
      });
    }
    return canOpen;
  }

  void _toggleBars() {
    if (_isLoading || _errorMessage != null) return;
    setState(() => _showBars = !_showBars);
  }

  void _openChapterComments() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommentThreadScreen(
          title: '${widget.manga.title} ${_currentChapter.title} 评论',
          targetType: 'manga',
          targetId: widget.manga.id,
          targetTitle: widget.manga.title,
          chapterId: _currentChapter.title,
          chapterTitle: _currentChapter.title,
        ),
      ),
    );
  }

  Future<void> _showDownloadOptions() async {
    if (_chapters.isEmpty) return;
    final selection = await showModalBottomSheet<_MangaDownloadSelection>(
      context: context,
      backgroundColor: const Color(0xFF202124),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.download_for_offline_outlined),
                  SizedBox(width: 10),
                  Text(
                    '下载漫画',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_border_rounded),
              title: const Text('当前话'),
              subtitle: Text(_currentChapter.title),
              onTap: () =>
                  Navigator.pop(context, _MangaDownloadSelection.current),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('后 10 话'),
              subtitle: Text('${_remainingChapterCount(10)} 话可加入队列'),
              enabled: _remainingChapterCount(10) > 0,
              onTap: () =>
                  Navigator.pop(context, _MangaDownloadSelection.next10),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_check_rounded),
              title: const Text('后 30 话'),
              subtitle: Text('${_remainingChapterCount(30)} 话可加入队列'),
              enabled: _remainingChapterCount(30) > 0,
              onTap: () =>
                  Navigator.pop(context, _MangaDownloadSelection.next30),
            ),
            ListTile(
              leading: const Icon(Icons.checklist_rounded),
              title: const Text('多选章节'),
              onTap: () =>
                  Navigator.pop(context, _MangaDownloadSelection.multiple),
            ),
            ListTile(
              leading: const Icon(Icons.library_add_check_rounded),
              title: const Text('缓存全本'),
              subtitle: Text('共 ${_chapters.length} 话，将显示空间预估并再次确认'),
              onTap: () => Navigator.pop(context, _MangaDownloadSelection.full),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || selection == null) return;

    List<int> indexes;
    switch (selection) {
      case _MangaDownloadSelection.current:
        indexes = <int>[_currentIndex];
      case _MangaDownloadSelection.next10:
        indexes = _nextChapterIndexes(10);
      case _MangaDownloadSelection.next30:
        indexes = _nextChapterIndexes(30);
      case _MangaDownloadSelection.multiple:
        indexes = await _showChapterDownloadMultiSelect();
      case _MangaDownloadSelection.full:
        indexes = List<int>.generate(_chapters.length, (index) => index);
        final averageBytes = await _estimatedMangaChapterBytes();
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认缓存全本？'),
            content: Text(
              '预计需要约 ${_formatDownloadBytes(averageBytes * indexes.length)}。'
              '实际大小取决于图片画质与章节页数，下载支持断点续传。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('加入下载队列'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
    }
    if (indexes.isEmpty || !mounted) return;
    final canDownload = await _ensureDownloadRangeUnlocked(indexes);
    if (!canDownload || !mounted) return;
    await _enqueueMangaDownloads(indexes);
  }

  int _remainingChapterCount(int requested) {
    return (_chapters.length - _currentIndex - 1).clamp(0, requested).toInt();
  }

  List<int> _nextChapterIndexes(int count) {
    final start = (_currentIndex + 1).clamp(0, _chapters.length).toInt();
    final end = (start + count).clamp(0, _chapters.length).toInt();
    return List<int>.generate(end - start, (offset) => start + offset);
  }

  Future<List<int>> _showChapterDownloadMultiSelect() async {
    final selected = <int>{_currentIndex};
    final result = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF202124),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: FractionallySizedBox(
            heightFactor: 0.86,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '选择章节 · ${selected.length}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setSheetState(() {
                          if (selected.length == _chapters.length) {
                            selected.clear();
                          } else {
                            selected.addAll(
                              List<int>.generate(
                                _chapters.length,
                                (index) => index,
                              ),
                            );
                          }
                        }),
                        child: Text(
                          selected.length == _chapters.length ? '取消全选' : '全选',
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: _chapters.length,
                    itemBuilder: (context, index) {
                      return CheckboxListTile(
                        value: selected.contains(index),
                        title: Text(_chapters[index].title),
                        secondary: Text('${index + 1}'),
                        onChanged: (checked) => setSheetState(() {
                          if (checked == true) {
                            selected.add(index);
                          } else {
                            selected.remove(index);
                          }
                        }),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.pop(
                              sheetContext,
                              (selected.toList()..sort()),
                            ),
                      child: Text('下载 ${selected.length} 话'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return result ?? const <int>[];
  }

  Future<bool> _ensureDownloadRangeUnlocked(List<int> indexes) async {
    if (indexes.every((index) => index == 0) ||
        context.read<InteractionAuthProvider>().isLoggedIn) {
      return true;
    }
    return ensureLoggedInForContent(
      context,
      allowed: false,
      title: '登录后批量下载',
      message: '登录后可下载第一话之外的漫画章节。',
    );
  }

  Future<int> _estimatedMangaChapterBytes() async {
    final manager = DownloadManagerService.instance;
    await manager.init();
    final samples = manager.items
        .where(
          (item) => item.type == LibraryItemType.manga && item.totalBytes > 0,
        )
        .map((item) => item.totalBytes)
        .toList(growable: false);
    if (samples.isEmpty) return 16 * 1024 * 1024;
    return (samples.reduce((left, right) => left + right) / samples.length)
        .round();
  }

  String _formatDownloadBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Future<void> _enqueueMangaDownloads(List<int> indexes) async {
    var completed = 0;
    StateSetter? updateDialog;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          updateDialog = setDialogState;
          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('加入下载队列'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: indexes.isEmpty ? null : completed / indexes.length,
                  ),
                  const SizedBox(height: 12),
                  Text('$completed/${indexes.length}'),
                ],
              ),
            ),
          );
        },
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    var failed = 0;
    for (final index in indexes) {
      try {
        await DownloadManagerService.instance.enqueueMangaChapter(
          manga: widget.manga,
          chapter: _chapters[index],
          chapterIndex: index,
        );
      } catch (_) {
        failed += 1;
      }
      completed += 1;
      updateDialog?.call(() {});
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? '已将 ${indexes.length} 话加入下载队列'
              : '已加入 ${indexes.length - failed} 话，$failed 话加入失败',
        ),
      ),
    );
  }

  int _currentSourcePageAnchor() {
    if (_images.isEmpty) return 0;
    if (_preferences.readingMode == MangaReadingMode.paged) {
      return _currentPagedPageIndex.clamp(0, _images.length - 1);
    }
    if (!_scrollController.hasClients) return 0;
    return _layoutIndex.indexAtOffset(
      _scrollController.offset +
          _scrollController.position.viewportDimension * 0.38,
    );
  }

  List<MangaPageSpread> _currentPageSpreads() {
    final width = _viewportWidth > 0
        ? _viewportWidth
        : MediaQuery.sizeOf(context).width;
    return _pagePipeline.build(
      pageCount: _images.length,
      viewportWidth: width,
      spreadMode: _preferences.spreadMode,
      direction: _preferences.pageDirection,
      viewportHeight: MediaQuery.sizeOf(context).height,
      aspectRatioAt: (index) =>
          _pageAspectRatios[index] ?? _defaultPageAspectRatio,
      splitWidePageIndexes: _splitWidePages,
      forcePairStartIndexes: _forcePairedPages,
      forceSinglePageIndexes: _forceSinglePages,
      swappedSpreadStartIndexes: _swappedSpreadStarts,
      safeBreakAfterIndexes: _safePageBreakAfterIndexes,
    );
  }

  MangaPageSpread? _currentPageSpread() {
    final spreads = _currentPageSpreads();
    if (spreads.isEmpty) return null;
    return spreads[_pagePipeline
        .spreadIndexForPage(spreads, _currentPagedPageIndex)
        .clamp(0, spreads.length - 1)];
  }

  void _toggleWidePageSplit() {
    final index = _currentSourcePageAnchor();
    final isWide =
        (_pageAspectRatios[index] ?? _defaultPageAspectRatio) >=
        _pagePipeline.widePageRatio;
    if (!isWide) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前页不是宽图')));
      return;
    }
    setState(() {
      if (!_splitWidePages.remove(index)) {
        _splitWidePages.add(index);
      }
      _forcePairedPages.remove(index);
      _forceSinglePages.remove(index);
      _currentPagedPageIndex = index;
    });
    _pageGeometryVersion.value += 1;
  }

  void _toggleCurrentSpreadPairing() {
    final spread = _currentPageSpread();
    if (spread == null) return;
    final distinctPages = spread.pageIndexes.toSet();
    if (spread.pageIndexes.length > 1 && distinctPages.length > 1) {
      setState(() {
        _forcePairedPages.remove(spread.firstSourceIndex);
        _swappedSpreadStarts.remove(spread.firstSourceIndex);
        _forceSinglePages.addAll(distinctPages);
        _currentPagedPageIndex = spread.firstSourceIndex;
      });
    } else {
      final start = spread.firstSourceIndex;
      if (start >= _images.length - 1) return;
      setState(() {
        _forceSinglePages.remove(start);
        _forceSinglePages.remove(start + 1);
        _splitWidePages.remove(start);
        _forcePairedPages.add(start);
        _currentPagedPageIndex = start;
      });
    }
    _pageGeometryVersion.value += 1;
  }

  void _swapCurrentSpreadPages() {
    final spread = _currentPageSpread();
    if (spread == null || spread.pageIndexes.length < 2) return;
    final start = spread.firstSourceIndex;
    setState(() {
      if (!_swappedSpreadStarts.remove(start)) {
        _swappedSpreadStarts.add(start);
      }
      _currentPagedPageIndex = start;
    });
    _pageGeometryVersion.value += 1;
  }

  void _toggleReadingMode() {
    final nextMode = _preferences.readingMode == MangaReadingMode.longStrip
        ? MangaReadingMode.paged
        : MangaReadingMode.longStrip;
    _applyPreferences(_preferences.copyWith(readingMode: nextMode));
  }

  void _applyPreferences(MangaReaderPreferences next) {
    if (!mounted) return;
    next = next.copyWith(
      spreadMode: MangaSpreadMode.single,
      autoRotateSpread: false,
    );
    final anchor = _currentSourcePageAnchor();
    final modeChanged = next.readingMode != _preferences.readingMode;
    final qualityChanged = next.imageQuality != _preferences.imageQuality;
    setState(() {
      _preferences = next;
      if (modeChanged) _zoomedLongStripPages.clear();
      _currentPagedPageIndex = anchor;
      _currentPagedLastPageIndex = anchor;
      _showBars = true;
    });
    unawaited(
      _storageService.setString(
        MangaReaderPreferences.storageKey,
        next.encode(),
      ),
    );
    unawaited(_syncPageOrientation(next));
    if (qualityChanged) {
      _evictTrackedPrefetches();
      _pageGeometryVersion.value += 1;
    }
    _refreshChapterProgress();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (next.readingMode == MangaReadingMode.longStrip &&
          _scrollController.hasClients) {
        _scrollController.jumpTo(
          _pageStartForIndex(
            anchor,
          ).clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      }
      if (modeChanged || qualityChanged) _prefetchNearCurrentLocation();
    });
  }

  Future<void> _syncPageOrientation(MangaReaderPreferences preferences) {
    return SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  Future<void> _showReaderSettings() {
    return ReaderModalSheet.show<void>(
      context,
      title: const Text('漫画阅读设置'),
      semanticLabel: '漫画阅读设置',
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void update(MangaReaderPreferences next) {
              _applyPreferences(next);
              setSheetState(() {});
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
              shrinkWrap: true,
              children: [
                _buildPreferenceChoices<MangaReadingMode>(
                  title: '阅读模式',
                  values: MangaReadingMode.values,
                  selected: _preferences.readingMode,
                  label: (value) =>
                      value == MangaReadingMode.longStrip ? '条漫' : '页漫',
                  onSelected: (value) =>
                      update(_preferences.copyWith(readingMode: value)),
                ),
                if (_preferences.readingMode == MangaReadingMode.paged) ...[
                  _buildPreferenceChoices<MangaPageDirection>(
                    title: '翻页方向',
                    values: MangaPageDirection.values,
                    selected: _preferences.pageDirection,
                    label: (value) =>
                        value == MangaPageDirection.ltr ? '从左到右' : '从右到左',
                    onSelected: (value) =>
                        update(_preferences.copyWith(pageDirection: value)),
                  ),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('双页模式暂时关闭'),
                    subtitle: Text('当前使用按大面积白色区域识别的页漫切分'),
                  ),
                  _buildManualSpreadControls(
                    onChanged: () => setSheetState(() {}),
                  ),
                ],
                _buildPreferenceChoices<MangaImageQuality>(
                  title: '图片画质',
                  values: MangaImageQuality.values,
                  selected: _preferences.imageQuality,
                  label: (value) => switch (value) {
                    MangaImageQuality.auto => '自动',
                    MangaImageQuality.high => '高清',
                    MangaImageQuality.original => '原图',
                  },
                  onSelected: (value) =>
                      update(_preferences.copyWith(imageQuality: value)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('夜间遮罩'),
                  subtitle: const Text('降低亮色漫画页面的刺眼程度'),
                  value: _preferences.nightMode,
                  onChanged: (value) =>
                      update(_preferences.copyWith(nightMode: value)),
                ),
                const SizedBox(height: 8),
                const Text(
                  '页漫支持双击缩放、双指缩放和放大拖动；缩放时不会误触翻页。',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildManualSpreadControls({required VoidCallback onChanged}) {
    final spread = _currentPageSpread();
    if (spread == null) return const SizedBox.shrink();
    final sourceIndex = spread.firstSourceIndex;
    final isWide =
        (_pageAspectRatios[sourceIndex] ?? _defaultPageAspectRatio) >=
        _pagePipeline.widePageRatio;
    final distinctCount = spread.pageIndexes.toSet().length;
    final splitWide = spread.pageIndexes.length == 2 && distinctCount == 1;
    final paired = spread.pageIndexes.length == 2 && distinctCount == 2;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '当前页排版',
              style: TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (isWide)
                OutlinedButton.icon(
                  onPressed: () {
                    _toggleWidePageSplit();
                    onChanged();
                  },
                  icon: Icon(
                    splitWide
                        ? Icons.fullscreen_rounded
                        : Icons.vertical_split_rounded,
                  ),
                  label: Text(splitWide ? '还原宽图' : '拆分宽图'),
                ),
              if (!splitWide && (paired || sourceIndex < _images.length - 1))
                OutlinedButton.icon(
                  onPressed: () {
                    _toggleCurrentSpreadPairing();
                    onChanged();
                  },
                  icon: Icon(
                    paired ? Icons.filter_1_outlined : Icons.menu_book_rounded,
                  ),
                  label: Text(paired ? '拆为单页' : '与下一页合并'),
                ),
              if (spread.pageIndexes.length == 2)
                OutlinedButton.icon(
                  onPressed: () {
                    _swapCurrentSpreadPages();
                    onChanged();
                  },
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('交换左右'),
                ),
              if (_splitWidePages.isNotEmpty ||
                  _forcePairedPages.isNotEmpty ||
                  _forceSinglePages.isNotEmpty ||
                  _swappedSpreadStarts.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _splitWidePages.clear();
                      _forcePairedPages.clear();
                      _forceSinglePages.clear();
                      _swappedSpreadStarts.clear();
                    });
                    _pageGeometryVersion.value += 1;
                    onChanged();
                  },
                  child: const Text('恢复自动排版'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreferenceChoices<T>({
    required String title,
    required Iterable<T> values,
    required T selected,
    required String Function(T value) label,
    required ValueChanged<T> onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in values)
                ChoiceChip(
                  label: Text(label(value)),
                  selected: value == selected,
                  onSelected: (_) => onSelected(value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;
    final canPrev = _currentIndex > 0 && !_isChangingChapter && !_isLoading;
    final canNext =
        _currentIndex >= 0 &&
        _currentIndex < _chapters.length - 1 &&
        !_isChangingChapter &&
        !_isLoading;

    final dimPages = _preferences.nightMode && !isNight;
    return ReaderShell(
      backgroundColor: isNight ? AppTheme.nightBackground : Colors.black,
      contentSemanticLabel: '漫画阅读内容',
      chromeVisible: _showBars,
      onContentTap: _preferences.readingMode == MangaReadingMode.longStrip
          ? _toggleBars
          : null,
      content: _buildBody(isNight),
      topChrome: _buildReaderTopControls(),
      bottomChrome: _buildReaderBottomControls(canPrev, canNext),
      progressHudPadding: EdgeInsets.only(
        right: 16,
        bottom: _showBars ? 74 : 16,
      ),
      progressHud: _images.isEmpty || _isLoading || _errorMessage != null
          ? null
          : _buildReaderProgressBadge(),
      overlays: [
        if (dimPages)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
            ),
          ),
      ],
    );
  }

  Widget _buildReaderTopControls() {
    return ReaderChrome.top(
      child: Row(
        children: [
          ReaderChromeAction(
            icon: Icons.arrow_back_rounded,
            label: '返回',
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.manga.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _currentChapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
          ReaderChromeAction(
            icon: Icons.list_rounded,
            label: '章节目录',
            onPressed: _chapters.isEmpty ? null : _showChapterSheet,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            color: const Color(0xFF202124),
            iconColor: Colors.white,
            onSelected: (value) {
              switch (value) {
                case 'download':
                  _showDownloadOptions();
                case 'comments':
                  _openChapterComments();
                case 'settings':
                  unawaited(_showReaderSettings());
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'download',
                child: ListTile(
                  textColor: Colors.white,
                  iconColor: Colors.white70,
                  leading: Icon(Icons.download_for_offline_outlined),
                  title: Text('下载漫画'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'comments',
                child: ListTile(
                  textColor: Colors.white,
                  iconColor: Colors.white70,
                  leading: Icon(Icons.chat_bubble_outline),
                  title: Text('章节评论'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  textColor: Colors.white,
                  iconColor: Colors.white70,
                  leading: Icon(Icons.tune_rounded),
                  title: Text('阅读设置'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReaderBottomControls(bool canPrev, bool canNext) {
    return ReaderChrome.bottom(
      child: Row(
        children: [
          ReaderChromeAction(
            icon: Icons.chevron_left_rounded,
            label: '上一章',
            onPressed: canPrev ? () => _changeChapter(-1) : null,
          ),
          Expanded(
            child: Text(
              '${_currentIndex + 1}/${_chapters.length} · ${_currentChapter.title}',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          ReaderChromeAction(
            icon: _preferences.readingMode == MangaReadingMode.longStrip
                ? Icons.view_stream_rounded
                : Icons.auto_stories_rounded,
            label: _preferences.readingMode == MangaReadingMode.longStrip
                ? '条漫模式'
                : '页漫模式',
            selected: _preferences.readingMode == MangaReadingMode.paged,
            onPressed: _toggleReadingMode,
          ),
          ReaderChromeAction(
            icon: Icons.tune_rounded,
            label: '阅读设置',
            onPressed: () => unawaited(_showReaderSettings()),
          ),
          ReaderChromeAction(
            icon: Icons.chevron_right_rounded,
            label: '下一章',
            onPressed: canNext ? () => _changeChapter(1) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildReaderProgressBadge() {
    return ValueListenableBuilder<int>(
      valueListenable: _chapterProgress,
      builder: (context, progress, _) => ReaderProgressHud(
        label: '$progress%',
        leading: Icon(
          _preferences.readingMode == MangaReadingMode.longStrip
              ? Icons.view_stream_rounded
              : Icons.auto_stories_rounded,
        ),
      ),
    );
  }

  Widget _buildBody(bool isNight) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 48),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _loadChapter(_currentChapter, _currentIndex),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _syncViewportWidth(constraints.maxWidth);
        if (_preferences.readingMode == MangaReadingMode.paged) {
          return _buildPagedReader(constraints.maxWidth);
        }
        return _buildLongStripReader();
      },
    );
  }

  Widget _buildLongStripReader() {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle) {
          _hasUserScrolledSinceChapterLoad = true;
          _scrollCorrectionGeneration++;
        }
        if (notification is ScrollUpdateNotification ||
            notification is UserScrollNotification) {
          _prefetchNearScrollOffset();
        }
        if (notification is ScrollEndNotification) {
          unawaited(_saveHistory());
        }
        return false;
      },
      child: ListView.builder(
        key: ValueKey('manga-chapter-${_currentChapter.url}'),
        controller: _scrollController,
        physics: _zoomedLongStripPages.isEmpty
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        scrollCacheExtent: const ScrollCacheExtent.viewport(1),
        itemCount: _images.length + 1,
        itemBuilder: (context, index) {
          if (index == _images.length) return _buildChapterEndSurface();
          return _ZoomableLongStripPage(
            key: ValueKey('manga-long-zoom-${_currentChapter.url}-$index'),
            onTap: _toggleBars,
            onZoomChanged: (zoomed) {
              final changed = zoomed
                  ? _zoomedLongStripPages.add(index)
                  : _zoomedLongStripPages.remove(index);
              if (changed && mounted) setState(() {});
            },
            child: _buildPageWidget(index, pageWidth: _viewportWidth),
          );
        },
      ),
    );
  }

  Widget _buildPagedReader(double viewportWidth) {
    return ValueListenableBuilder<int>(
      valueListenable: _pageGeometryVersion,
      builder: (context, geometryVersion, child) {
        final spreads = _pagePipeline.build(
          pageCount: _images.length,
          viewportWidth: viewportWidth,
          spreadMode: _preferences.spreadMode,
          direction: _preferences.pageDirection,
          viewportHeight: MediaQuery.sizeOf(context).height,
          aspectRatioAt: (index) =>
              _pageAspectRatios[index] ?? _defaultPageAspectRatio,
          splitWidePageIndexes: _splitWidePages,
          forcePairStartIndexes: _forcePairedPages,
          forceSinglePageIndexes: _forceSinglePages,
          swappedSpreadStartIndexes: _swappedSpreadStarts,
          safeBreakAfterIndexes: _safePageBreakAfterIndexes,
        );
        return ColoredBox(
          color: Colors.white,
          child: MangaPagedView(
            key: ValueKey('manga-paged-${_currentChapter.url}'),
            spreads: spreads,
            direction: _preferences.pageDirection,
            initialPageIndex: _currentPagedPageIndex,
            pageBuilder: (context, pageIndex, pageWidth) =>
                _buildPageWidget(pageIndex, pageWidth: pageWidth, paged: true),
            endBuilder: (_) => _buildChapterEndSurface(paged: true),
            onPageChanged: (firstPageIndex, lastPageIndex) {
              _currentPagedPageIndex = firstPageIndex;
              _currentPagedLastPageIndex = lastPageIndex;
              _refreshChapterProgress();
              _prefetchNearCurrentLocation();
              unawaited(_saveHistory());
            },
            onTap: _toggleBars,
          ),
        );
      },
    );
  }

  Widget _buildPageWidget(
    int index, {
    required double pageWidth,
    bool paged = false,
  }) {
    final customPage = widget.mangaPageBuilder?.call(
      context,
      _currentIndex,
      index,
      _images[index],
    );
    if (customPage != null) {
      return KeyedSubtree(
        key: ValueKey('${_currentChapter.url}|${_images[index]}'),
        child: customPage,
      );
    }
    return _MangaPageImage(
      key: ValueKey(
        '${_currentChapter.url}|${_images[index]}|${_preferences.imageQuality.code}|$paged',
      ),
      url: _images[index],
      referer: _currentChapter.url,
      index: index,
      cacheWidth: _targetDecodeWidth(pageWidth),
      aspectRatio: _pageAspectRatios[index] ?? _defaultPageAspectRatio,
      fillViewport: paged,
      useTiledDecoding:
          !paged && _preferences.imageQuality == MangaImageQuality.original,
      tileCacheKey:
          '${widget.manga.id}|${_currentChapter.url}|$index|${_images[index]}',
      onAspectRatioChanged: (ratio) {
        _updatePageAspectRatio(index, ratio);
      },
      onHeightChanged: (height) {
        if (!paged) _updatePageHeight(index, height);
      },
    );
  }

  Widget _buildChapterEndSurface({bool paged = false}) {
    final canNext =
        _currentIndex >= 0 &&
        _currentIndex < _chapters.length - 1 &&
        !_isChangingChapter;
    return ColoredBox(
      color: const Color(0xFF111214),
      child: SizedBox(
        height: paged ? double.infinity : 180,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_outline, color: Colors.white54),
                const SizedBox(height: 10),
                Text(
                  canNext ? '本章已读完' : '已读到最后一章',
                  style: const TextStyle(color: Colors.white70),
                ),
                if (canNext) ...[
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () => _changeChapter(1),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text('下一章 · ${_chapters[_currentIndex + 1].title}'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

ImageProvider _mangaPageImageProvider(
  String source, {
  required String referer,
  required int? cacheWidth,
  required String cacheName,
  required Duration cacheMaxAge,
}) {
  final localPath = _localMangaImagePath(source);
  final ImageProvider provider = localPath == null
      ? ExtendedNetworkImageProvider(
          source,
          headers: mangaImageHeaders(referer: referer),
          cache: true,
          retries: 3,
          timeLimit: const Duration(seconds: 15),
          cacheMaxAge: cacheMaxAge,
          imageCacheName: cacheName,
        )
      : ExtendedFileImageProvider(File(localPath));
  return ExtendedResizeImage.resizeIfNeeded(
    provider: provider,
    cacheWidth: cacheWidth,
  );
}

String? _localMangaImagePath(String source) {
  final uri = Uri.tryParse(source);
  if (uri?.scheme == 'file') {
    try {
      return uri!.toFilePath(windows: Platform.isWindows);
    } catch (_) {
      return null;
    }
  }
  if (uri?.scheme == 'http' || uri?.scheme == 'https') return null;
  if (source.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(source)) {
    return source;
  }
  return null;
}

enum _MangaDownloadSelection { current, next10, next30, multiple, full }

class _ZoomableLongStripPage extends StatefulWidget {
  const _ZoomableLongStripPage({
    super.key,
    required this.child,
    required this.onTap,
    required this.onZoomChanged,
  });

  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomableLongStripPage> createState() => _ZoomableLongStripPageState();
}

class _ZoomableLongStripPageState extends State<_ZoomableLongStripPage> {
  final TransformationController _transformationController =
      TransformationController();
  bool _zoomed = false;

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _reportZoom() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(zoomed);
  }

  void _toggleDoubleTapZoom() {
    _transformationController.value = _zoomed
        ? Matrix4.identity()
        : Matrix4.diagonal3Values(2.25, 2.25, 1);
    _reportZoom();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTap: _toggleDoubleTapZoom,
      child: InteractiveViewer(
        transformationController: _transformationController,
        alignment: Alignment.topCenter,
        minScale: 1,
        maxScale: 4,
        panEnabled: _zoomed,
        scaleEnabled: true,
        boundaryMargin: const EdgeInsets.all(48),
        onInteractionUpdate: (_) => _reportZoom(),
        onInteractionEnd: (_) => _reportZoom(),
        child: widget.child,
      ),
    );
  }
}

class _MangaPageImage extends StatefulWidget {
  const _MangaPageImage({
    super.key,
    required this.url,
    required this.referer,
    required this.index,
    required this.cacheWidth,
    required this.aspectRatio,
    this.fillViewport = false,
    this.useTiledDecoding = false,
    this.tileCacheKey,
    required this.onAspectRatioChanged,
    required this.onHeightChanged,
  });

  final String url;
  final String referer;
  final int index;
  final int? cacheWidth;
  final double aspectRatio;
  final bool fillViewport;
  final bool useTiledDecoding;
  final String? tileCacheKey;
  final ValueChanged<double> onAspectRatioChanged;
  final ValueChanged<double> onHeightChanged;

  @override
  State<_MangaPageImage> createState() => _MangaPageImageState();
}

class _MangaPageImageState extends State<_MangaPageImage> {
  static const double _tiledAspectRatioThreshold = 0.24;
  static const int _tiledMinSourceHeight = 8192;
  static const int _tiledMinPixels = 20 * 1024 * 1024;

  double _lastReportedHeight = 0;
  late double _resolvedAspectRatio;

  @override
  void initState() {
    super.initState();
    _resolvedAspectRatio = widget.aspectRatio;
  }

  @override
  void didUpdateWidget(covariant _MangaPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.aspectRatio - widget.aspectRatio).abs() >= 0.01) {
      _resolvedAspectRatio = widget.aspectRatio;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fillViewport) {
      return SizedBox.expand(child: _buildImage(double.infinity));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageHeight = constraints.maxWidth / _resolvedAspectRatio;
        if ((_lastReportedHeight - pageHeight).abs() >= 1) {
          _lastReportedHeight = pageHeight;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onHeightChanged(pageHeight);
          });
        }
        return SizedBox(
          width: double.infinity,
          height: pageHeight,
          child: _buildImage(pageHeight),
        );
      },
    );
  }

  Widget _buildImage(double height) {
    if (widget.useTiledDecoding &&
        !widget.fillViewport &&
        _resolvedAspectRatio <= _tiledAspectRatioThreshold) {
      return ColoredBox(
        color: Colors.white,
        child: MangaTiledImage(
          source: widget.url,
          referer: widget.referer,
          cacheKey: widget.tileCacheKey,
          initialAspectRatio: _resolvedAspectRatio,
          resolutionScale: 1.25,
          compressionQuality: 96,
          semanticLabel: '第 ${widget.index + 1} 页漫画',
          shouldUseTiling: (info) =>
              info.aspectRatio <= _tiledAspectRatioThreshold &&
              (info.height >= _tiledMinSourceHeight ||
                  info.pixelCount >= _tiledMinPixels),
          onSourceInfo: _applySourceDimensions,
          fallbackBuilder: (context, source, error) =>
              _buildBoundedImage(height),
          errorBuilder: (context, error, retry) => _buildRetryFailure(retry),
        ),
      );
    }
    return _buildBoundedImage(height);
  }

  Widget _buildBoundedImage(double height) {
    return ColoredBox(
      color: Colors.white,
      child: ExtendedImage(
        image: _mangaPageImageProvider(
          widget.url,
          referer: widget.referer,
          cacheWidth: widget.cacheWidth,
          cacheName: _MangaReaderScreenState._imageCacheName,
          cacheMaxAge: _MangaReaderScreenState._imageCacheMaxAge,
        ),
        enableLoadState: true,
        width: double.infinity,
        height: height,
        fit: BoxFit.contain,
        alignment: Alignment.topCenter,
        clearMemoryCacheIfFailed: true,
        clearMemoryCacheWhenDispose: true,
        filterQuality: FilterQuality.low,
        loadStateChanged: _handleLoadState,
      ),
    );
  }

  void _applySourceDimensions(MangaTileSourceInfo info) {
    final ratio = info.aspectRatio;
    if (!mounted || ratio <= 0 || !ratio.isFinite) return;
    if ((_resolvedAspectRatio - ratio).abs() >= 0.01) {
      setState(() => _resolvedAspectRatio = ratio);
    }
    widget.onAspectRatioChanged(ratio);
  }

  Widget _handleLoadState(ExtendedImageState state) {
    switch (state.extendedImageLoadState) {
      case LoadState.loading:
        return const ColoredBox(color: Color(0xFFF4F4F4));
      case LoadState.completed:
        final image = state.extendedImageInfo?.image;
        if (image != null && image.width > 0 && image.height > 0) {
          final ratio = image.width / image.height;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if ((_resolvedAspectRatio - ratio).abs() >= 0.01) {
              setState(() => _resolvedAspectRatio = ratio);
            }
            widget.onAspectRatioChanged(ratio);
          });
        }
        return state.completedWidget;
      case LoadState.failed:
        return _buildFailure(state);
    }
  }

  Widget _buildFailure(ExtendedImageState state) {
    return _buildRetryFailure(state.reLoadImage);
  }

  Widget _buildRetryFailure(VoidCallback retry) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, color: Colors.black38),
          const SizedBox(height: 8),
          Text(
            '第 ${widget.index + 1} 页加载失败',
            style: const TextStyle(color: Colors.black45, fontSize: 12),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
