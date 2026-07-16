import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/manga_reader/manga_reader_preferences.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';

void main() {
  test('preferences persist stable enum codes', () {
    const preferences = MangaReaderPreferences(
      readingMode: MangaReadingMode.paged,
      pageDirection: MangaPageDirection.rtl,
      spreadMode: MangaSpreadMode.double,
      imageQuality: MangaImageQuality.high,
      nightMode: true,
    );

    final restored = MangaReaderPreferences.decode(preferences.encode());

    expect(restored.readingMode, MangaReadingMode.paged);
    expect(restored.pageDirection, MangaPageDirection.rtl);
    expect(restored.spreadMode, MangaSpreadMode.double);
    expect(restored.imageQuality, MangaImageQuality.high);
    expect(restored.nightMode, isTrue);
  });

  test('legacy aliases migrate and unknown values use safe defaults', () {
    final legacy = MangaReaderPreferences.fromJson(<String, dynamic>{
      'mode': 'paged',
      'direction': 'rtl',
      'spread': 'double',
      'quality': 'hd',
    });
    final unknown = MangaReaderPreferences.fromJson(<String, dynamic>{
      'mode': 'unknown',
      'direction': 'unknown',
      'spread': 'unknown',
      'quality': 'unknown',
    });

    expect(legacy.readingMode, MangaReadingMode.paged);
    expect(legacy.pageDirection, MangaPageDirection.rtl);
    expect(legacy.spreadMode, MangaSpreadMode.double);
    expect(legacy.imageQuality, MangaImageQuality.high);
    expect(unknown.readingMode, MangaReadingMode.longStrip);
    expect(unknown.pageDirection, MangaPageDirection.ltr);
    expect(unknown.spreadMode, MangaSpreadMode.auto);
    expect(unknown.imageQuality, MangaImageQuality.auto);
  });
}
