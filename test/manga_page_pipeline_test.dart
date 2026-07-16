import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/manga_reader/manga_page_pipeline.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';

void main() {
  const pipeline = MangaPagePipeline();

  test('auto spread changes to double pages at 720dp', () {
    expect(
      pipeline.usesDoublePages(
        spreadMode: MangaSpreadMode.auto,
        viewportWidth: 719,
      ),
      isFalse,
    );
    expect(
      pipeline.usesDoublePages(
        spreadMode: MangaSpreadMode.auto,
        viewportWidth: 720,
      ),
      isTrue,
    );
  });

  test('LTR and RTL preserve source indexes but reverse visual pairing', () {
    List<MangaPageSpread> build(MangaPageDirection direction) {
      return pipeline.build(
        pageCount: 4,
        viewportWidth: 900,
        spreadMode: MangaSpreadMode.auto,
        direction: direction,
        aspectRatioAt: (_) => 0.7,
      );
    }

    expect(build(MangaPageDirection.ltr).first.pageIndexes, [0, 1]);
    expect(build(MangaPageDirection.rtl).first.pageIndexes, [1, 0]);
    expect(build(MangaPageDirection.rtl).first.firstSourceIndex, 0);
    expect(build(MangaPageDirection.rtl).first.lastSourceIndex, 1);
  });

  test('explicit double mode splits a stitched wide page', () {
    final spreads = pipeline.build(
      pageCount: 5,
      viewportWidth: 900,
      spreadMode: MangaSpreadMode.double,
      direction: MangaPageDirection.ltr,
      aspectRatioAt: (index) => index == 2 ? 1.4 : 0.7,
    );

    expect(spreads.map((spread) => spread.pageIndexes).toList(), [
      [0, 1],
      [2, 2],
      [3, 4],
    ]);
    expect(spreads[1].isWidePage, isTrue);
    expect(pipeline.spreadIndexForPage(spreads, 4), 2);
  });

  test('three-page horizontal composites become complete virtual pages', () {
    final spreads = pipeline.build(
      pageCount: 1,
      viewportWidth: 900,
      spreadMode: MangaSpreadMode.double,
      direction: MangaPageDirection.ltr,
      aspectRatioAt: (_) => 2.04,
    );

    expect(spreads.map((spread) => spread.pageIndexes).toList(), [
      [0, 0],
      [0],
    ]);
    expect(spreads.first.crops.first.widthFraction, closeTo(1 / 3, 0.001));
    expect(spreads.last.crops.single.left, closeTo(2 / 3, 0.001));
  });

  test('vertical composites are split into full-height virtual pages', () {
    final spreads = pipeline.build(
      pageCount: 1,
      viewportWidth: 400,
      spreadMode: MangaSpreadMode.single,
      direction: MangaPageDirection.ltr,
      aspectRatioAt: (_) => 0.22,
    );

    expect(spreads, hasLength(3));
    expect(spreads.map((spread) => spread.pageIndexes.single), [0, 0, 0]);
    expect(spreads.first.crops.single.heightFraction, closeTo(1 / 3, 0.001));
    expect(spreads.last.crops.single.top, closeTo(2 / 3, 0.001));
  });

  test('composite segment counts change when real dimensions arrive', () {
    expect(pipeline.segmentCountForAspectRatio(0.68), 1);
    expect(pipeline.segmentCountForAspectRatio(0.22), 3);
    expect(pipeline.segmentCountForAspectRatio(2.04), 3);
  });

  test('wide page can be split into two cropped visual slots', () {
    final spreads = pipeline.build(
      pageCount: 3,
      viewportWidth: 900,
      spreadMode: MangaSpreadMode.double,
      direction: MangaPageDirection.ltr,
      aspectRatioAt: (index) => index == 1 ? 1.6 : 0.7,
      splitWidePageIndexes: const {1},
    );

    expect(spreads.map((spread) => spread.pageIndexes).toList(), [
      [0],
      [1, 1],
      [2],
    ]);
    expect(spreads[1].crops, [MangaPageCrop.leftHalf, MangaPageCrop.rightHalf]);
  });

  test('manual merge and swap override automatic spread mapping', () {
    final spreads = pipeline.build(
      pageCount: 3,
      viewportWidth: 400,
      spreadMode: MangaSpreadMode.single,
      direction: MangaPageDirection.ltr,
      aspectRatioAt: (_) => 0.7,
      forcePairStartIndexes: const {0},
      swappedSpreadStartIndexes: const {0},
    );

    expect(spreads.map((spread) => spread.pageIndexes).toList(), [
      [1, 0],
      [2],
    ]);
  });
}
