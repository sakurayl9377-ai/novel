import '../reader_core/reader_modes.dart';

class MangaPageCrop {
  const MangaPageCrop({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  static const full = MangaPageCrop(left: 0, top: 0, right: 1, bottom: 1);
  static const leftHalf = MangaPageCrop(left: 0, top: 0, right: 0.5, bottom: 1);
  static const rightHalf = MangaPageCrop(
    left: 0.5,
    top: 0,
    right: 1,
    bottom: 1,
  );

  factory MangaPageCrop.horizontalSegment(int index, int count) {
    return MangaPageCrop(
      left: index / count,
      top: 0,
      right: (index + 1) / count,
      bottom: 1,
    );
  }

  factory MangaPageCrop.verticalSegment(int index, int count) {
    return MangaPageCrop(
      left: 0,
      top: index / count,
      right: 1,
      bottom: (index + 1) / count,
    );
  }

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get widthFraction => right - left;
  double get heightFraction => bottom - top;
  bool get isFull => this == full;

  @override
  bool operator ==(Object other) =>
      other is MangaPageCrop &&
      left == other.left &&
      top == other.top &&
      right == other.right &&
      bottom == other.bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Immutable grouping of one or two source pages shown in a paged viewport.
class MangaPageSpread {
  const MangaPageSpread(
    this.pageIndexes, {
    this.isWidePage = false,
    this.isVerticalComposite = false,
    this.crops = const <MangaPageCrop>[],
    this.aspectRatios = const <double>[],
  });

  /// Source page indexes in their visual left-to-right order.
  final List<int> pageIndexes;
  final bool isWidePage;
  final bool isVerticalComposite;
  final List<MangaPageCrop> crops;
  final List<double> aspectRatios;

  MangaPageCrop cropAt(int visualIndex) {
    return crops.isEmpty || visualIndex >= crops.length
        ? MangaPageCrop.full
        : crops[visualIndex];
  }

  double aspectRatioAt(int visualIndex) {
    return aspectRatios.isEmpty || visualIndex >= aspectRatios.length
        ? 0.68
        : aspectRatios[visualIndex];
  }

  int get firstSourceIndex => pageIndexes.reduce((a, b) => a < b ? a : b);
  int get lastSourceIndex => pageIndexes.reduce((a, b) => a > b ? a : b);

  bool containsPage(int pageIndex) => pageIndexes.contains(pageIndex);
}

/// Builds a stable source-page to viewport-page mapping.
///
/// Wide landscape pages always occupy their own spread. On a double-page
/// spread, RTL only changes the visual order; history continues to use the
/// original source page indexes.
class MangaPagePipeline {
  const MangaPagePipeline({
    this.widePageRatio = 1.15,
    this.typicalPageRatio = 0.68,
    this.tallCompositeRatio = 0.42,
  });

  static const double autoDoublePageMinWidth = 720;

  final double widePageRatio;
  final double typicalPageRatio;
  final double tallCompositeRatio;

  int segmentCountForAspectRatio(double aspectRatio) {
    if (!aspectRatio.isFinite || aspectRatio <= 0) return 1;
    if (aspectRatio >= widePageRatio) {
      return (aspectRatio / typicalPageRatio).round().clamp(2, 6).toInt();
    }
    return 1;
  }

  bool usesDoublePages({
    required MangaSpreadMode spreadMode,
    required double viewportWidth,
  }) {
    return switch (spreadMode) {
      MangaSpreadMode.single => false,
      MangaSpreadMode.double => true,
      MangaSpreadMode.auto => viewportWidth >= autoDoublePageMinWidth,
    };
  }

  List<MangaPageSpread> build({
    required int pageCount,
    required double viewportWidth,
    required MangaSpreadMode spreadMode,
    required MangaPageDirection direction,
    required double Function(int pageIndex) aspectRatioAt,
    double viewportHeight = 0,
    Set<int> splitWidePageIndexes = const <int>{},
    Set<int> forcePairStartIndexes = const <int>{},
    Set<int> forceSinglePageIndexes = const <int>{},
    Set<int> swappedSpreadStartIndexes = const <int>{},
  }) {
    if (pageCount <= 0) return const <MangaPageSpread>[];
    final doublePages = usesDoublePages(
      spreadMode: spreadMode,
      viewportWidth: viewportWidth,
    );
    final result = <MangaPageSpread>[];
    var pageIndex = 0;
    while (pageIndex < pageCount) {
      final isWide = aspectRatioAt(pageIndex) >= widePageRatio;
      if (forceSinglePageIndexes.contains(pageIndex)) {
        result.add(
          MangaPageSpread(
            <int>[pageIndex],
            isWidePage: isWide,
            aspectRatios: <double>[aspectRatioAt(pageIndex)],
          ),
        );
        pageIndex += 1;
        continue;
      }
      final aspectRatio = aspectRatioAt(pageIndex);
      final explicitWideSplit = splitWidePageIndexes.contains(pageIndex);
      if (!doublePages && isWide && !explicitWideSplit) {
        var runEnd = pageIndex + 1;
        while (runEnd < pageCount &&
            aspectRatioAt(runEnd) >= widePageRatio &&
            !splitWidePageIndexes.contains(runEnd) &&
            !forceSinglePageIndexes.contains(runEnd)) {
          runEnd += 1;
        }
        if (runEnd - pageIndex >= 2) {
          final targetHeightRatio = viewportHeight > 0 && viewportWidth > 0
              ? viewportHeight / viewportWidth
              : 1 / typicalPageRatio;
          var chunkStart = pageIndex;
          while (chunkStart < runEnd) {
            var chunkEnd = chunkStart;
            var assembledHeightRatio = 0.0;
            while (chunkEnd < runEnd) {
              assembledHeightRatio += 1 / aspectRatioAt(chunkEnd);
              chunkEnd += 1;
              if (chunkEnd - chunkStart >= 2 &&
                  assembledHeightRatio >= targetHeightRatio) {
                break;
              }
            }
            final indexes = List<int>.generate(
              chunkEnd - chunkStart,
              (offset) => chunkStart + offset,
            );
            result.add(
              MangaPageSpread(
                indexes,
                isVerticalComposite: true,
                aspectRatios: [
                  for (final index in indexes) aspectRatioAt(index),
                ],
              ),
            );
            chunkStart = chunkEnd;
          }
          pageIndex = runEnd;
          continue;
        }
      }
      final automaticWideSplit = spreadMode == MangaSpreadMode.double && isWide;
      if (isWide && (explicitWideSplit || automaticWideSplit)) {
        final segmentCount = segmentCountForAspectRatio(aspectRatio);
        final swapped = swappedSpreadStartIndexes.contains(pageIndex);
        var segments = List<int>.generate(segmentCount, (index) => index);
        if (direction == MangaPageDirection.rtl) {
          segments = segments.reversed.toList(growable: false);
        }
        if (swapped) segments = segments.reversed.toList(growable: false);
        final slotsPerSpread = doublePages ? 2 : 1;
        for (var start = 0; start < segments.length; start += slotsPerSpread) {
          final end = (start + slotsPerSpread).clamp(0, segments.length);
          final visible = segments.sublist(start, end);
          result.add(
            MangaPageSpread(
              List<int>.filled(visible.length, pageIndex),
              isWidePage: true,
              crops: [
                for (final segment in visible)
                  MangaPageCrop.horizontalSegment(segment, segmentCount),
              ],
              aspectRatios: List<double>.filled(visible.length, aspectRatio),
            ),
          );
        }
        pageIndex += 1;
        continue;
      }

      final forcePair =
          pageIndex < pageCount - 1 &&
          forcePairStartIndexes.contains(pageIndex);
      if ((!doublePages && !forcePair) ||
          (isWide && !forcePair) ||
          pageIndex == pageCount - 1) {
        result.add(
          MangaPageSpread(
            <int>[pageIndex],
            isWidePage: isWide,
            aspectRatios: <double>[aspectRatio],
          ),
        );
        pageIndex += 1;
        continue;
      }

      final nextIsWide = aspectRatioAt(pageIndex + 1) >= widePageRatio;
      if (nextIsWide && !forcePair) {
        result.add(
          MangaPageSpread(
            <int>[pageIndex],
            aspectRatios: <double>[aspectRatio],
          ),
        );
        pageIndex += 1;
        continue;
      }

      var visualIndexes = direction == MangaPageDirection.rtl
          ? <int>[pageIndex + 1, pageIndex]
          : <int>[pageIndex, pageIndex + 1];
      if (swappedSpreadStartIndexes.contains(pageIndex)) {
        visualIndexes = visualIndexes.reversed.toList(growable: false);
      }
      result.add(
        MangaPageSpread(
          visualIndexes,
          aspectRatios: [
            for (final index in visualIndexes) aspectRatioAt(index),
          ],
        ),
      );
      pageIndex += 2;
    }
    return result;
  }

  int spreadIndexForPage(List<MangaPageSpread> spreads, int pageIndex) {
    if (spreads.isEmpty) return 0;
    final result = spreads.indexWhere(
      (spread) => spread.containsPage(pageIndex),
    );
    return result < 0 ? 0 : result;
  }
}
