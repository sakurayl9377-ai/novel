import '../reader_core/reader_modes.dart';

class MangaPageCrop {
  const MangaPageCrop({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  static const full = MangaPageCrop(left: 0, top: 0, right: 1, bottom: 1);
  static const leftHalf = MangaPageCrop(
    left: 0,
    top: 0,
    right: 0.5,
    bottom: 1,
  );
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
    this.crops = const <MangaPageCrop>[],
  });

  /// Source page indexes in their visual left-to-right order.
  final List<int> pageIndexes;
  final bool isWidePage;
  final List<MangaPageCrop> crops;

  MangaPageCrop cropAt(int visualIndex) {
    return crops.isEmpty || visualIndex >= crops.length
        ? MangaPageCrop.full
        : crops[visualIndex];
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
        result.add(MangaPageSpread(<int>[pageIndex], isWidePage: isWide));
        pageIndex += 1;
        continue;
      }
      final aspectRatio = aspectRatioAt(pageIndex);
      final explicitWideSplit = splitWidePageIndexes.contains(pageIndex);
      final automaticWideSplit =
          spreadMode == MangaSpreadMode.double && isWide;
      if (isWide && (explicitWideSplit || automaticWideSplit)) {
        final segmentCount = (aspectRatio / typicalPageRatio)
            .round()
            .clamp(2, 6)
            .toInt();
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
            ),
          );
        }
        pageIndex += 1;
        continue;
      }

      if (aspectRatio < tallCompositeRatio) {
        final segmentCount = (typicalPageRatio / aspectRatio)
            .round()
            .clamp(2, 6)
            .toInt();
        for (var segment = 0; segment < segmentCount; segment++) {
          result.add(
            MangaPageSpread(
              <int>[pageIndex],
              crops: <MangaPageCrop>[
                MangaPageCrop.verticalSegment(segment, segmentCount),
              ],
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
        result.add(MangaPageSpread(<int>[pageIndex], isWidePage: isWide));
        pageIndex += 1;
        continue;
      }

      final nextIsWide = aspectRatioAt(pageIndex + 1) >= widePageRatio;
      if (nextIsWide && !forcePair) {
        result.add(MangaPageSpread(<int>[pageIndex]));
        pageIndex += 1;
        continue;
      }

      var visualIndexes = direction == MangaPageDirection.rtl
          ? <int>[pageIndex + 1, pageIndex]
          : <int>[pageIndex, pageIndex + 1];
      if (swappedSpreadStartIndexes.contains(pageIndex)) {
        visualIndexes = visualIndexes.reversed.toList(growable: false);
      }
      result.add(MangaPageSpread(visualIndexes));
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
