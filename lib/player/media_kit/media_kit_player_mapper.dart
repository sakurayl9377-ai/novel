import 'package:media_kit/media_kit.dart' as media_kit;

import '../player_models.dart';

class MediaKitPlayerMapper {
  const MediaKitPlayerMapper._();

  static PlayerTrackState tracks(
    media_kit.Tracks available,
    media_kit.Track selected,
  ) => PlayerTrackState(
    video: available.video.map(videoTrack).toList(growable: false),
    audio: available.audio.map(audioTrack).toList(growable: false),
    subtitle: available.subtitle.map(subtitleTrack).toList(growable: false),
    selectedVideoId: selected.video.id,
    selectedAudioId: selected.audio.id,
    selectedSubtitleId: selected.subtitle.id,
  );

  static PlayerTrackInfo videoTrack(media_kit.VideoTrack track) =>
      PlayerTrackInfo(
        id: track.id,
        kind: PlayerTrackKind.video,
        origin: _origin(track.id),
        title: track.title ?? '',
        language: track.language ?? '',
        codec: track.codec ?? '',
        width: track.w,
        height: track.h,
        bitrate: track.bitrate,
        isDefault: track.isDefault ?? false,
      );

  static PlayerTrackInfo audioTrack(media_kit.AudioTrack track) =>
      PlayerTrackInfo(
        id: track.id,
        kind: PlayerTrackKind.audio,
        origin: track.uri ? PlayerTrackOrigin.external : _origin(track.id),
        title: track.title ?? '',
        language: track.language ?? '',
        codec: track.codec ?? '',
        bitrate: track.bitrate,
        channels: track.channelscount,
        isDefault: track.isDefault ?? false,
      );

  static PlayerTrackInfo subtitleTrack(media_kit.SubtitleTrack track) =>
      PlayerTrackInfo(
        id: track.id,
        kind: PlayerTrackKind.subtitle,
        origin: track.uri || track.data
            ? PlayerTrackOrigin.external
            : _origin(track.id),
        title: track.title ?? '',
        language: track.language ?? '',
        codec: track.codec ?? '',
        isDefault: track.isDefault ?? false,
      );

  static PlayerTrackOrigin _origin(String id) => switch (id) {
    'auto' => PlayerTrackOrigin.automatic,
    'no' => PlayerTrackOrigin.disabled,
    _ => PlayerTrackOrigin.embedded,
  };
}
