import '../features/reader_core/reader_modes.dart';

class ReadingSettings {
  static const int currentSchemaVersion = 3;
  static const int currentLayoutPresetVersion = 2;
  static const String defaultPageTurnMode = 'verticalScroll';
  static const String systemFont = 'system';
  static const String notoSerifFont = 'NotoSerifSC';
  static const String wenKaiFont = 'LXGWWenKaiScreen';
  static const double defaultFontSize = 23.0;
  static const double defaultLineHeight = 2.2;
  static const double defaultParagraphSpacing = 0.85;
  static const double defaultHorizontalPadding = 26.0;
  static const String defaultPaperColor = '#F4E3BC';

  static const double _legacyFontSize = 20.0;
  static const double _legacyLineHeight = 1.75;
  static const double _legacyParagraphSpacing = 0.85;
  static const double _legacyHorizontalPadding = 24.0;
  static const String _legacyPaperColor = '#F6E7C5';

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
    this.fontSize = defaultFontSize,
    this.fontFamily = systemFont,
    this.backgroundColor = defaultPaperColor,
    this.brightness = 1.0,
    this.useSystemBrightness = true,
    this.pageMode = NovelPageMode.verticalScroll,
    this.showLineHeight = false,
    this.nightMode = false,
    this.lineHeight = defaultLineHeight,
    this.paragraphSpacing = defaultParagraphSpacing,
    this.horizontalPadding = defaultHorizontalPadding,
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
    defaultPaperColor,
    _legacyPaperColor,
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

  static bool needsLayoutPresetMigration(Map<String, dynamic> json) {
    final schemaVersion = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    final layoutPresetVersion =
        (json['layoutPresetVersion'] as num?)?.toInt() ?? 1;
    return schemaVersion < currentSchemaVersion ||
        layoutPresetVersion < currentLayoutPresetVersion;
  }

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
    'layoutPresetVersion': currentLayoutPresetVersion,
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
    final schemaVersion = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    final layoutPresetVersion =
        (json['layoutPresetVersion'] as num?)?.toInt() ?? 1;
    final hasCurrentLayoutPreset =
        schemaVersion >= currentSchemaVersion ||
        layoutPresetVersion >= currentLayoutPresetVersion;
    final migrateUntouchedLegacyLayout =
        !hasCurrentLayoutPreset && _matchesUntouchedLegacyLayout(json);
    final useCurrentDefaults =
        hasCurrentLayoutPreset || migrateUntouchedLegacyLayout;
    final storedFont = json['fontFamily']?.toString().trim() ?? '';
    final fontFamily = switch (storedFont) {
      notoSerifFont || '宋体' => notoSerifFont,
      wenKaiFont || '楷体' => wenKaiFont,
      _ => systemFont,
    };
    final background = migrateUntouchedLegacyLayout
        ? defaultPaperColor
        : json['backgroundColor']?.toString() ??
              (useCurrentDefaults ? defaultPaperColor : _legacyPaperColor);
    final night =
        json['nightMode'] as bool? ??
        background == '#1A1A1A' || background == '#2B2B2B';
    return ReadingSettings(
      fontSize:
          (migrateUntouchedLegacyLayout
                  ? defaultFontSize
                  : (json['fontSize'] as num?)?.toDouble() ??
                        (useCurrentDefaults
                            ? defaultFontSize
                            : _legacyFontSize))
              .clamp(14.0, 34.0),
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
      lineHeight:
          (migrateUntouchedLegacyLayout
                  ? defaultLineHeight
                  : (json['lineHeight'] as num?)?.toDouble() ??
                        (useCurrentDefaults
                            ? defaultLineHeight
                            : _legacyLineHeight))
              .clamp(1.2, 2.2),
      paragraphSpacing:
          (migrateUntouchedLegacyLayout
                  ? defaultParagraphSpacing
                  : (json['paragraphSpacing'] as num?)?.toDouble() ??
                        (useCurrentDefaults
                            ? defaultParagraphSpacing
                            : _legacyParagraphSpacing))
              .clamp(0.0, 1.6),
      horizontalPadding:
          (migrateUntouchedLegacyLayout
                  ? defaultHorizontalPadding
                  : (json['horizontalPadding'] as num?)?.toDouble() ??
                        (useCurrentDefaults
                            ? defaultHorizontalPadding
                            : _legacyHorizontalPadding))
              .clamp(12.0, 40.0),
      singleHandMode: json['singleHandMode'] as bool? ?? false,
      volumeKeyTurnPage: json['volumeKeyTurnPage'] as bool? ?? false,
      keepScreenOn: json['keepScreenOn'] as bool? ?? false,
      autoReadSpeed: ((json['autoReadSpeed'] as num?)?.toDouble() ?? 1.0).clamp(
        0.5,
        3.0,
      ),
    );
  }

  static bool _matchesUntouchedLegacyLayout(Map<String, dynamic> json) {
    final storedFont = json['fontFamily']?.toString().trim() ?? systemFont;
    final nightMode = json['nightMode'] as bool? ?? false;
    return _sameNumber(json['fontSize'], _legacyFontSize) &&
        (storedFont.isEmpty || storedFont == systemFont) &&
        _sameNumber(json['lineHeight'], _legacyLineHeight) &&
        _sameNumber(json['paragraphSpacing'], _legacyParagraphSpacing) &&
        _sameNumber(json['horizontalPadding'], _legacyHorizontalPadding) &&
        (json['backgroundColor']?.toString() ?? _legacyPaperColor) ==
            _legacyPaperColor &&
        !nightMode;
  }

  static bool _sameNumber(Object? value, double expected) {
    final actual = value is num ? value.toDouble() : expected;
    return (actual - expected).abs() < 0.0001;
  }
}
