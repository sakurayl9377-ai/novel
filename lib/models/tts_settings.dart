class TtsSettings {
  static const String engineSystem = 'system';
  static const String engineIflytek = 'iflytek';
  final String engine;
  final String systemVoiceName;
  final String systemVoiceLocale;
  final String iflytekVoiceName;
  final String iflytekVoiceLabel;

  const TtsSettings({
    this.engine = engineSystem,
    this.systemVoiceName = '',
    this.systemVoiceLocale = 'zh-CN',
    this.iflytekVoiceName = 'x4_xiaoyan',
    this.iflytekVoiceLabel = '讯飞小燕',
  });

  bool get useIflytek => engine == engineIflytek;

  TtsSettings copyWith({
    String? engine,
    String? systemVoiceName,
    String? systemVoiceLocale,
    String? iflytekVoiceName,
    String? iflytekVoiceLabel,
  }) {
    return TtsSettings(
      engine: engine ?? this.engine,
      systemVoiceName: systemVoiceName ?? this.systemVoiceName,
      systemVoiceLocale: systemVoiceLocale ?? this.systemVoiceLocale,
      iflytekVoiceName: iflytekVoiceName ?? this.iflytekVoiceName,
      iflytekVoiceLabel: iflytekVoiceLabel ?? this.iflytekVoiceLabel,
    );
  }

  Map<String, dynamic> toJson() => {
    'engine': engine,
    'systemVoiceName': systemVoiceName,
    'systemVoiceLocale': systemVoiceLocale,
    'iflytekVoiceName': iflytekVoiceName,
    'iflytekVoiceLabel': iflytekVoiceLabel,
  };

  factory TtsSettings.fromJson(Map<String, dynamic> json) {
    return TtsSettings(
      engine: json['engine'] as String? ?? engineSystem,
      systemVoiceName: json['systemVoiceName'] as String? ?? '',
      systemVoiceLocale: json['systemVoiceLocale'] as String? ?? 'zh-CN',
      iflytekVoiceName: json['iflytekVoiceName'] as String? ?? 'x4_xiaoyan',
      iflytekVoiceLabel: json['iflytekVoiceLabel'] as String? ?? '讯飞小燕',
    );
  }
}

class TtsSystemVoice {
  const TtsSystemVoice({required this.name, required this.locale});

  final String name;
  final String locale;

  String get label => '$name · $locale';
}

class IflytekVoice {
  final String label;
  final String name;
  final String language;

  const IflytekVoice({
    required this.label,
    required this.name,
    this.language = '普通话',
  });
}

const List<IflytekVoice> iflytekBasicVoices = [
  IflytekVoice(label: '讯飞小燕', name: 'x4_xiaoyan'),
  IflytekVoice(label: '讯飞小露', name: 'x4_yezi'),
  IflytekVoice(label: '讯飞许久', name: 'aisjiuxu'),
  IflytekVoice(label: '讯飞小婧', name: 'aisjinger'),
  IflytekVoice(label: '讯飞许小宝', name: 'aisbabyxu'),
];
