import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../config/theme.dart';
import '../models/manga.dart';
import '../models/manga_read_history.dart';
import '../services/app_telemetry_service.dart';
import '../services/bounded_task_scheduler.dart';
import '../services/manga_service.dart';
import '../services/storage_service.dart';
import '../utils/auth_gate.dart';
import 'comment_thread_screen.dart';
import 'manga_screen.dart';

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

class _MangaReaderScreenState extends State<MangaReaderScreen> {
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
  Timer? _aspectRatioSaveTimer;
  double _viewportWidth = 0;
  int _chapterProgressPercent = 0;
  int _scrollCorrectionGeneration = 0;
  bool _hasUserScrolledSinceChapterLoad = false;
  bool _isChangingChapter = false;
  bool _isLoading = true;
  bool _showBars = true;
  String? _errorMessage;
  late final AppTelemetryScreenTrace _telemetryTrace;

  static const double _defaultPageAspectRatio = 0.68;
  static const String _imageCacheName = 'manga_reader_images';
  static const Duration _imageCacheMaxAge = Duration(days: 14);

  List<MangaChapter> get _chapters => widget.manga.chapters;

  Future<List<String>> _fetchChapterImages(MangaChapter chapter) {
    return widget.chapterImageLoader?.call(chapter) ??
        _service.fetchChapterImages(chapter);
  }

  @override
  void initState() {
    super.initState();
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
    _chapterLoadGeneration++;
    _saveTimer?.cancel();
    _aspectRatioSaveTimer?.cancel();
    unawaited(_saveAspectRatioCache());
    unawaited(_saveHistory());
    _scrollController.removeListener(_handleScrollChanged);
    _scrollController.dispose();
    _telemetryTrace.close(
      metadata: {
        'chapterIndex': _currentIndex,
        'pageCount': _images.length,
        'progressPercent': _chapterProgressPercent,
      },
    );
    super.dispose();
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
    if (!hadVisibleChapter) {
      setState(() {
        _currentChapter = chapter;
        _currentIndex = index;
        _images = [];
        _pageAspectRatios.clear();
        _pageHeights.clear();
        _prefetchedPages.clear();
        _chapterProgressPercent = 0;
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
      setState(() {
        _currentChapter = chapter;
        _currentIndex = index;
        _images = images;
        _pageAspectRatios.clear();
        _pageAspectRatios.addAll(cachedRatios);
        _pageHeights.clear();
        _prefetchedPages.clear();
        _chapterProgressPercent = 0;
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
          _prefetchNearScrollOffset();
        });
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
    _refreshChapterProgress();
  }

  void _refreshChapterProgress() {
    if (!mounted) return;
    final nextPercent = _currentChapterProgressPercent();
    if (nextPercent == _chapterProgressPercent) return;
    setState(() => _chapterProgressPercent = nextPercent);
  }

  int _currentChapterProgressPercent() {
    if (_images.isEmpty || !_scrollController.hasClients) return 0;
    final position = _scrollController.position;
    final maxOffset = position.maxScrollExtent;
    if (maxOffset <= 0) return position.pixels > 0 ? 100 : 0;
    return ((position.pixels / maxOffset) * 100).clamp(0.0, 100.0).round();
  }

  Future<void> _warmPageImage(String url, String referer) async {
    final provider = ExtendedNetworkImageProvider(
      url,
      headers: mangaImageHeaders(referer: referer),
      cache: true,
      retries: 3,
      timeLimit: const Duration(seconds: 15),
      cacheMaxAge: _imageCacheMaxAge,
      imageCacheName: _imageCacheName,
    );
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
    for (final delta in const [0, 1, -1, 2, -2]) {
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
    if (!_prefetchedPages.add(index)) return Future<void>.value();
    return _imagePrefetchScheduler.schedule(
      () => _loadPageImage(index, url, referer, generation),
      priority: priority,
    );
  }

  Future<void> _loadPageImage(
    int index,
    String url,
    String referer,
    int chapterLoadGeneration,
  ) async {
    if (!_isCurrentChapterLoad(chapterLoadGeneration) ||
        referer != _currentChapter.url) {
      return;
    }
    final provider = ExtendedNetworkImageProvider(
      url,
      headers: mangaImageHeaders(referer: referer),
      cache: true,
      retries: 3,
      timeLimit: const Duration(seconds: 15),
      cacheMaxAge: _imageCacheMaxAge,
      imageCacheName: _imageCacheName,
    );
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final completer = Completer<void>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, synchronousCall) {
        if (!_isCurrentChapterLoad(chapterLoadGeneration) ||
            referer != _currentChapter.url) {
          if (!completer.isCompleted) completer.complete();
          return;
        }
        final image = imageInfo.image;
        final width = image.width.toDouble();
        final height = image.height.toDouble();
        if (width > 0 && height > 0) {
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
    }
  }

  void _prefetchNearScrollOffset() {
    if (_images.isEmpty) return;
    final offset = _scrollController.hasClients
        ? _scrollController.position.pixels
        : 0.0;
    var pageStart = 0.0;
    var currentIndex = 0;
    for (var i = 0; i < _images.length; i++) {
      final pageHeight = _estimatedPageHeight(i);
      if (pageStart + pageHeight >= offset) {
        currentIndex = i;
        break;
      }
      pageStart += pageHeight;
    }
    final end = (currentIndex + 10).clamp(0, _images.length).toInt();
    for (var i = currentIndex; i < end; i++) {
      unawaited(
        _preloadPageImage(
          i,
          _images[i],
          _currentChapter.url,
          priority: 50 - (i - currentIndex),
        ),
      );
    }
  }

  void _updatePageAspectRatio(int index, double aspectRatio) {
    if (aspectRatio <= 0 || !aspectRatio.isFinite) return;
    final old = _pageAspectRatios[index];
    if (old != null && (old - aspectRatio).abs() < 0.01) return;
    if (!mounted) return;
    setState(() => _pageAspectRatios[index] = aspectRatio);
    _aspectRatioSaveTimer?.cancel();
    _aspectRatioSaveTimer = Timer(
      const Duration(milliseconds: 800),
      () => unawaited(_saveAspectRatioCache()),
    );
  }

  void _updatePageHeight(int index, double height) {
    if (height <= 0 || !height.isFinite) return;
    final oldHeight = _pageHeights[index];
    if (oldHeight == null || (oldHeight - height).abs() < 1) {
      _pageHeights[index] = height;
      return;
    }

    final pageStart = _pageStartForIndex(index);
    final delta = height - oldHeight;
    _pageHeights[index] = height;
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
    final measuredHeight = _pageHeights[index];
    if (measuredHeight != null) return measuredHeight;
    final width = _viewportWidth > 0 ? _viewportWidth : 390.0;
    final aspectRatio = _pageAspectRatios[index] ?? _defaultPageAspectRatio;
    return width / aspectRatio;
  }

  double _pageStartForIndex(int index) {
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _estimatedPageHeight(i);
    }
    return offset;
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_saveHistory());
    });
  }

  Future<void> _saveHistory() async {
    if (_images.isEmpty || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final location = _currentPageLocation(position.pixels);
    await _storageService.saveMangaReadHistory(
      MangaReadHistory(
        mangaId: widget.manga.id,
        title: widget.manga.title,
        coverUrl: widget.manga.coverUrl,
        chapterTitle: _currentChapter.title,
        chapterUrl: _currentChapter.url,
        chapterIndex: _currentIndex,
        scrollOffset: position.pixels,
        contentExtent: position.maxScrollExtent,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        chapters: widget.manga.chapters,
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
    var pageStart = 0.0;
    for (var i = 0; i < _images.length; i++) {
      final pageHeight = _estimatedPageHeight(i);
      if (scrollOffset <= pageStart + pageHeight || i == _images.length - 1) {
        final ratio = pageHeight <= 0
            ? 0.0
            : ((scrollOffset - pageStart) / pageHeight).clamp(0.0, 1.0);
        return (pageIndex: i, pageOffsetRatio: ratio.toDouble());
      }
      pageStart += pageHeight;
    }
    return (pageIndex: 0, pageOffsetRatio: 0);
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

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;
    final canPrev = _currentIndex > 0 && !_isChangingChapter && !_isLoading;
    final canNext =
        _currentIndex >= 0 &&
        _currentIndex < _chapters.length - 1 &&
        !_isChangingChapter &&
        !_isLoading;

    return Scaffold(
      backgroundColor: isNight ? AppTheme.nightBackground : Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleBars,
              child: Stack(
                children: [
                  Positioned.fill(child: _buildBody(isNight)),
                  if (_images.isNotEmpty &&
                      !_isLoading &&
                      _errorMessage == null)
                    _buildChapterProgressBadge(),
                ],
              ),
            ),
          ),
          if (_showBars) _buildTopControls(),
          if (_showBars) _buildBottomControls(canPrev, canNext),
        ],
      ),
    );
  }

  Widget _buildTopControls() {
    return Positioned(
      left: 0,
      top: 0,
      right: 0,
      child: Material(
        color: Colors.black,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.maybePop(context),
                  color: Colors.white,
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(
                    '${widget.manga.title} ${_currentChapter.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '章节评论',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CommentThreadScreen(
                          title:
                              '${widget.manga.title} ${_currentChapter.title} 评论',
                          targetType: 'manga',
                          targetId: widget.manga.id,
                          targetTitle: widget.manga.title,
                          chapterId: _currentChapter.title,
                          chapterTitle: _currentChapter.title,
                        ),
                      ),
                    );
                  },
                  color: Colors.white,
                  icon: const Icon(Icons.chat_bubble_outline),
                ),
                IconButton(
                  tooltip: '章节目录',
                  onPressed: _chapters.isEmpty ? null : _showChapterSheet,
                  color: Colors.white,
                  icon: const Icon(Icons.list),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls(bool canPrev, bool canNext) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: Colors.black,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 54,
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一章',
                  onPressed: canPrev ? () => _changeChapter(-1) : null,
                  icon: Icon(
                    Icons.chevron_left,
                    color: canPrev ? Colors.white : Colors.white38,
                  ),
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
                IconButton(
                  tooltip: '下一章',
                  onPressed: canNext ? () => _changeChapter(1) : null,
                  icon: Icon(
                    Icons.chevron_right,
                    color: canNext ? Colors.white : Colors.white38,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChapterProgressBadge() {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottom = _showBars ? bottomInset + 68.0 : bottomInset + 18.0;

    return Positioned(
      right: 16,
      bottom: bottom,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white24),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            child: Text(
              '$_chapterProgressPercent%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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
        _viewportWidth = constraints.maxWidth;
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
            padding: EdgeInsets.zero,
            scrollCacheExtent: const ScrollCacheExtent.viewport(3),
            itemCount: _images.length + 1,
            itemBuilder: (context, index) {
              if (index == _images.length) {
                return const SizedBox(height: 24);
              }
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
                key: ValueKey('${_currentChapter.url}|${_images[index]}'),
                url: _images[index],
                referer: _currentChapter.url,
                index: index,
                aspectRatio:
                    _pageAspectRatios[index] ?? _defaultPageAspectRatio,
                onAspectRatioChanged: (ratio) {
                  _updatePageAspectRatio(index, ratio);
                },
                onHeightChanged: (height) {
                  _updatePageHeight(index, height);
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _MangaPageImage extends StatefulWidget {
  const _MangaPageImage({
    super.key,
    required this.url,
    required this.referer,
    required this.index,
    required this.aspectRatio,
    required this.onAspectRatioChanged,
    required this.onHeightChanged,
  });

  final String url;
  final String referer;
  final int index;
  final double aspectRatio;
  final ValueChanged<double> onAspectRatioChanged;
  final ValueChanged<double> onHeightChanged;

  @override
  State<_MangaPageImage> createState() => _MangaPageImageState();
}

class _MangaPageImageState extends State<_MangaPageImage> {
  double _lastReportedHeight = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageHeight = constraints.maxWidth / widget.aspectRatio;
        if ((_lastReportedHeight - pageHeight).abs() >= 1) {
          _lastReportedHeight = pageHeight;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onHeightChanged(pageHeight);
          });
        }
        return SizedBox(
          width: double.infinity,
          height: pageHeight,
          child: ColoredBox(
            color: Colors.white,
            child: ExtendedImage.network(
              widget.url,
              cache: true,
              retries: 3,
              timeLimit: const Duration(seconds: 15),
              cacheMaxAge: _MangaReaderScreenState._imageCacheMaxAge,
              imageCacheName: _MangaReaderScreenState._imageCacheName,
              width: double.infinity,
              height: pageHeight,
              fit: BoxFit.contain,
              alignment: Alignment.topCenter,
              headers: mangaImageHeaders(referer: widget.referer),
              clearMemoryCacheIfFailed: true,
              filterQuality: FilterQuality.low,
              loadStateChanged: _handleLoadState,
            ),
          ),
        );
      },
    );
  }

  Widget _handleLoadState(ExtendedImageState state) {
    switch (state.extendedImageLoadState) {
      case LoadState.loading:
        return const ColoredBox(color: Color(0xFFF4F4F4));
      case LoadState.completed:
        final image = state.extendedImageInfo?.image;
        if (image != null && image.width > 0 && image.height > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              widget.onAspectRatioChanged(image.width / image.height);
            }
          });
        }
        return state.completedWidget;
      case LoadState.failed:
        return Center(
          child: Text(
            '第 ${widget.index + 1} 页加载失败',
            style: const TextStyle(color: Colors.black45, fontSize: 12),
          ),
        );
    }
  }
}
