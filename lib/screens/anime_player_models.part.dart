part of 'anime_player_screen.dart';

class _AnimeVideoControls extends StatefulWidget {
  const _AnimeVideoControls({
    required this.danmakuListenable,
    required this.onDanmakuPanelPressed,
    required this.onDanmakuComposePressed,
    required this.onDanmakuSettingsPressed,
    required this.onDanmakuEnabledChanged,
    required this.onPictureInPicturePressed,
    required this.canPlayNext,
    required this.onNextEpisodePressed,
    required this.onFullScreenPressed,
    required this.onPlaybackIntentChanged,
    required this.onPlaybackSpeedChanged,
    required this.onVolumeChanged,
    this.forceFullScreenLayout = false,
  });

  final ValueListenable<_DanmakuOverlaySnapshot> danmakuListenable;
  final ValueChanged<BuildContext> onDanmakuPanelPressed;
  final ValueChanged<BuildContext> onDanmakuComposePressed;
  final ValueChanged<BuildContext> onDanmakuSettingsPressed;
  final ValueChanged<bool> onDanmakuEnabledChanged;
  final VoidCallback onPictureInPicturePressed;
  final bool canPlayNext;
  final VoidCallback onNextEpisodePressed;
  final Future<void> Function(ChewieController controller) onFullScreenPressed;
  final ValueChanged<bool> onPlaybackIntentChanged;
  final ValueChanged<double> onPlaybackSpeedChanged;
  final ValueChanged<double> onVolumeChanged;
  final bool forceFullScreenLayout;

  @override
  State<_AnimeVideoControls> createState() => _AnimeVideoControlsState();
}

enum _VideoGestureMode { none, seek, volume, brightness }

class _AnimeVideoVolume {
  static const double defaultVolume = 0.5;
  static double current = defaultVolume;

  static void set(double volume) {
    current = volume.clamp(0.0, 1.0).toDouble();
  }
}

class _PlaybackTarget {
  const _PlaybackTarget(this.source, this.episode);

  final AnimePlaySource source;
  final AnimeEpisode episode;
}

class _PlayerPreferences {
  const _PlayerPreferences({
    this.autoPlayNext = true,
    this.playbackSpeed = 1,
    this.volume = _AnimeVideoVolume.defaultVolume,
  });

  static const String key = 'anime_player_preferences_v1';

  final bool autoPlayNext;
  final double playbackSpeed;
  final double volume;

  factory _PlayerPreferences.fromJson(Map<String, dynamic> json) {
    return _PlayerPreferences(
      autoPlayNext: json['autoPlayNext'] != false,
      playbackSpeed: _doubleInRange(json['playbackSpeed'], 0.5, 3, fallback: 1),
      volume: _doubleInRange(
        json['volume'],
        0,
        1,
        fallback: _AnimeVideoVolume.defaultVolume,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'autoPlayNext': autoPlayNext,
    'playbackSpeed': playbackSpeed,
    'volume': volume,
  };
}

class _DanmakuDisplaySettings {
  const _DanmakuDisplaySettings({
    this.enabled = true,
    this.area = 0.75,
    this.color = Colors.white,
    this.opacity = 0.85,
    this.fontSize = 16,
    this.duration = 7,
    this.hideFixed = false,
    this.hideScroll = false,
    this.hideSpecial = false,
  });

  static const String key = 'anime_danmaku_display_settings';

  final bool enabled;
  final double area;
  final Color color;
  final double opacity;
  final double fontSize;
  final double duration;
  final bool hideFixed;
  final bool hideScroll;
  final bool hideSpecial;

  DanmakuOption toOption() {
    return DanmakuOption(
      area: area,
      opacity: opacity,
      fontSize: fontSize,
      duration: duration,
      hideTop: hideFixed,
      hideBottom: hideFixed,
      hideScroll: hideScroll,
      hideSpecial: hideSpecial,
      lineHeight: 1.32,
      strokeWidth: 1.15,
      safeArea: true,
      massiveMode: false,
    );
  }

  _DanmakuDisplaySettings copyWith({
    bool? enabled,
    double? area,
    Color? color,
    double? opacity,
    double? fontSize,
    double? duration,
    bool? hideFixed,
    bool? hideScroll,
    bool? hideSpecial,
  }) {
    return _DanmakuDisplaySettings(
      enabled: enabled ?? this.enabled,
      area: area ?? this.area,
      color: color ?? this.color,
      opacity: opacity ?? this.opacity,
      fontSize: fontSize ?? this.fontSize,
      duration: duration ?? this.duration,
      hideFixed: hideFixed ?? this.hideFixed,
      hideScroll: hideScroll ?? this.hideScroll,
      hideSpecial: hideSpecial ?? this.hideSpecial,
    );
  }

  factory _DanmakuDisplaySettings.fromJson(Map<String, dynamic> json) {
    return _DanmakuDisplaySettings(
      enabled: json['enabled'] != false,
      area: _doubleInRange(json['area'], 0.25, 1, fallback: 0.75),
      color: Color(_intValue(json['color'], fallback: Colors.white.toARGB32())),
      opacity: _doubleInRange(json['opacity'], 0.2, 1, fallback: 0.85),
      fontSize: _doubleInRange(json['fontSize'], 12, 22, fallback: 16),
      duration: _doubleInRange(json['duration'], 5, 14, fallback: 7),
      hideFixed: json['hideFixed'] == true,
      hideScroll: json['hideScroll'] == true,
      hideSpecial: json['hideSpecial'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'area': area,
      'color': color.toARGB32(),
      'opacity': opacity,
      'fontSize': fontSize,
      'duration': duration,
      'hideFixed': hideFixed,
      'hideScroll': hideScroll,
      'hideSpecial': hideSpecial,
    };
  }
}
