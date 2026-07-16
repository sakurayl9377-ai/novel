import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';
import 'package:novel_app/models/reading_settings.dart';

void main() {
  test('new readers use the calibrated comfortable paper layout', () {
    final settings = ReadingSettings();

    expect(settings.fontSize, 24);
    expect(settings.fontFamily, ReadingSettings.wenKaiFont);
    expect(settings.lineHeight, 2.2);
    expect(settings.paragraphSpacing, 0.85);
    expect(settings.horizontalPadding, 26);
    expect(settings.backgroundColor, '#F4E3BC');
    expect(
      settings.toJson()['layoutPresetVersion'],
      ReadingSettings.currentLayoutPresetVersion,
    );
  });

  test('untouched beta 8 typography migrates without changing page mode', () {
    final legacy = <String, dynamic>{
      'schemaVersion': 2,
      'fontSize': 20.0,
      'fontFamily': ReadingSettings.systemFont,
      'backgroundColor': '#F6E7C5',
      'nightMode': false,
      'lineHeight': 1.75,
      'paragraphSpacing': 0.85,
      'horizontalPadding': 24.0,
      'pageTurnMode': 'simulation',
    };
    final settings = ReadingSettings.fromJson(legacy);

    expect(ReadingSettings.needsLayoutPresetMigration(legacy), isTrue);
    expect(settings.fontSize, 24);
    expect(settings.fontFamily, ReadingSettings.wenKaiFont);
    expect(settings.lineHeight, 2.2);
    expect(settings.paragraphSpacing, 0.85);
    expect(settings.horizontalPadding, 26);
    expect(settings.backgroundColor, '#F4E3BC');
    expect(settings.pageMode, NovelPageMode.simulation);
    expect(
      ReadingSettings.needsLayoutPresetMigration(settings.toJson()),
      isFalse,
    );
  });

  test('any customized beta 8 layout keeps every legacy visual value', () {
    final settings = ReadingSettings.fromJson({
      'schemaVersion': 2,
      'fontSize': 21.0,
      'fontFamily': ReadingSettings.systemFont,
      'backgroundColor': '#F6E7C5',
      'nightMode': false,
      'lineHeight': 1.75,
      'paragraphSpacing': 0.85,
      'horizontalPadding': 24.0,
    });

    expect(settings.fontSize, 21);
    expect(settings.lineHeight, 1.75);
    expect(settings.paragraphSpacing, 0.85);
    expect(settings.horizontalPadding, 24);
    expect(settings.backgroundColor, '#F6E7C5');
  });

  test('untouched beta 9 defaults migrate to 24sp WenKai', () {
    final settings = ReadingSettings.fromJson({
      'schemaVersion': 3,
      'layoutPresetVersion': 2,
      'fontSize': 23.0,
      'fontFamily': ReadingSettings.systemFont,
      'backgroundColor': '#F4E3BC',
      'nightMode': false,
      'lineHeight': 2.2,
      'paragraphSpacing': 0.85,
      'horizontalPadding': 26.0,
    });

    expect(settings.fontSize, 24);
    expect(settings.fontFamily, ReadingSettings.wenKaiFont);
    expect(settings.toJson()['layoutPresetVersion'], 3);
  });

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
