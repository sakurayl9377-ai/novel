class TtsSettings {
  static const String engineSystem = 'system';
  static const String engineIflytek = 'iflytek';
  // Client apps must never contain third-party service credentials.
  // Keep these fields only to migrate older local settings safely.
  static const String defaultIflytekAppId = '';
  static const String defaultIflytekApiKey = '';
  static const String defaultIflytekApiSecret = '';

  final String engine;
  final String iflytekAppId;
  final String iflytekApiKey;
  final String iflytekApiSecret;
  final String iflytekVoiceName;
  final String iflytekVoiceLabel;

  const TtsSettings({
    this.engine = engineSystem,
    this.iflytekVoiceName = 'x4_xiaoyan',
    this.iflytekVoiceLabel = '讯飞小燕',
  }) : iflytekAppId = defaultIflytekAppId,
       iflytekApiKey = defaultIflytekApiKey,
       iflytekApiSecret = defaultIflytekApiSecret;

  bool get useIflytek => engine == engineIflytek;
  bool get hasIflytekCredentials =>
      iflytekAppId.trim().isNotEmpty &&
      iflytekApiKey.trim().isNotEmpty &&
      iflytekApiSecret.trim().isNotEmpty;

  TtsSettings copyWith({
    String? engine,
    String? iflytekVoiceName,
    String? iflytekVoiceLabel,
  }) {
    return TtsSettings(
      engine: engine ?? this.engine,
      iflytekVoiceName: iflytekVoiceName ?? this.iflytekVoiceName,
      iflytekVoiceLabel: iflytekVoiceLabel ?? this.iflytekVoiceLabel,
    );
  }

  Map<String, dynamic> toJson() => {
    'engine': engine,
    'iflytekVoiceName': iflytekVoiceName,
    'iflytekVoiceLabel': iflytekVoiceLabel,
  };

  factory TtsSettings.fromJson(Map<String, dynamic> json) {
    final savedEngine = json['engine'] as String? ?? engineSystem;
    return TtsSettings(
      // Old direct-cloud TTS choices relied on credentials embedded in the app.
      // Migrate them to the safe, device-provided system engine.
      engine: savedEngine == engineIflytek ? engineSystem : savedEngine,
      iflytekVoiceName: json['iflytekVoiceName'] as String? ?? 'x4_xiaoyan',
      iflytekVoiceLabel: json['iflytekVoiceLabel'] as String? ?? '讯飞小燕',
    );
  }
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
