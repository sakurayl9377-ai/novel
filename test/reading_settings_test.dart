import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';
import 'package:novel_app/models/reading_settings.dart';

void main() {
  test('legacy Chinese page and font settings migrate to stable codes', () {
    final settings = ReadingSettings.fromJson({
      'pageTurnMode': '仿真',
      'fontFamily': '宋体',
      'backgroundColor': '#2B2B2B',
    });

    expect(settings.pageMode, NovelPageMode.simulation);
    expect(settings.fontFamily, ReadingSettings.notoSerifFont);
    expect(settings.nightMode, isTrue);
    expect(settings.toJson()['pageTurnMode'], 'simulation');
  });

  test('unknown page mode safely falls back to vertical scrolling', () {
    final settings = ReadingSettings.fromJson({'pageTurnMode': 'future-mode'});

    expect(settings.pageMode, NovelPageMode.verticalScroll);
  });

  test('all reader typography and device controls round trip', () {
    final original = ReadingSettings(
      fontSize: 25,
      fontFamily: ReadingSettings.wenKaiFont,
      backgroundColor: '#C7EDCC',
      brightness: 0.55,
      useSystemBrightness: false,
      pageMode: NovelPageMode.cover,
      nightMode: false,
      lineHeight: 1.9,
      paragraphSpacing: 1.1,
      horizontalPadding: 30,
      singleHandMode: true,
      volumeKeyTurnPage: true,
      keepScreenOn: true,
      autoReadSpeed: 2.0,
    );
    final restored = ReadingSettings.fromJson(original.toJson());

    expect(restored.fontSize, 25);
    expect(restored.fontFamily, ReadingSettings.wenKaiFont);
    expect(restored.brightness, 0.55);
    expect(restored.useSystemBrightness, isFalse);
    expect(restored.pageMode, NovelPageMode.cover);
    expect(restored.lineHeight, 1.9);
    expect(restored.paragraphSpacing, 1.1);
    expect(restored.horizontalPadding, 30);
    expect(restored.singleHandMode, isTrue);
    expect(restored.volumeKeyTurnPage, isTrue);
    expect(restored.keepScreenOn, isTrue);
    expect(restored.autoReadSpeed, 2.0);
  });
}
