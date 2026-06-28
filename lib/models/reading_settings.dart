class ReadingSettings {
  static const String defaultPageTurnMode = '滚动';

  double fontSize;
  String fontFamily;
  String backgroundColor;
  double brightness;
  String pageTurnMode;
  bool showLineHeight;
  bool nightMode;
  double lineHeight;

  ReadingSettings({
    this.fontSize = 18.0,
    this.fontFamily = '系统默认',
    this.backgroundColor = '#FFF8ED',
    this.brightness = 1.0,
    this.pageTurnMode = defaultPageTurnMode,
    this.showLineHeight = false,
    this.nightMode = false,
    this.lineHeight = 1.6,
  });

  static const List<String> backgroundColors = [
    '#FFF8ED',
    '#F2F2F2',
    '#C7EDCC',
    '#FFFFFF',
    '#1A1A1A',
    '#2B2B2B',
  ];

  static const List<String> fontFamilies = ['系统默认', '苹方', '宋体', '楷体', '黑体'];

  static const List<String> pageTurnModes = [defaultPageTurnMode];

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'fontFamily': fontFamily,
    'backgroundColor': backgroundColor,
    'brightness': brightness,
    'pageTurnMode': pageTurnMode,
    'showLineHeight': showLineHeight,
    'nightMode': nightMode,
    'lineHeight': lineHeight,
  };

  factory ReadingSettings.fromJson(Map<String, dynamic> json) {
    final savedPageTurnMode = json['pageTurnMode'] as String?;
    return ReadingSettings(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18.0,
      fontFamily: json['fontFamily'] as String? ?? '系统默认',
      backgroundColor: json['backgroundColor'] as String? ?? '#FFF8ED',
      brightness: (json['brightness'] as num?)?.toDouble() ?? 1.0,
      pageTurnMode: pageTurnModes.contains(savedPageTurnMode)
          ? savedPageTurnMode!
          : defaultPageTurnMode,
      showLineHeight: json['showLineHeight'] as bool? ?? false,
      nightMode: json['nightMode'] as bool? ?? false,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.6,
    );
  }
}
