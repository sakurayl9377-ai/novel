import 'dart:async';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../config/theme.dart';
import '../models/manga.dart';
import '../models/manga_read_history.dart';
import '../services/manga_service.dart';
import '../services/storage_service.dart';
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
  });

  final Manga manga;
  final MangaChapter chapter;
  final int chapterIndex;
  final double initialScrollOffset;
  final double? initialScrollProgress;
  final int initialPageIndex;
  final double initialPageOffsetRatio;

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends State<MangaReaderScreen> {
  final MangaService _service = MangaService();
  final StorageService _storageService = StorageService();
  final ScrollController _scrollController = ScrollController();

  Timer? _saveTimer;
  late MangaChapter _currentChapter;
  late int _currentIndex;
  List<String> _images = [];
  final Map<int, double> _pageAspectRatios = {};
  final Map<int, double> _pageHeights = {};
  final Set<int> _prefetchedPages = {};
  double _viewportWidth = 0;
  bool _isLoading = true;
  bool _showBars = true;
  String? _errorMessage;

  static const double _defaultPageAspectRatio = 0.68;
  static const String _imageCacheName = 'manga_reader_images';
  static const Duration _imageCacheMaxAge = Duration(days: 14);

  List<MangaChapter> get _chapters => widget.manga.chapters;

  @override
  void initState() {
    super.initState();
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
    _saveTimer?.cancel();
    unawaited(_saveHistory());
    _scrollController.dispose();
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
    _saveTimer?.cancel();
    if (_images.isNotEmpty) await _saveHistory();
    setState(() {
      _currentChapter = chapter;
      _currentIndex = index;
      _images = [];
      _pageAspectRatios.clear();
      _pageHeights.clear();
      _prefetchedPages.clear();
      _isLoading = true;
      _errorMessage = null;
      _showBars = true;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    try {
      final images = await _service.fetchChapterImages(chapter);
      if (!mounted) return;
      if (images.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = '章节图片解析失败，请稍后重试';
        });
        return;
      }
      setState(() {
        _images = images;
        _isLoading = false;
      });
      _restoreScroll(
        initialScrollOffset,
        progress: initialScrollProgress ?? widget.initialScrollProgress,
        pageIndex: initialPageIndex,
        pageOffsetRatio: initialPageOffsetRatio,
      );
      _startSaveTimer();
      unawaited(_saveHistory());
      unawaited(_preloadInitialPages(images, chapter.url));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _prefetchNearScrollOffset();
        unawaited(_preloadChapterImages(images, chapter.url));
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '章节加载失败，请稍后重试';
      });
    }
  }

  void _restoreScroll(
    double offset, {
    double? progress,
    int pageIndex = 0,
    double pageOffsetRatio = 0,
  }) {
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
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
  }

  void _cancelRestoreScroll() {}

  Future<void> _preloadInitialPages(List<String> images, String referer) async {
    final count = images.length < 4 ? images.length : 4;
    if (count <= 0) return;
    try {
      await Future.wait([
        for (var i = 0; i < count; i++)
          _preloadPageImage(i, images[i], referer),
      ]).timeout(const Duration(seconds: 5));
    } catch (_) {
      // A slow first page should not block opening the chapter indefinitely.
    }
  }

  Future<void> _preloadChapterImages(
    List<String> images,
    String referer,
  ) async {
    const batchSize = 6;
    for (var start = 0; start < images.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, images.length).toInt();
      await Future.wait([
        for (var i = start; i < end; i++)
          _preloadPageImage(i, images[i], referer),
      ]);
    }
  }

  Future<void> _preloadPageImage(int index, String url, String referer) async {
    if (!_prefetchedPages.add(index)) return;
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
        final image = imageInfo.image;
        final width = image.width.toDouble();
        final height = image.height.toDouble();
        if (width > 0 && height > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _updatePageAspectRatio(index, width / height);
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
      unawaited(_preloadPageImage(i, _images[i], _currentChapter.url));
    }
  }

  void _updatePageAspectRatio(int index, double aspectRatio) {
    if (aspectRatio <= 0 || !aspectRatio.isFinite) return;
    final old = _pageAspectRatios[index];
    if (old != null && (old - aspectRatio).abs() < 0.01) return;
    if (!mounted) return;
    setState(() => _pageAspectRatios[index] = aspectRatio);
  }

  void _updatePageHeight(int index, double height) {
    if (height <= 0 || !height.isFinite) return;

    final oldHeight = _pageHeights[index];
    if (oldHeight == null) {
      _pageHeights[index] = height;
      return;
    }

    final delta = height - oldHeight;
    if (delta.abs() < 1) {
      _pageHeights[index] = height;
      return;
    }

    final pageStart = _pageStartForIndex(index);
    _pageHeights[index] = height;

    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final currentOffset = position.pixels;
    if (pageStart >= currentOffset) return;

    final correction = pageStart + oldHeight <= currentOffset
        ? delta
        : delta * ((currentOffset - pageStart) / oldHeight).clamp(0.0, 1.0);
    if (correction.abs() < 1) return;

    final target = (currentOffset + correction).clamp(
      0.0,
      position.maxScrollExtent,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(target.toDouble());
    });
  }

  double _pageStartForIndex(int index) {
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _estimatedPageHeight(i);
    }
    return offset;
  }

  double _estimatedPageHeight(int index) {
    final measuredHeight = _pageHeights[index];
    if (measuredHeight != null) return measuredHeight;
    final width = _viewportWidth > 0 ? _viewportWidth : 390.0;
    final aspectRatio = _pageAspectRatios[index] ?? _defaultPageAspectRatio;
    return width / aspectRatio;
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
    unawaited(_loadChapter(_chapters[target], target));
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
    unawaited(_loadChapter(_chapters[selected], selected));
  }

  void _toggleBars() {
    if (_isLoading || _errorMessage != null) return;
    setState(() => _showBars = !_showBars);
  }

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;
    final canPrev = _currentIndex > 0;
    final canNext = _currentIndex >= 0 && _currentIndex < _chapters.length - 1;

    return Scaffold(
      backgroundColor: isNight ? AppTheme.nightBackground : Colors.black,
      appBar: _showBars
          ? AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(
                '${widget.manga.title} ${_currentChapter.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  tooltip: '章节目录',
                  onPressed: _chapters.isEmpty ? null : _showChapterSheet,
                  icon: const Icon(Icons.list),
                ),
              ],
            )
          : null,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleBars,
        child: _buildBody(isNight),
      ),
      bottomNavigationBar: _showBars
          ? SafeArea(
              top: false,
              child: Container(
                height: 54,
                color: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 8),
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
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
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
            )
          : null,
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
            _cancelRestoreScroll();
            if (notification is ScrollUpdateNotification ||
                notification is UserScrollNotification) {
              _prefetchNearScrollOffset();
            }
            return false;
          },
          child: ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.zero,
            scrollCacheExtent: const ScrollCacheExtent.viewport(3),
            itemCount: _images.length + 1,
            itemBuilder: (context, index) {
              if (index == _images.length) {
                return const SizedBox(height: 24);
              }
              return _MangaPageImage(
                url: _images[index],
                referer: _currentChapter.url,
                index: index,
                aspectRatio:
                    _pageAspectRatios[index] ?? _defaultPageAspectRatio,
                onAspectRatioChanged: (aspectRatio) {
                  _updatePageAspectRatio(index, aspectRatio);
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
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImageAspectRatio();
  }

  @override
  void didUpdateWidget(covariant _MangaPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.referer != widget.referer) {
      _resolveImageAspectRatio();
    }
  }

  @override
  void dispose() {
    _removeImageStreamListener();
    super.dispose();
  }

  void _resolveImageAspectRatio() {
    _removeImageStreamListener();
    final provider = ExtendedNetworkImageProvider(
      widget.url,
      headers: mangaImageHeaders(referer: widget.referer),
      cache: true,
      retries: 3,
      timeLimit: const Duration(seconds: 15),
      cacheMaxAge: _MangaReaderScreenState._imageCacheMaxAge,
      imageCacheName: _MangaReaderScreenState._imageCacheName,
    );
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((imageInfo, synchronousCall) {
      final image = imageInfo.image;
      final width = image.width.toDouble();
      final height = image.height.toDouble();
      if (width > 0 && height > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onAspectRatioChanged(width / height);
        });
      }
    }, onError: (exception, stackTrace) {});
    stream.addListener(listener);
    _imageStream = stream;
    _imageStreamListener = listener;
  }

  void _removeImageStreamListener() {
    final listener = _imageStreamListener;
    if (listener != null) {
      _imageStream?.removeListener(listener);
    }
    _imageStream = null;
    _imageStreamListener = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageWidth = constraints.maxWidth;
        final pageHeight = pageWidth / widget.aspectRatio;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onHeightChanged(pageHeight);
        });

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
              filterQuality: FilterQuality.medium,
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
        return _MangaPagePlaceholder(index: widget.index);
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
        return _MangaPagePlaceholder(
          index: widget.index,
          message: '第 ${widget.index + 1} 页加载失败',
        );
    }
  }
}

class _MangaPagePlaceholder extends StatelessWidget {
  const _MangaPagePlaceholder({required this.index, this.message});

  final int index;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final errorMessage = message;
    return ColoredBox(
      color: const Color(0xFFF4F4F4),
      child: Center(
        child: errorMessage == null
            ? const SizedBox.shrink()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.black38,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    errorMessage,
                    style: const TextStyle(color: Colors.black45, fontSize: 12),
                  ),
                ],
              ),
      ),
    );
  }
}
