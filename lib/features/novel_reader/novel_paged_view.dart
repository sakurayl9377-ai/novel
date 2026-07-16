import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../reader_core/reader_modes.dart';
import 'novel_pagination.dart';
import 'novel_reader_backdrop.dart';
import 'novel_text_layout.dart';

typedef NovelPagePositionCallback =
    void Function(int pageIndex, int charPosition);

class NovelPagedViewController {
  _NovelPagedViewState? _state;

  int get currentPage => _state?._currentPage ?? 0;

  int? get currentCharPosition => _state?._currentCharPosition;

  Future<bool> nextPage() async => await _state?._turnPage(1) ?? false;

  Future<bool> previousPage() async => await _state?._turnPage(-1) ?? false;

  void _attach(_NovelPagedViewState state) => _state = state;

  void _detach(_NovelPagedViewState state) {
    if (identical(_state, state)) _state = null;
  }
}

class NovelPagedView extends StatefulWidget {
  const NovelPagedView({
    super.key,
    required this.content,
    required this.chapterTitle,
    required this.mode,
    required this.textStyle,
    required this.paragraphSpacing,
    required this.horizontalPadding,
    required this.initialTextOffset,
    required this.onPositionChanged,
    required this.onPositionSettled,
    required this.onNeedNextChapter,
    required this.onNeedPreviousChapter,
    required this.onToggleControls,
    this.controller,
    this.activeTextRange = TextRange.empty,
    this.singleHandMode = false,
    this.pageBackgroundColor,
  });

  final String content;
  final String chapterTitle;
  final NovelPageMode mode;
  final TextStyle textStyle;
  final double paragraphSpacing;
  final double horizontalPadding;
  final int initialTextOffset;
  final NovelPagePositionCallback onPositionChanged;
  final NovelPagePositionCallback onPositionSettled;
  final Future<void> Function() onNeedNextChapter;
  final Future<void> Function() onNeedPreviousChapter;
  final VoidCallback onToggleControls;
  final NovelPagedViewController? controller;
  final TextRange activeTextRange;
  final bool singleHandMode;
  final Color? pageBackgroundColor;

  @override
  State<NovelPagedView> createState() => _NovelPagedViewState();
}

class _NovelPagedViewState extends State<NovelPagedView> {
  PageController? _pageController;
  NovelPaginationResult? _pagination;
  _PaginationSignature? _signature;
  int _currentPage = 0;
  double _boundaryOverscroll = 0;
  bool _userDragging = false;
  bool _boundaryActionRunning = false;
  int? _lastFollowedHighlightOffset;
  int _pageEffectOrigin = 0;
  int _pageEffectDirection = 0;
  bool _pageEffectRunning = false;
  double _curlTouchYFraction = 0.68;

  int? get _currentCharPosition {
    final pagination = _pagination;
    if (pagination == null || pagination.pages.isEmpty) return null;
    return pagination
        .pages[_currentPage.clamp(0, pagination.pages.length - 1)]
        .startOffset;
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant NovelPagedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.content != widget.content ||
        oldWidget.textStyle != widget.textStyle ||
        oldWidget.paragraphSpacing != widget.paragraphSpacing ||
        oldWidget.horizontalPadding != widget.horizontalPadding) {
      _signature = null;
    }
    if (oldWidget.mode != widget.mode) {
      _resetPageEffect();
    }
    if (widget.activeTextRange.isValid &&
        widget.activeTextRange.start != _lastFollowedHighlightOffset &&
        !_userDragging) {
      _lastFollowedHighlightOffset = widget.activeTextRange.start;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _followActiveText();
      });
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _pageController?.dispose();
    super.dispose();
  }

  void _ensurePagination(BoxConstraints constraints, BuildContext context) {
    // Reader body typography is controlled by the in-app font slider. System
    // scaling continues to apply to controls, but must not silently change
    // line breaks and saved page anchors across devices.
    const textScaler = TextScaler.noScaling;
    final width = math.max(
      1.0,
      constraints.maxWidth - widget.horizontalPadding * 2,
    );
    const verticalPadding = 30.0;
    final height = math.max(1.0, constraints.maxHeight - verticalPadding * 2);
    final signature = _PaginationSignature(
      content: widget.content,
      width: width,
      height: height,
      textStyle: widget.textStyle,
      paragraphSpacing: widget.paragraphSpacing,
      textScaleFactor: textScaler.scale(1),
      title: '',
      titleExtent: 0,
    );
    if (signature == _signature && _pagination != null) return;

    final anchor = _pagination == null
        ? widget.initialTextOffset
        : _pagination!
              .pages[_currentPage.clamp(0, _pagination!.pages.length - 1)]
              .startOffset;
    _pagination = NovelPaginationEngine.paginate(
      content: widget.content,
      width: width,
      height: height,
      style: widget.textStyle,
      paragraphSpacing: widget.paragraphSpacing,
      textDirection: Directionality.of(context),
      textAlign: TextAlign.justify,
      textScaler: textScaler,
      locale: Localizations.maybeLocaleOf(context),
      firstPageReservedHeight: 0,
    );
    _signature = signature;
    _currentPage = _pagination!.pageForOffset(anchor);
    _pageEffectOrigin = _currentPage;
    _pageEffectDirection = 0;
    _pageEffectRunning = false;
    final oldController = _pageController;
    _pageController = PageController(initialPage: _currentPage);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => oldController?.dispose(),
    );
  }

  Future<bool> _turnPage(int delta) async {
    final pagination = _pagination;
    final controller = _pageController;
    if (pagination == null || controller == null || !controller.hasClients) {
      return false;
    }
    final target = _currentPage + delta;
    if (target >= 0 && target < pagination.pages.length) {
      _preparePageEffect(delta);
      await controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
      return true;
    }
    if (_boundaryActionRunning) return false;
    _boundaryActionRunning = true;
    try {
      if (delta > 0) {
        await widget.onNeedNextChapter();
      } else {
        await widget.onNeedPreviousChapter();
      }
      return true;
    } finally {
      _boundaryActionRunning = false;
    }
  }

  void _followActiveText() {
    final pagination = _pagination;
    final controller = _pageController;
    if (pagination == null || controller == null || !controller.hasClients) {
      return;
    }
    final target = pagination.pageForOffset(widget.activeTextRange.start);
    if (target == _currentPage) return;
    _preparePageEffect(target.compareTo(_currentPage));
    controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userDragging = true;
      _boundaryOverscroll = 0;
      _preparePageEffect(0);
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _boundaryOverscroll += notification.overscroll;
    } else if (notification is ScrollEndNotification) {
      final overscroll = _boundaryOverscroll;
      _boundaryOverscroll = 0;
      final wasDragging = _userDragging;
      _userDragging = false;
      if (wasDragging && overscroll.abs() >= 42) {
        unawaited(_turnPage(overscroll > 0 ? 1 : -1));
      } else if (_pagination != null) {
        final page = _pagination!.pages[_currentPage];
        widget.onPositionSettled(_currentPage, page.startOffset);
      }
      _resetPageEffect();
    }
    return false;
  }

  void _preparePageEffect(int direction) {
    if (widget.mode != NovelPageMode.simulation) return;
    _pageEffectOrigin = _currentPage;
    _pageEffectDirection = direction.sign;
    _pageEffectRunning = true;
  }

  void _resetPageEffect() {
    _pageEffectOrigin = _currentPage;
    _pageEffectDirection = 0;
    _pageEffectRunning = false;
  }

  _PaperCurlTransition _paperCurlTransition(double page) {
    var origin = _pageEffectOrigin;
    var direction = _pageEffectDirection;
    var distance = page - origin;
    if (!_pageEffectRunning && distance.abs() < 0.0001) {
      return const _PaperCurlTransition.idle();
    }
    if (direction == 0 && distance.abs() >= 0.0001) {
      direction = distance.isNegative ? -1 : 1;
    }
    if (direction == 0) return const _PaperCurlTransition.idle();
    if (distance.sign != direction && distance.abs() >= 0.0001) {
      origin = page.round();
      distance = page - origin;
      direction = distance.isNegative ? -1 : 1;
    }
    return _PaperCurlTransition(
      originPage: origin,
      direction: direction,
      progress: distance.abs().clamp(0.0, 1.0),
      touchYFraction: _curlTouchYFraction,
    );
  }

  void _handleTap(TapUpDetails details, double width) {
    final ratio = width <= 0 ? 0.5 : details.localPosition.dx / width;
    final leftBoundary = widget.singleHandMode ? 0.18 : 0.28;
    final rightBoundary = widget.singleHandMode ? 0.42 : 0.72;
    if (ratio < leftBoundary) {
      unawaited(_turnPage(-1));
    } else if (ratio > rightBoundary) {
      unawaited(_turnPage(1));
    } else {
      widget.onToggleControls();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _ensurePagination(constraints, context);
        final pagination = _pagination!;
        final controller = _pageController!;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanDown: (details) {
            if (widget.mode != NovelPageMode.simulation ||
                constraints.maxHeight <= 0) {
              return;
            }
            _curlTouchYFraction = (details.localPosition.dy /
                    constraints.maxHeight)
                .clamp(0.12, 0.92);
          },
          onTapUp: (details) => _handleTap(details, constraints.maxWidth),
          child: Stack(
            fit: StackFit.expand,
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: PageView.builder(
                  key: const ValueKey('novel-pages'),
                  controller: controller,
                  physics: const BouncingScrollPhysics(
                    parent: PageScrollPhysics(),
                  ),
                  itemCount: pagination.pages.length,
                  onPageChanged: (index) {
                    _currentPage = index;
                    final page = pagination.pages[index];
                    widget.onPositionChanged(index, page.startOffset);
                    if (!_userDragging) {
                      widget.onPositionSettled(index, page.startOffset);
                    }
                  },
                  itemBuilder: (context, index) {
                    return AnimatedBuilder(
                      animation: controller,
                      child: _buildPage(context, pagination, index),
                      builder: (context, child) {
                        final page = controller.positions.length == 1
                            ? controller.page ?? _currentPage.toDouble()
                            : _currentPage.toDouble();
                        return _applyPageEffect(
                          child!,
                          index: index,
                          page: page,
                          width: constraints.maxWidth,
                        );
                      },
                    );
                  },
                ),
              ),
              if (widget.mode == NovelPageMode.simulation)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) {
                        final page = controller.positions.length == 1
                            ? controller.page ?? _currentPage.toDouble()
                            : _currentPage.toDouble();
                        final transition = _paperCurlTransition(page);
                        if (!transition.isVisible) {
                          return const SizedBox.shrink();
                        }
                        return RepaintBoundary(
                          key: const ValueKey('novel-paper-curl-overlay'),
                          child: CustomPaint(
                            painter: _PaperCurlPainter(
                              progress: transition.progress,
                              direction: transition.direction,
                              touchYFraction: transition.touchYFraction,
                              paperColor:
                                  widget.pageBackgroundColor ??
                                  Theme.of(context).colorScheme.surface,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPage(
    BuildContext context,
    NovelPaginationResult pagination,
    int index,
  ) {
    final page = pagination.pages[index];
    final text = page.textOf(widget.content);
    final highlight = widget.activeTextRange;
    final highlightColor = widget.textStyle.color?.computeLuminance() == 1
        ? Colors.orange.withValues(alpha: 0.32)
        : Colors.orange.withValues(alpha: 0.18);
    final pageBody = Padding(
      padding: EdgeInsets.fromLTRB(
        widget.horizontalPadding,
        34,
        widget.horizontalPadding,
        30,
      ),
      child: RichText(
        textScaler: TextScaler.noScaling,
        textAlign: TextAlign.justify,
        text: NovelTextLayout.buildSpan(
          text: text,
          globalStartOffset: page.startOffset,
          previousCodeUnit: page.startOffset > 0
              ? widget.content.codeUnitAt(page.startOffset - 1)
              : null,
          style: widget.textStyle,
          paragraphSpacing: widget.paragraphSpacing,
          highlightRange: highlight,
          highlightColor: highlightColor,
        ),
        softWrap: true,
        overflow: TextOverflow.clip,
      ),
    );
    return RepaintBoundary(
      child: NovelReaderBackdrop(
        color:
            widget.pageBackgroundColor ?? Theme.of(context).colorScheme.surface,
        child: pageBody,
      ),
    );
  }

  Widget _applyPageEffect(
    Widget child, {
    required int index,
    required double page,
    required double width,
  }) {
    final delta = index - page;
    switch (widget.mode) {
      case NovelPageMode.horizontalSlide:
        return child;
      case NovelPageMode.cover:
        final offset = delta < 0 ? -delta * width : 0.0;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: delta.abs() < 1.1
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.16),
                        blurRadius: 12,
                        offset: const Offset(-5, 0),
                      ),
                    ]
                  : null,
            ),
            child: child,
          ),
        );
      case NovelPageMode.simulation:
        final transition = _paperCurlTransition(page);
        if (!transition.isVisible) {
          return child;
        }
        final targetPage = transition.originPage + transition.direction;
        if (index == targetPage) {
          return Transform.translate(
            offset: Offset(
              -transition.direction * (1 - transition.progress) * width,
              0,
            ),
            child: child,
          );
        }
        if (index != transition.originPage) return child;
        return Transform.translate(
          offset: Offset(transition.direction * transition.progress * width, 0),
          child: ClipPath(
            key: const ValueKey('novel-paper-curl-front'),
            clipBehavior: Clip.hardEdge,
            clipper: _PaperCurlFrontClipper(
              progress: transition.progress,
              direction: transition.direction,
              touchYFraction: transition.touchYFraction,
            ),
            child: child,
          ),
        );
      case NovelPageMode.verticalScroll:
        return child;
    }
  }
}

@immutable
class _PaperCurlTransition {
  const _PaperCurlTransition({
    required this.originPage,
    required this.direction,
    required this.progress,
    required this.touchYFraction,
  });

  const _PaperCurlTransition.idle()
    : originPage = 0,
      direction = 0,
      progress = 0,
      touchYFraction = 0.68;

  final int originPage;
  final int direction;
  final double progress;
  final double touchYFraction;

  bool get isVisible => direction != 0 && progress > 0.001 && progress < 0.999;
}

class _PaperCurlFrontClipper extends CustomClipper<Path> {
  const _PaperCurlFrontClipper({
    required this.progress,
    required this.direction,
    required this.touchYFraction,
  });

  final double progress;
  final int direction;
  final double touchYFraction;

  @override
  Path getClip(Size size) {
    final foldX = direction > 0
        ? size.width * (1 - progress)
        : size.width * progress;
    final bow =
        math.min(20.0, size.width * 0.05) * math.sin(math.pi * progress);
    final tilt =
        (touchYFraction - 0.5) * size.width * 0.42 *
        math.sin(math.pi * progress);
    final topFoldX = (foldX - tilt).clamp(0.0, size.width);
    final bottomFoldX = (foldX + tilt).clamp(0.0, size.width);
    final path = Path();
    if (direction > 0) {
      path
        ..moveTo(0, 0)
        ..lineTo(topFoldX, 0)
        ..cubicTo(
          topFoldX + bow * 0.18,
          size.height * 0.17,
          foldX + bow,
          size.height * touchYFraction,
          foldX + bow * 0.66,
          size.height * 0.56,
        )
        ..cubicTo(
          foldX + bow * 0.36,
          size.height * 0.72,
          bottomFoldX + bow * 0.08,
          size.height * 0.90,
          bottomFoldX,
          size.height,
        )
        ..lineTo(0, size.height)
        ..close();
    } else {
      path
        ..moveTo(topFoldX, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(bottomFoldX, size.height)
        ..cubicTo(
          bottomFoldX - bow * 0.08,
          size.height * 0.90,
          foldX - bow * 0.36,
          size.height * 0.72,
          foldX - bow * 0.66,
          size.height * 0.56,
        )
        ..cubicTo(
          foldX - bow,
          size.height * touchYFraction,
          topFoldX - bow * 0.18,
          size.height * 0.17,
          topFoldX,
          0,
        )
        ..close();
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _PaperCurlFrontClipper oldClipper) =>
      oldClipper.progress != progress ||
      oldClipper.direction != direction ||
      oldClipper.touchYFraction != touchYFraction;
}

class _PaperCurlPainter extends CustomPainter {
  const _PaperCurlPainter({
    required this.progress,
    required this.direction,
    required this.touchYFraction,
    required this.paperColor,
  });

  final double progress;
  final int direction;
  final double touchYFraction;
  final Color paperColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (direction == 0 || progress <= 0 || progress >= 1) return;
    final directionValue = direction.toDouble();
    final foldX = direction > 0
        ? size.width * (1 - progress)
        : size.width * progress;
    final strength = math.sin(math.pi * progress).clamp(0.0, 1.0);
    final bow = math.min(20.0, size.width * 0.05) * strength;
    final curlWidth = math.min(size.width * 0.14, 54.0) * strength;
    final shadowWidth = 18 + 38 * strength;
    final tilt = (touchYFraction - 0.5) * size.width * 0.42 * strength;
    final topFoldX = (foldX - tilt).clamp(0.0, size.width);
    final bottomFoldX = (foldX + tilt).clamp(0.0, size.width);

    final targetShadowRect = direction > 0
        ? Rect.fromLTRB(
            foldX,
            0,
            math.min(size.width, foldX + shadowWidth),
            size.height,
          )
        : Rect.fromLTRB(
            math.max(0, foldX - shadowWidth),
            0,
            foldX,
            size.height,
          );
    if (targetShadowRect.width > 0) {
      canvas.drawRect(
        targetShadowRect,
        Paint()
          ..shader = LinearGradient(
            begin: direction > 0 ? Alignment.centerLeft : Alignment.centerRight,
            end: direction > 0 ? Alignment.centerRight : Alignment.centerLeft,
            colors: [
              Colors.black.withValues(alpha: 0.20 * strength),
              Colors.black.withValues(alpha: 0.055 * strength),
              Colors.transparent,
            ],
          ).createShader(targetShadowRect),
      );
    }

    final edge = Path()
      ..moveTo(topFoldX, 0)
      ..cubicTo(
        topFoldX + directionValue * bow * 0.18,
        size.height * 0.17,
        foldX + directionValue * bow,
        size.height * touchYFraction,
        foldX + directionValue * bow * 0.66,
        size.height * 0.56,
      )
      ..cubicTo(
        foldX + directionValue * bow * 0.36,
        size.height * 0.72,
        bottomFoldX + directionValue * bow * 0.08,
        size.height * 0.90,
        bottomFoldX,
        size.height,
      );
    final outerX = (foldX + directionValue * curlWidth).clamp(0.0, size.width);
    final flap = Path.from(edge)
      ..lineTo(outerX, size.height)
      ..cubicTo(
        outerX - directionValue * bow * 0.04,
        size.height * 0.82,
        outerX - directionValue * bow * 0.24,
        size.height * 0.62,
        outerX - directionValue * bow * 0.18,
        size.height * 0.48,
      )
      ..cubicTo(
        outerX - directionValue * bow * 0.10,
        size.height * 0.32,
        outerX,
        size.height * 0.12,
        outerX,
        0,
      )
      ..close();
    final flapBounds = flap.getBounds();
    if (flapBounds.width > 0) {
      final backLight = Color.lerp(paperColor, Colors.white, 0.22)!;
      final backShade = Color.lerp(paperColor, Colors.black, 0.10)!;
      canvas.drawPath(
        flap,
        Paint()
          ..shader = LinearGradient(
            begin: direction > 0 ? Alignment.centerLeft : Alignment.centerRight,
            end: direction > 0 ? Alignment.centerRight : Alignment.centerLeft,
            colors: [backShade, backLight, paperColor],
            stops: const [0, 0.48, 1],
          ).createShader(flapBounds),
      );
    }

    canvas.drawPath(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..color = Color.lerp(
          paperColor,
          Colors.black,
          0.22,
        )!.withValues(alpha: 0.55 + 0.20 * strength),
    );

    final innerShadowWidth = 12 + 24 * strength;
    final innerShadowRect = direction > 0
        ? Rect.fromLTRB(
            math.max(0, foldX - innerShadowWidth),
            0,
            foldX,
            size.height,
          )
        : Rect.fromLTRB(
            foldX,
            0,
            math.min(size.width, foldX + innerShadowWidth),
            size.height,
          );
    if (innerShadowRect.width > 0) {
      canvas.drawRect(
        innerShadowRect,
        Paint()
          ..shader = LinearGradient(
            begin: direction > 0 ? Alignment.centerLeft : Alignment.centerRight,
            end: direction > 0 ? Alignment.centerRight : Alignment.centerLeft,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: 0.075 * strength),
            ],
          ).createShader(innerShadowRect),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PaperCurlPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.direction != direction ||
      oldDelegate.touchYFraction != touchYFraction ||
      oldDelegate.paperColor != paperColor;
}

@immutable
class _PaginationSignature {
  const _PaginationSignature({
    required this.content,
    required this.width,
    required this.height,
    required this.textStyle,
    required this.paragraphSpacing,
    required this.textScaleFactor,
    required this.title,
    required this.titleExtent,
  });

  final String content;
  final double width;
  final double height;
  final TextStyle textStyle;
  final double paragraphSpacing;
  final double textScaleFactor;
  final String title;
  final double titleExtent;

  @override
  bool operator ==(Object other) {
    return other is _PaginationSignature &&
        other.content == content &&
        other.width == width &&
        other.height == height &&
        other.textStyle == textStyle &&
        other.paragraphSpacing == paragraphSpacing &&
        other.textScaleFactor == textScaleFactor &&
        other.title == title &&
        other.titleExtent == titleExtent;
  }

  @override
  int get hashCode => Object.hash(
    content,
    width,
    height,
    textStyle,
    paragraphSpacing,
    textScaleFactor,
    title,
    titleExtent,
  );
}
