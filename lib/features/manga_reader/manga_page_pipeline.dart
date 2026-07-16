import '../reader_core/reader_modes.dart';

enum MangaPageCrop { full, leftHalf, rightHalf }

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
  const MangaPagePipeline({this.widePageRatio = 1.15});

  static const double autoDoublePageMinWidth = 720;

  final double widePageRatio;

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
      if (isWide && splitWidePageIndexes.contains(pageIndex)) {
        final swapped = swappedSpreadStartIndexes.contains(pageIndex);
        result.add(
          MangaPageSpread(
            <int>[pageIndex, pageIndex],
            isWidePage: true,
            crops: swapped
                ? const <MangaPageCrop>[
                    MangaPageCrop.rightHalf,
                    MangaPageCrop.leftHalf,
                  ]
                : const <MangaPageCrop>[
                    MangaPageCrop.leftHalf,
                    MangaPageCrop.rightHalf,
                  ],
          ),
        );
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
