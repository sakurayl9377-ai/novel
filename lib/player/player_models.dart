import 'package:flutter/foundation.dart';

enum PlayerPhase { idle, opening, ready, buffering, failed, disposed }

enum PlayerTrackKind { video, audio, subtitle }

enum PlayerTrackOrigin { automatic, disabled, embedded, external }

enum PlayerEventType { opened, firstFrame, completed, error }

@immutable
class PlayerMediaSource {
  const PlayerMediaSource({
    required this.uri,
    required this.canonicalId,
    this.httpHeaders = const {},
    this.title = '',
  });

  factory PlayerMediaSource.network(
    String url, {
    required String canonicalId,
    Map<String, String> httpHeaders = const {},
    String title = '',
  }) {
    final uri = Uri.parse(url);
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw FormatException('Unsupported network media URI: $url');
    }
    return PlayerMediaSource(
      uri: uri,
      canonicalId: canonicalId,
      httpHeaders: Map.unmodifiable(httpHeaders),
      title: title,
    );
  }

  factory PlayerMediaSource.file(
    String path, {
    required String canonicalId,
    String title = '',
  }) => PlayerMediaSource(
    uri: Uri.file(path),
    canonicalId: canonicalId,
    title: title,
  );

  final Uri uri;
  final String canonicalId;
  final Map<String, String> httpHeaders;
  final String title;

  bool get isLocal => uri.scheme == 'file' || uri.scheme == 'content';
}

@immutable
class PlayerOpenRequest {
  const PlayerOpenRequest({
    required this.source,
    this.startAt = Duration.zero,
    this.autoplay = true,
  });

  final PlayerMediaSource source;
  final Duration startAt;
  final bool autoplay;

  PlayerOpenRequest copyWith({
    PlayerMediaSource? source,
    Duration? startAt,
    bool? autoplay,
  }) => PlayerOpenRequest(
    source: source ?? this.source,
    startAt: startAt ?? this.startAt,
    autoplay: autoplay ?? this.autoplay,
  );
}

@immutable
class PlayerStatus {
  const PlayerStatus({
    this.phase = PlayerPhase.idle,
    this.errorMessage = '',
    this.width,
    this.height,
    this.firstFrameRendered = false,
  });

  final PlayerPhase phase;
  final String errorMessage;
  final int? width;
  final int? height;
  final bool firstFrameRendered;

  double? get aspectRatio {
    final valueWidth = width;
    final valueHeight = height;
    if (valueWidth == null || valueHeight == null || valueHeight <= 0) {
      return null;
    }
    return valueWidth / valueHeight;
  }

  PlayerStatus copyWith({
    PlayerPhase? phase,
    String? errorMessage,
    int? width,
    int? height,
    bool? firstFrameRendered,
    bool clearError = false,
  }) => PlayerStatus(
    phase: phase ?? this.phase,
    errorMessage: clearError ? '' : errorMessage ?? this.errorMessage,
    width: width ?? this.width,
    height: height ?? this.height,
    firstFrameRendered: firstFrameRendered ?? this.firstFrameRendered,
  );
}

@immutable
class PlayerTimeline {
  const PlayerTimeline({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.rate = 1,
    this.volume = 1,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool playing;
  final bool buffering;
  final bool completed;
  final double rate;
  final double volume;

  PlayerTimeline copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? playing,
    bool? buffering,
    bool? completed,
    double? rate,
    double? volume,
  }) => PlayerTimeline(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffered: buffered ?? this.buffered,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    rate: rate ?? this.rate,
    volume: volume ?? this.volume,
  );
}

@immutable
class PlayerTrackInfo {
  const PlayerTrackInfo({
    required this.id,
    required this.kind,
    required this.origin,
    this.title = '',
    this.language = '',
    this.codec = '',
    this.width,
    this.height,
    this.bitrate,
    this.channels,
    this.isDefault = false,
  });

  final String id;
  final PlayerTrackKind kind;
  final PlayerTrackOrigin origin;
  final String title;
  final String language;
  final String codec;
  final int? width;
  final int? height;
  final int? bitrate;
  final int? channels;
  final bool isDefault;

  String get label {
    if (title.isNotEmpty) return title;
    if (height != null && height! > 0) return '${height}P';
    if (language.isNotEmpty) return language;
    return switch (origin) {
      PlayerTrackOrigin.automatic => '自动',
      PlayerTrackOrigin.disabled => '关闭',
      PlayerTrackOrigin.embedded => id,
      PlayerTrackOrigin.external => '外挂',
    };
  }
}

@immutable
class PlayerTrackState {
  const PlayerTrackState({
    this.video = const [],
    this.audio = const [],
    this.subtitle = const [],
    this.selectedVideoId = 'auto',
    this.selectedAudioId = 'auto',
    this.selectedSubtitleId = 'auto',
  });

  final List<PlayerTrackInfo> video;
  final List<PlayerTrackInfo> audio;
  final List<PlayerTrackInfo> subtitle;
  final String selectedVideoId;
  final String selectedAudioId;
  final String selectedSubtitleId;

  PlayerTrackState copyWith({
    List<PlayerTrackInfo>? video,
    List<PlayerTrackInfo>? audio,
    List<PlayerTrackInfo>? subtitle,
    String? selectedVideoId,
    String? selectedAudioId,
    String? selectedSubtitleId,
  }) => PlayerTrackState(
    video: video ?? this.video,
    audio: audio ?? this.audio,
    subtitle: subtitle ?? this.subtitle,
    selectedVideoId: selectedVideoId ?? this.selectedVideoId,
    selectedAudioId: selectedAudioId ?? this.selectedAudioId,
    selectedSubtitleId: selectedSubtitleId ?? this.selectedSubtitleId,
  );
}

@immutable
class PlayerTrackSelection {
  const PlayerTrackSelection.embedded(this.kind, this.id)
    : uri = null,
      title = '',
      language = '';

  const PlayerTrackSelection.external(
    this.kind,
    this.uri, {
    this.title = '',
    this.language = '',
  }) : id = '';

  final PlayerTrackKind kind;
  final String id;
  final Uri? uri;
  final String title;
  final String language;

  bool get isExternal => uri != null;
}

@immutable
class PlaybackCapabilities {
  const PlaybackCapabilities({
    this.trackSelection = true,
    this.externalAudio = true,
    this.externalSubtitle = true,
    this.videoTrackSelection = true,
  });

  final bool trackSelection;
  final bool externalAudio;
  final bool externalSubtitle;
  final bool videoTrackSelection;
}

@immutable
class PlayerEvent {
  const PlayerEvent(this.type, {this.message = ''});

  final PlayerEventType type;
  final String message;
}
