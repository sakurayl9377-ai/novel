import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';

void main() {
  group('NovelPageMode', () {
    test('uses stable English storage codes', () {
      expect(NovelPageMode.values.map((mode) => mode.code), [
        'verticalScroll',
        'horizontalSlide',
        'cover',
        'simulation',
      ]);
    });

    test('migrates legacy Chinese values and falls back safely', () {
      expect(NovelPageMode.fromStorage('滚动'), NovelPageMode.verticalScroll);
      expect(NovelPageMode.fromStorage('左右平移'), NovelPageMode.horizontalSlide);
      expect(NovelPageMode.fromStorage('覆盖翻页'), NovelPageMode.cover);
      expect(NovelPageMode.fromStorage('纸张仿真'), NovelPageMode.simulation);
      expect(
        NovelPageMode.fromStorage('future-mode'),
        NovelPageMode.verticalScroll,
      );
      expect(NovelPageMode.fromStorage(null), NovelPageMode.verticalScroll);
    });

    test('round trips every current code', () {
      for (final mode in NovelPageMode.values) {
        expect(NovelPageMode.fromStorage(mode.code), mode);
      }
    });
  });

  group('manga reader modes', () {
    test('use stable codes', () {
      expect(MangaReadingMode.values.map((mode) => mode.code), [
        'longStrip',
        'paged',
      ]);
      expect(MangaPageDirection.values.map((mode) => mode.code), [
        'ltr',
        'rtl',
      ]);
      expect(MangaSpreadMode.values.map((mode) => mode.code), [
        'auto',
        'single',
        'double',
      ]);
      expect(MangaImageQuality.values.map((mode) => mode.code), [
        'auto',
        'high',
        'original',
      ]);
    });

    test('read legacy display labels', () {
      expect(MangaReadingMode.fromStorage('横向分页'), MangaReadingMode.paged);
      expect(MangaPageDirection.fromStorage('从右到左'), MangaPageDirection.rtl);
      expect(MangaSpreadMode.fromStorage('双页'), MangaSpreadMode.double);
      expect(MangaImageQuality.fromStorage('高清'), MangaImageQuality.high);
      expect(MangaImageQuality.fromStorage('原图'), MangaImageQuality.original);
    });

    test('unknown values use conservative defaults', () {
      expect(
        MangaReadingMode.fromStorage('unknown'),
        MangaReadingMode.longStrip,
      );
      expect(MangaPageDirection.fromStorage('unknown'), MangaPageDirection.ltr);
      expect(MangaSpreadMode.fromStorage('unknown'), MangaSpreadMode.auto);
      expect(MangaImageQuality.fromStorage('unknown'), MangaImageQuality.auto);
    });
  });
}
