import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:page_flip/page_flip.dart';
import 'package:provider/provider.dart';
import '../models/reading_settings.dart';
import '../providers/reading_provider.dart';

class _PageChunk {
  final String text;
  final int startOffset;

  const _PageChunk(this.text, this.startOffset);
}

class PageTurnView extends StatefulWidget {
  final String content;
  final Widget Function(String pageContent, int pageStartOffset) pageBuilder;
  final int totalPages;
  final int currentPage;
  final double fontSize;
  final double lineHeight;
  final int? activeTextOffset;
  final int? initialTextOffset;
  final double initialScrollPosition;
  final void Function(int pageIndex, int charPosition, double scrollPosition)?
  onReadingPositionChanged;
  final void Function(int pageIndex, int charPosition, double scrollPosition)?
  onReadingPositionSettled;
  final VoidCallback? onNeedNextChapter;
  final VoidCallback? onNeedPrevChapter;
  final bool isNightMode;
  final VoidCallback? onTap;

  const PageTurnView({
    super.key,
    required this.content,
    required this.pageBuilder,
    required this.totalPages,
    required this.currentPage,
    required this.fontSize,
    required this.lineHeight,
    this.activeTextOffset,
    this.initialTextOffset,
    this.initialScrollPosition = 0,
    this.onReadingPositionChanged,
    this.onReadingPositionSettled,
    this.onNeedNextChapter,
    this.onNeedPrevChapter,
    this.isNightMode = false,
    this.onTap,
  });

  @override
  State<PageTurnView> createState() => _PageTurnViewState();
}

class _PageTurnViewState extends State<PageTurnView>
    with SingleTickerProviderStateMixin {
  final List<_PageChunk> _pages = [];
  final List<GlobalKey> _pageKeys = [];
  final GlobalKey _scrollViewportKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  final PageFlipController _pageFlipController = PageFlipController();
  late AnimationController _flipAnimationController;
  late Animation<double> _flipAnimation;

  int _currentPageIndex = 0;
  bool _isChangingChapter = false;
  bool _isReversing = false;
  bool _didRequestNextFromScroll = false;
  bool _isSyncingPageFlip = false;
  static const double _activeScrollAnchorFraction = 0.45;

  Color _parseColor(String hex) {
    var value = hex.replaceAll('#', '');
    if (value.length == 6) value = 'FF$value';
    return Color(int.parse(value, radix: 16));
  }

  @override
  void initState() {
    super.initState();
    _flipAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _flipAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _flipAnimationController,
        curve: Curves.easeOutCubic,
      ),
    );
    _splitPages();
    _currentPageIndex = _pageIndexForOffset(
      widget.initialTextOffset ?? _initialPageStartOffset(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncScrollToCurrentPosition(jump: true);
    });
  }

  @override
  void didUpdateWidget(PageTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.lineHeight != widget.lineHeight) {
      _splitPages();
      _isChangingChapter = false;
      setState(() {
        _currentPageIndex = _pageIndexForOffset(
          widget.initialTextOffset ?? _initialPageStartOffset(),
        );
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncScrollToCurrentPosition(jump: true);
      });
    }
    if (oldWidget.activeTextOffset != widget.activeTextOffset) {
      _syncToActiveOffset();
    }
  }

  void _splitPages() {
    _pages.clear();
    if (widget.content.isEmpty) {
      _pages.add(const _PageChunk('暂无内容', 0));
      _syncPageKeys();
      return;
    }

    final charsPerPage =
        (500 *
                (18 / widget.fontSize).clamp(0.65, 1.35) *
                (1.6 / widget.lineHeight).clamp(0.75, 1.2))
            .clamp(220, 650)
            .round();
    final paragraphs = widget.content.split('\n');

    String currentPage = '';
    int currentStart = 0;
    int cursor = 0;
    for (final para in paragraphs) {
      if ((currentPage.length + para.length) > charsPerPage * 1.5 &&
          currentPage.isNotEmpty) {
        _pages.add(_PageChunk(currentPage, currentStart));
        currentPage = para;
        currentStart = cursor;
      } else {
        currentPage += (currentPage.isEmpty ? '' : '\n') + para;
      }
      cursor += para.length + 1;
    }
    if (currentPage.isNotEmpty) {
      _pages.add(_PageChunk(currentPage, currentStart));
    }
    if (_pages.isEmpty) {
      _pages.add(_PageChunk(widget.content, 0));
    }
    _syncPageKeys();
  }

  void _syncPageKeys() {
    while (_pageKeys.length < _pages.length) {
      _pageKeys.add(GlobalKey());
    }
    if (_pageKeys.length > _pages.length) {
      _pageKeys.removeRange(_pages.length, _pageKeys.length);
    }
  }

  int _pageIndexForOffset(int offset) {
    for (var i = _pages.length - 1; i >= 0; i--) {
      if (offset >= _pages[i].startOffset) return i;
    }
    return 0;
  }

  int _pageStartOffsetForCurrentPage() {
    if (_pages.isEmpty) return 0;
    final safePageIndex = _currentPageIndex.clamp(0, _pages.length - 1).toInt();
    return _pages[safePageIndex].startOffset;
  }

  int _initialPageStartOffset() {
    if (_pages.isEmpty) return 0;
    final safePageIndex = widget.currentPage
        .clamp(0, _pages.length - 1)
        .toInt();
    return _pages[safePageIndex].startOffset;
  }

  void _notifyReadingPosition({bool settled = true}) {
    if (_pages.isEmpty) return;
    final readingProvider = context.read<ReadingProvider>();
    if (readingProvider.settings.pageTurnMode ==
            ReadingSettings.defaultPageTurnMode &&
        _scrollController.hasClients &&
        _scrollController.position.maxScrollExtent > 0) {
      final position = _scrollController.position;
      final ratio = (position.pixels / position.maxScrollExtent).clamp(
        0.0,
        1.0,
      );
      final activeOffset = widget.activeTextOffset;
      final charPosition = activeOffset != null && activeOffset >= 0
          ? activeOffset.clamp(0, widget.content.length).toInt()
          : (ratio * widget.content.length).round();
      final pageIndex = _pageIndexForOffset(charPosition);
      final scrollPosition = position.pixels;
      widget.onReadingPositionChanged?.call(
        pageIndex,
        charPosition,
        scrollPosition,
      );
      if (settled) {
        widget.onReadingPositionSettled?.call(
          pageIndex,
          charPosition,
          scrollPosition,
        );
      }
      return;
    }

    final pageIndex = _currentPageIndex.clamp(0, _pages.length - 1).toInt();
    final charPosition = _pages[pageIndex].startOffset;
    widget.onReadingPositionChanged?.call(pageIndex, charPosition, 0);
    if (settled) {
      widget.onReadingPositionSettled?.call(pageIndex, charPosition, 0);
    }
  }

  void _syncScrollToCurrentPosition({required bool jump}) {
    final readingProvider = context.read<ReadingProvider>();
    if (readingProvider.settings.pageTurnMode !=
        ReadingSettings.defaultPageTurnMode) {
      return;
    }
    if (!_scrollController.hasClients || widget.content.isEmpty) return;

    final position = _scrollController.position;
    final targetOffset =
        widget.initialTextOffset ?? _pageStartOffsetForCurrentPage();
    final hasSavedScroll = widget.initialScrollPosition > 0 && targetOffset > 0;
    _currentPageIndex = _pageIndexForOffset(targetOffset);
    final target = hasSavedScroll
        ? widget.initialScrollPosition.clamp(0.0, position.maxScrollExtent)
        : (targetOffset / widget.content.length).clamp(0.0, 1.0) *
              position.maxScrollExtent;
    if (jump) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  double _activeOffsetScrollTarget(ScrollPosition position, int activeOffset) {
    final measuredTarget = _measuredActiveOffsetScrollTarget(
      position,
      activeOffset,
    );
    if (measuredTarget != null) return measuredTarget;

    final ratio = (activeOffset / widget.content.length).clamp(0.0, 1.0);
    final contentExtent = position.maxScrollExtent + position.viewportDimension;
    final target =
        ratio * contentExtent -
        position.viewportDimension * _activeScrollAnchorFraction;
    return target.clamp(0.0, position.maxScrollExtent).toDouble();
  }

  double? _measuredActiveOffsetScrollTarget(
    ScrollPosition position,
    int activeOffset,
  ) {
    final pageIndex = _pageIndexForOffset(
      activeOffset,
    ).clamp(0, _pages.length - 1).toInt();
    if (pageIndex >= _pageKeys.length) return null;

    final pageContext = _pageKeys[pageIndex].currentContext;
    final viewportContext = _scrollViewportKey.currentContext;
    final pageRender = pageContext?.findRenderObject();
    final viewportRender = viewportContext?.findRenderObject();
    if (pageRender is! RenderBox ||
        viewportRender is! RenderBox ||
        !pageRender.hasSize ||
        !viewportRender.hasSize) {
      return null;
    }

    final page = _pages[pageIndex];
    final localRatio = page.text.isEmpty
        ? 0.0
        : ((activeOffset - page.startOffset) / page.text.length)
              .clamp(0.0, 1.0)
              .toDouble();
    final pageTop = pageRender
        .localToGlobal(Offset.zero, ancestor: viewportRender)
        .dy;
    final activeY = pageTop + pageRender.size.height * localRatio;
    final target =
        position.pixels +
        activeY -
        position.viewportDimension * _activeScrollAnchorFraction;
    return target.clamp(0.0, position.maxScrollExtent).toDouble();
  }

  void _syncToActiveOffset() {
    final activeOffset = widget.activeTextOffset;
    if (activeOffset == null || activeOffset < 0 || _pages.isEmpty) return;

    final readingProvider = context.read<ReadingProvider>();
    if (readingProvider.settings.pageTurnMode ==
        ReadingSettings.defaultPageTurnMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients || widget.content.isEmpty) return;
        final position = _scrollController.position;
        final target = _activeOffsetScrollTarget(position, activeOffset);
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      });
      return;
    }

    final targetPage = _pageIndexForOffset(activeOffset);
    if (targetPage != _currentPageIndex && mounted) {
      setState(() => _currentPageIndex = targetPage);
      if (readingProvider.settings.pageTurnMode == '仿真') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _isSyncingPageFlip = true;
          _pageFlipController.goToPage(_currentPageIndex);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _isSyncingPageFlip = false;
          });
        });
      } else {
        _flipAnimationController.reset();
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _flipAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final readingProvider = context.watch<ReadingProvider>();
    final savedPageTurnMode = readingProvider.settings.pageTurnMode;
    final pageTurnMode =
        ReadingSettings.pageTurnModes.contains(savedPageTurnMode)
        ? savedPageTurnMode
        : ReadingSettings.defaultPageTurnMode;

    return _buildPageView(pageTurnMode);
  }

  Widget _buildPageView(String mode) {
    switch (mode) {
      case '仿真':
        return _buildSimulationMode();
      case '覆盖':
        return _buildCoverMode();
      case ReadingSettings.defaultPageTurnMode:
        return _buildScrollView();
      case '平移':
        return _buildSlideMode();
      default:
        return _buildScrollView();
    }
  }

  Widget _buildScrollView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) =>
              _handleTapUp(details, viewSize, allowEdgePageTurn: false),
          child: NotificationListener<ScrollNotification>(
            onNotification: _handleScrollNotification,
            child: SizedBox.expand(
              key: _scrollViewportKey,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < _pages.length; i++)
                      KeyedSubtree(
                        key: _pageKeys[i],
                        child: widget.pageBuilder(
                          _pages[i].text,
                          _pages[i].startOffset,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleTapUp(
    TapUpDetails details,
    Size viewSize, {
    bool allowEdgePageTurn = true,
  }) {
    _handleTapPosition(
      details.localPosition,
      viewSize,
      allowEdgePageTurn: allowEdgePageTurn,
    );
  }

  void _handleTapPosition(
    Offset position,
    Size viewSize, {
    bool allowEdgePageTurn = true,
  }) {
    if (_flipAnimationController.isAnimating || _isChangingChapter) return;

    final centerLeft = viewSize.width * 0.32;
    final centerRight = viewSize.width * 0.68;
    final centerTop = viewSize.height * 0.16;
    final centerBottom = viewSize.height * 0.84;
    final isCenterTap =
        position.dx >= centerLeft &&
        position.dx <= centerRight &&
        position.dy >= centerTop &&
        position.dy <= centerBottom;

    if (isCenterTap) {
      widget.onTap?.call();
      return;
    }

    if (!allowEdgePageTurn) return;
    if (position.dx < centerLeft) {
      _goBackward();
    } else if (position.dx > centerRight) {
      _goForward();
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.metrics.maxScrollExtent <= 0) {
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      _notifyReadingPosition(settled: false);
    } else if (notification is ScrollEndNotification ||
        (notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle)) {
      _notifyReadingPosition(settled: true);
    }

    final isAtBottom =
        notification.metrics.pixels >=
        notification.metrics.maxScrollExtent - 12;
    final isDraggingDown =
        _scrollController.position.userScrollDirection ==
        ScrollDirection.reverse;
    if (!isAtBottom) {
      _didRequestNextFromScroll = false;
    } else if (isDraggingDown && !_didRequestNextFromScroll) {
      _didRequestNextFromScroll = true;
      widget.onNeedNextChapter?.call();
    }
    return false;
  }

  // ==================== 仿真翻页模式 ====================
  Widget _buildSimulationMode() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        final settings = context.read<ReadingProvider>().settings;
        final pageColor = _parseColor(settings.backgroundColor);
        final currentPageIndex = _currentPageIndex
            .clamp(0, _pages.length - 1)
            .toInt();

        return Stack(
          children: [
            Positioned.fill(
              child: PageFlipWidget(
                key: ValueKey(
                  'page-flip-${widget.content.hashCode}-${widget.fontSize}-${widget.lineHeight}-${_pages.length}',
                ),
                controller: _pageFlipController,
                duration: const Duration(milliseconds: 520),
                backgroundColor: pageColor,
                initialIndex: currentPageIndex,
                isRightSwipe: false,
                onPageFlipped: _handlePageFlipped,
                children: [
                  for (final page in _pages)
                    _buildPageWidget(page, expand: true),
                ],
              ),
            ),
            Positioned(
              left: viewSize.width * 0.32,
              right: viewSize.width * 0.32,
              top: viewSize.height * 0.16,
              bottom: viewSize.height * 0.16,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: widget.onTap,
              ),
            ),
          ],
        );
      },
    );
  }

  void _handlePageFlipped(int pageNumber) {
    if (_isSyncingPageFlip) return;
    if (_pages.isEmpty) return;
    _currentPageIndex = pageNumber.clamp(0, _pages.length - 1).toInt();
    _notifyReadingPosition();
  }

  // ==================== 覆盖模式 ====================
  Widget _buildCoverMode() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        final currentPageIndex = _currentPageIndex
            .clamp(0, _pages.length - 1)
            .toInt();
        final underneathPageIndex = _isReversing
            ? (currentPageIndex > 0 ? currentPageIndex - 1 : currentPageIndex)
            : (currentPageIndex < _pages.length - 1
                  ? currentPageIndex + 1
                  : currentPageIndex);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _handleTapUp(details, viewSize),
          onHorizontalDragEnd: (details) {
            if (_flipAnimationController.isAnimating || _isChangingChapter) {
              return;
            }
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -500) {
              _goForward();
            } else if (velocity > 500) {
              _goBackward();
            }
          },
          onVerticalDragEnd: (details) {
            if (_flipAnimationController.isAnimating || _isChangingChapter) {
              return;
            }
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -500) {
              _goForward();
            } else if (velocity > 500) {
              _goBackward();
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildPageWidget(
                  _pages[underneathPageIndex],
                  expand: true,
                ),
              ),
              AnimatedBuilder(
                animation: _flipAnimationController,
                builder: (context, child) {
                  final offset = _isReversing
                      ? constraints.maxWidth * _flipAnimation.value
                      : -constraints.maxWidth * _flipAnimation.value;
                  return Transform.translate(
                    offset: Offset(offset, 0),
                    child: ClipRect(
                      child: _buildPageWidget(
                        _pages[currentPageIndex],
                        expand: true,
                      ),
                    ),
                  );
                },
              ),
              // 阴影
              AnimatedBuilder(
                animation: _flipAnimationController,
                builder: (context, child) {
                  if (_flipAnimation.value > 0) {
                    return Positioned(
                      left: _isReversing ? 0 : null,
                      right: _isReversing ? null : 0,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: _isReversing
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            end: _isReversing
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            colors: [
                              Colors.black.withValues(
                                alpha: 0.15 * (1 - _flipAnimation.value),
                              ),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ==================== 平移模式 ====================
  Widget _buildSlideMode() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        final currentPageIndex = _currentPageIndex
            .clamp(0, _pages.length - 1)
            .toInt();
        final underneathPageIndex = _isReversing
            ? (currentPageIndex > 0 ? currentPageIndex - 1 : currentPageIndex)
            : (currentPageIndex < _pages.length - 1
                  ? currentPageIndex + 1
                  : currentPageIndex);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _handleTapUp(details, viewSize),
          onHorizontalDragEnd: (details) {
            if (_flipAnimationController.isAnimating || _isChangingChapter) {
              return;
            }
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -500) {
              _goForward();
            } else if (velocity > 500) {
              _goBackward();
            }
          },
          onVerticalDragEnd: (details) {
            if (_flipAnimationController.isAnimating || _isChangingChapter) {
              return;
            }
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -500) {
              _goForward();
            } else if (velocity > 500) {
              _goBackward();
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(
                    (_isReversing ? -1 : 1) *
                        constraints.maxWidth *
                        (1 - _flipAnimation.value),
                    0,
                  ),
                  child: _buildPageWidget(
                    _pages[underneathPageIndex],
                    expand: true,
                  ),
                ),
              ),
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(
                    (_isReversing ? 1 : -1) *
                        constraints.maxWidth *
                        _flipAnimation.value,
                    0,
                  ),
                  child: _buildPageWidget(
                    _pages[currentPageIndex],
                    expand: true,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==================== 翻页逻辑 ====================
  void _goForward() {
    if (_flipAnimationController.isAnimating || _isChangingChapter) return;
    final isSimulationMode =
        context.read<ReadingProvider>().settings.pageTurnMode == '仿真';
    if (_currentPageIndex < _pages.length - 1) {
      if (isSimulationMode) {
        _pageFlipController.nextPage();
        return;
      }
      _isReversing = false;
      _flipAnimationController.forward().then((_) {
        if (mounted) {
          setState(() {
            _currentPageIndex++;
          });
          _notifyReadingPosition();
          _flipAnimationController.reset();
        }
      });
    } else {
      _isChangingChapter = true;
      widget.onNeedNextChapter?.call();
    }
  }

  void _goBackward() {
    if (_flipAnimationController.isAnimating || _isChangingChapter) return;
    final isSimulationMode =
        context.read<ReadingProvider>().settings.pageTurnMode == '仿真';
    if (_currentPageIndex > 0) {
      if (isSimulationMode) {
        _pageFlipController.previousPage();
        return;
      }
      _isReversing = true;
      _flipAnimationController.forward(from: 0).then((_) {
        if (mounted) {
          setState(() {
            _currentPageIndex--;
            _isReversing = false;
          });
          _notifyReadingPosition();
          _flipAnimationController.reset();
        }
      });
    } else {
      _isChangingChapter = true;
      widget.onNeedPrevChapter?.call();
    }
  }

  Widget _buildPageWidget(_PageChunk pageChunk, {bool expand = false}) {
    final settings = context.read<ReadingProvider>().settings;
    final page = ColoredBox(
      color: _parseColor(settings.backgroundColor),
      child: widget.pageBuilder(pageChunk.text, pageChunk.startOffset),
    );
    return expand ? SizedBox.expand(child: page) : page;
  }
}
