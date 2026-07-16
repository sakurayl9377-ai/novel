import 'package:flutter/material.dart';

import '../reader_core/reader_modes.dart';
import 'manga_page_pipeline.dart';

typedef MangaPagedPageBuilder =
    Widget Function(BuildContext context, int pageIndex, double pageWidth);

class MangaPagedView extends StatefulWidget {
  const MangaPagedView({
    super.key,
    required this.spreads,
    required this.direction,
    required this.initialPageIndex,
    required this.pageBuilder,
    required this.endBuilder,
    required this.onPageChanged,
    required this.onTap,
  });

  final List<MangaPageSpread> spreads;
  final MangaPageDirection direction;
  final int initialPageIndex;
  final MangaPagedPageBuilder pageBuilder;
  final WidgetBuilder endBuilder;
  final void Function(int firstPageIndex, int lastPageIndex) onPageChanged;
  final VoidCallback onTap;

  @override
  State<MangaPagedView> createState() => _MangaPagedViewState();
}

class _MangaPagedViewState extends State<MangaPagedView> {
  late PageController _controller;
  var _currentSpreadIndex = 0;
  var _zoomed = false;

  @override
  void initState() {
    super.initState();
    _currentSpreadIndex = _spreadForPage(widget.initialPageIndex);
    _controller = PageController(initialPage: _currentSpreadIndex);
  }

  @override
  void didUpdateWidget(covariant MangaPagedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final mappingChanged =
        oldWidget.spreads.length != widget.spreads.length ||
        !_sameSpreadMapping(oldWidget.spreads, widget.spreads) ||
        oldWidget.direction != widget.direction;
    if (!mappingChanged) return;

    final sourcePage = oldWidget.spreads.isEmpty
        ? widget.initialPageIndex
        : oldWidget
              .spreads[_currentSpreadIndex.clamp(
                0,
                oldWidget.spreads.length - 1,
              )]
              .firstSourceIndex;
    _currentSpreadIndex = _spreadForPage(sourcePage);
    final oldController = _controller;
    _controller = PageController(initialPage: _currentSpreadIndex);
    _zoomed = false;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => oldController.dispose(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _spreadForPage(int pageIndex) {
    if (widget.spreads.isEmpty) return 0;
    final found = widget.spreads.indexWhere(
      (spread) => spread.containsPage(pageIndex),
    );
    return found < 0 ? 0 : found;
  }

  bool _sameSpreadMapping(
    List<MangaPageSpread> previous,
    List<MangaPageSpread> next,
  ) {
    if (previous.length != next.length) return false;
    for (var index = 0; index < previous.length; index++) {
      final a = previous[index];
      final b = next[index];
      if (a.isWidePage != b.isWidePage ||
          a.pageIndexes.length != b.pageIndexes.length ||
          a.crops.length != b.crops.length ||
          a.aspectRatios.length != b.aspectRatios.length) {
        return false;
      }
      for (var page = 0; page < a.pageIndexes.length; page++) {
        if (a.pageIndexes[page] != b.pageIndexes[page] ||
            a.cropAt(page) != b.cropAt(page) ||
            a.aspectRatioAt(page) != b.aspectRatioAt(page)) {
          return false;
        }
      }
    }
    return true;
  }

  void _handlePageChanged(int spreadIndex) {
    if (spreadIndex >= widget.spreads.length) {
      if (widget.spreads.isNotEmpty) {
        final last = widget.spreads.last.lastSourceIndex;
        widget.onPageChanged(last, last);
      }
      return;
    }
    _currentSpreadIndex = spreadIndex;
    if (_zoomed) setState(() => _zoomed = false);
    final spread = widget.spreads[spreadIndex];
    widget.onPageChanged(spread.firstSourceIndex, spread.lastSourceIndex);
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      key: const ValueKey('manga-paged-view'),
      controller: _controller,
      reverse: widget.direction == MangaPageDirection.rtl,
      physics: _zoomed
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: widget.spreads.length + 1,
      onPageChanged: _handlePageChanged,
      itemBuilder: (context, spreadIndex) {
        if (spreadIndex == widget.spreads.length) {
          return widget.endBuilder(context);
        }
        final spread = widget.spreads[spreadIndex];
        return _ZoomableMangaSpread(
          key: ValueKey(
            'manga-spread-$spreadIndex-${spread.pageIndexes.join('-')}',
          ),
          onTap: widget.onTap,
          onZoomChanged: (zoomed) {
            if (spreadIndex != _currentSpreadIndex || zoomed == _zoomed) return;
            setState(() => _zoomed = zoomed);
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final pageWidth =
                  constraints.maxWidth / spread.pageIndexes.length;
              return Row(
                children: [
                  for (
                    var slotIndex = 0;
                    slotIndex < spread.pageIndexes.length;
                    slotIndex++
                  )
                    SizedBox(
                      width: pageWidth,
                      height: constraints.maxHeight,
                      child: _buildPageSlot(
                        context,
                        pageIndex: spread.pageIndexes[slotIndex],
                        pageWidth: pageWidth,
                        crop: spread.cropAt(slotIndex),
                        aspectRatio: spread.aspectRatioAt(slotIndex),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildPageSlot(
    BuildContext context, {
    required int pageIndex,
    required double pageWidth,
    required MangaPageCrop crop,
    required double aspectRatio,
  }) {
    if (crop.isFull) {
      if (aspectRatio < 0.42) {
        return SingleChildScrollView(
          key: const ValueKey('manga-paged-tall-scroll'),
          physics: const BouncingScrollPhysics(),
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: widget.pageBuilder(context, pageIndex, pageWidth),
          ),
        );
      }
      return widget.pageBuilder(context, pageIndex, pageWidth);
    }
    final horizontalCenter = (crop.left + crop.right) / 2;
    final verticalCenter = (crop.top + crop.bottom) / 2;
    final alignment = Alignment(
      horizontalCenter * 2 - 1,
      verticalCenter * 2 - 1,
    );
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fullWidth = pageWidth / crop.widthFraction;
          final fullHeight = constraints.maxHeight / crop.heightFraction;
          return OverflowBox(
            alignment: alignment,
            minWidth: fullWidth,
            maxWidth: fullWidth,
            minHeight: fullHeight,
            maxHeight: fullHeight,
            child: SizedBox(
              width: fullWidth,
              height: fullHeight,
              child: widget.pageBuilder(context, pageIndex, fullWidth),
            ),
          );
        },
      ),
    );
  }
}

class _ZoomableMangaSpread extends StatefulWidget {
  const _ZoomableMangaSpread({
    super.key,
    required this.child,
    required this.onTap,
    required this.onZoomChanged,
  });

  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomableMangaSpread> createState() => _ZoomableMangaSpreadState();
}

class _ZoomableMangaSpreadState extends State<_ZoomableMangaSpread> {
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
    if (_zoomed) {
      _transformationController.value = Matrix4.identity();
    } else {
      _transformationController.value = Matrix4.diagonal3Values(2.25, 2.25, 1);
    }
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
