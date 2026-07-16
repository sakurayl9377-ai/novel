import '../features/reader_core/reader_modes.dart';

class ReadingSettings {
  static const int currentSchemaVersion = 2;
  static const String defaultPageTurnMode = 'verticalScroll';
  static const String systemFont = 'system';
  static const String notoSerifFont = 'NotoSerifSC';
  static const String wenKaiFont = 'LXGWWenKaiScreen';

  double fontSize;
  String fontFamily;
  String backgroundColor;
  double brightness;
  bool useSystemBrightness;
  NovelPageMode pageMode;
  bool showLineHeight;
  bool nightMode;
  double lineHeight;
  double paragraphSpacing;
  double horizontalPadding;
  bool singleHandMode;
  bool volumeKeyTurnPage;
  bool keepScreenOn;
  double autoReadSpeed;

  ReadingSettings({
    this.fontSize = 20.0,
    this.fontFamily = systemFont,
    this.backgroundColor = '#F6E7C5',
    this.brightness = 1.0,
    this.useSystemBrightness = true,
    this.pageMode = NovelPageMode.verticalScroll,
    this.showLineHeight = false,
    this.nightMode = false,
    this.lineHeight = 1.75,
    this.paragraphSpacing = 0.85,
    this.horizontalPadding = 24.0,
    this.singleHandMode = false,
    this.volumeKeyTurnPage = false,
    this.keepScreenOn = false,
    this.autoReadSpeed = 1.0,
  });

  String get pageTurnMode => pageMode.code;

  set pageTurnMode(String value) {
    pageMode = NovelPageMode.fromStorage(value);
  }

  static const List<String> backgroundColors = [
    '#F6E7C5',
    '#FFF8ED',
    '#F2F2F2',
    '#C7EDCC',
    '#FFFFFF',
    '#1A1A1A',
    '#2B2B2B',
  ];

  static const List<String> fontFamilies = [
    systemFont,
    notoSerifFont,
    wenKaiFont,
  ];

  static const List<NovelPageMode> pageModes = NovelPageMode.values;
  static final List<String> pageTurnModes = pageModes
      .map((mode) => mode.code)
      .toList(growable: false);

  static String fontLabel(String family) => switch (family) {
    notoSerifFont => '思源宋体',
    wenKaiFont => '霞鹜文楷',
    _ => '系统默认',
  };

  ReadingSettings copyWith({
    double? fontSize,
    String? fontFamily,
    String? backgroundColor,
    double? brightness,
    bool? useSystemBrightness,
    NovelPageMode? pageMode,
    bool? showLineHeight,
    bool? nightMode,
    double? lineHeight,
    double? paragraphSpacing,
    double? horizontalPadding,
    bool? singleHandMode,
    bool? volumeKeyTurnPage,
    bool? keepScreenOn,
    double? autoReadSpeed,
  }) {
    return ReadingSettings(
      fontSize: fontSize ?? this.fontSize,
      fontFamily: fontFamily ?? this.fontFamily,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      brightness: brightness ?? this.brightness,
      useSystemBrightness: useSystemBrightness ?? this.useSystemBrightness,
      pageMode: pageMode ?? this.pageMode,
      showLineHeight: showLineHeight ?? this.showLineHeight,
      nightMode: nightMode ?? this.nightMode,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      singleHandMode: singleHandMode ?? this.singleHandMode,
      volumeKeyTurnPage: volumeKeyTurnPage ?? this.volumeKeyTurnPage,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      autoReadSpeed: autoReadSpeed ?? this.autoReadSpeed,
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': currentSchemaVersion,
    'fontSize': fontSize,
    'fontFamily': fontFamily,
    'backgroundColor': backgroundColor,
    'brightness': brightness,
    'useSystemBrightness': useSystemBrightness,
    'pageTurnMode': pageMode.code,
    'showLineHeight': showLineHeight,
    'nightMode': nightMode,
    'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing,
    'horizontalPadding': horizontalPadding,
    'singleHandMode': singleHandMode,
    'volumeKeyTurnPage': volumeKeyTurnPage,
    'keepScreenOn': keepScreenOn,
    'autoReadSpeed': autoReadSpeed,
  };

  factory ReadingSettings.fromJson(Map<String, dynamic> json) {
    final storedFont = json['fontFamily']?.toString().trim() ?? '';
    final fontFamily = switch (storedFont) {
      notoSerifFont || '宋体' => notoSerifFont,
      wenKaiFont || '楷体' => wenKaiFont,
      _ => systemFont,
    };
    final background = json['backgroundColor']?.toString() ?? '#F6E7C5';
    final night =
        json['nightMode'] as bool? ??
        background == '#1A1A1A' || background == '#2B2B2B';
    return ReadingSettings(
      fontSize: ((json['fontSize'] as num?)?.toDouble() ?? 20.0).clamp(
        14.0,
        34.0,
      ),
      fontFamily: fontFamily,
      backgroundColor: background,
      brightness: ((json['brightness'] as num?)?.toDouble() ?? 1.0).clamp(
        0.05,
        1.0,
      ),
      useSystemBrightness: json['useSystemBrightness'] as bool? ?? true,
      pageMode: NovelPageMode.fromStorage(json['pageTurnMode']),
      showLineHeight: json['showLineHeight'] as bool? ?? false,
      nightMode: night,
      lineHeight: ((json['lineHeight'] as num?)?.toDouble() ?? 1.75).clamp(
        1.2,
        2.2,
      ),
      paragraphSpacing: ((json['paragraphSpacing'] as num?)?.toDouble() ?? 0.85)
          .clamp(0.0, 1.6),
      horizontalPadding:
          ((json['horizontalPadding'] as num?)?.toDouble() ?? 24.0).clamp(
            12.0,
            40.0,
          ),
      singleHandMode: json['singleHandMode'] as bool? ?? false,
      volumeKeyTurnPage: json['volumeKeyTurnPage'] as bool? ?? false,
      keepScreenOn: json['keepScreenOn'] as bool? ?? false,
      autoReadSpeed: ((json['autoReadSpeed'] as num?)?.toDouble() ?? 1.0).clamp(
        0.5,
        3.0,
      ),
    );
  }
}
