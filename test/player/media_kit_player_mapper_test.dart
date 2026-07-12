import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media_kit;
import 'package:novel_app/player/media_kit/media_kit_player_mapper.dart';
import 'package:novel_app/player/player_models.dart';

void main() {
  test('maps embedded media_kit tracks without leaking plugin types', () {
    const video = media_kit.VideoTrack(
      '7',
      '1080P',
      null,
      codec: 'h264',
      w: 1920,
      h: 1080,
      bitrate: 4500000,
      isDefault: true,
    );
    const audio = media_kit.AudioTrack(
      '8',
      '国语',
      'zh',
      codec: 'aac',
      channelscount: 2,
    );
    const subtitle = media_kit.SubtitleTrack('9', '简体中文', 'zh');
    final state = MediaKitPlayerMapper.tracks(
      const media_kit.Tracks(
        video: [media_kit.VideoTrack('auto', null, null), video],
        audio: [media_kit.AudioTrack('auto', null, null), audio],
        subtitle: [media_kit.SubtitleTrack('no', null, null), subtitle],
      ),
      const media_kit.Track(video: video, audio: audio, subtitle: subtitle),
    );

    expect(state.selectedVideoId, '7');
    expect(state.video.last.height, 1080);
    expect(state.video.last.origin, PlayerTrackOrigin.embedded);
    expect(state.audio.last.language, 'zh');
    expect(state.audio.last.channels, 2);
    expect(state.subtitle.first.origin, PlayerTrackOrigin.disabled);
  });

  test('marks URI tracks as external', () {
    final audio = MediaKitPlayerMapper.audioTrack(
      media_kit.AudioTrack.uri('file:///audio.m4a', title: '外挂音轨'),
    );
    final subtitle = MediaKitPlayerMapper.subtitleTrack(
      media_kit.SubtitleTrack.uri('file:///subtitle.srt', title: '外挂字幕'),
    );

    expect(audio.origin, PlayerTrackOrigin.external);
    expect(subtitle.origin, PlayerTrackOrigin.external);
  });
}
