class TtsSettings {
  static const String engineSystem = 'system';
  static const String engineIflytek = 'iflytek';
  static const String defaultIflytekAppId = '45cb70e8';
  static const String defaultIflytekApiKey = 'afc0e22eb498337db8e9631573786cbb';
  static const String defaultIflytekApiSecret =
      'ZWZlNGM5NTViMGNlY2UwMjA5ZDUyNzUx';

  final String engine;
  final String iflytekAppId;
  final String iflytekApiKey;
  final String iflytekApiSecret;
  final String iflytekVoiceName;
  final String iflytekVoiceLabel;

  const TtsSettings({
    this.engine = engineSystem,
    this.iflytekAppId = defaultIflytekAppId,
    this.iflytekApiKey = defaultIflytekApiKey,
    this.iflytekApiSecret = defaultIflytekApiSecret,
    this.iflytekVoiceName = 'x4_xiaoyan',
    this.iflytekVoiceLabel = '讯飞小燕',
  });

  bool get useIflytek => engine == engineIflytek;
  bool get hasIflytekCredentials =>
      iflytekAppId.trim().isNotEmpty &&
      iflytekApiKey.trim().isNotEmpty &&
      iflytekApiSecret.trim().isNotEmpty;

  TtsSettings copyWith({
    String? engine,
    String? iflytekAppId,
    String? iflytekApiKey,
    String? iflytekApiSecret,
    String? iflytekVoiceName,
    String? iflytekVoiceLabel,
  }) {
    return TtsSettings(
      engine: engine ?? this.engine,
      iflytekAppId: iflytekAppId ?? this.iflytekAppId,
      iflytekApiKey: iflytekApiKey ?? this.iflytekApiKey,
      iflytekApiSecret: iflytekApiSecret ?? this.iflytekApiSecret,
      iflytekVoiceName: iflytekVoiceName ?? this.iflytekVoiceName,
      iflytekVoiceLabel: iflytekVoiceLabel ?? this.iflytekVoiceLabel,
    );
  }

  Map<String, dynamic> toJson() => {
    'engine': engine,
    'iflytekAppId': iflytekAppId,
    'iflytekApiKey': iflytekApiKey,
    'iflytekApiSecret': iflytekApiSecret,
    'iflytekVoiceName': iflytekVoiceName,
    'iflytekVoiceLabel': iflytekVoiceLabel,
  };

  factory TtsSettings.fromJson(Map<String, dynamic> json) => TtsSettings(
    engine: json['engine'] as String? ?? engineSystem,
    iflytekAppId: _stringOrDefault(json['iflytekAppId'], defaultIflytekAppId),
    iflytekApiKey: _stringOrDefault(
      json['iflytekApiKey'],
      defaultIflytekApiKey,
    ),
    iflytekApiSecret: _stringOrDefault(
      json['iflytekApiSecret'],
      defaultIflytekApiSecret,
    ),
    iflytekVoiceName: json['iflytekVoiceName'] as String? ?? 'x4_xiaoyan',
    iflytekVoiceLabel: json['iflytekVoiceLabel'] as String? ?? '讯飞小燕',
  );
}

String _stringOrDefault(dynamic value, String defaultValue) {
  final stringValue = value as String?;
  return stringValue == null || stringValue.trim().isEmpty
      ? defaultValue
      : stringValue;
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
