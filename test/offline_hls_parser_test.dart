import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/offline_hls_parser.dart';

void main() {
  test(
    'selects highest average bandwidth variant and matching audio group',
    () {
      const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="中文",DEFAULT=YES,URI="audio/main.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=600000
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1600000,AVERAGE-BANDWIDTH=1200000,AUDIO="stereo"
high/index.m3u8
''';
      final base = Uri.parse('https://cdn.example.com/master.m3u8');
      final variant = selectHighestBandwidthHlsVariant(master, base);

      expect(variant, isNotNull);
      expect(
        variant!.uri,
        Uri.parse('https://cdn.example.com/high/index.m3u8'),
      );
      expect(variant.bandwidth, 1200000);
      expect(variant.audioGroup, 'stereo');

      final audio = selectHlsMediaRendition(
        master,
        base,
        type: 'AUDIO',
        groupId: variant.audioGroup,
      );
      expect(audio, isNotNull);
      expect(audio!.uri, Uri.parse('https://cdn.example.com/audio/main.m3u8'));
      expect(audio.localLine('audio/index.m3u8'), contains('audio/index.m3u8'));
    },
  );

  test('rewrites keys, maps and implicit byte ranges for offline playback', () {
    const media = '''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin",IV=0x01
#EXT-X-MAP:URI="media.mp4",BYTERANGE="100@20"
#EXTINF:4,
#EXT-X-BYTERANGE:4@0
media.mp4
#EXTINF:4,
#EXT-X-BYTERANGE:4
media.mp4
#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin",IV=0x02
#EXT-X-ENDLIST
''';
    final parsed = parseOfflineHlsMediaPlaylist(
      media,
      Uri.parse('https://cdn.example.com/show/playlist.m3u8'),
    );

    expect(parsed.resources, hasLength(4));
    expect(parsed.resources[0].uri.path, '/show/keys/key.bin');
    expect(parsed.resources[1].range, 'bytes=20-119');
    expect(parsed.resources[2].range, 'bytes=0-3');
    expect(parsed.resources[3].range, 'bytes=4-7');
    expect(
      parsed.resources.where(
        (resource) => resource.uri.path.endsWith('key.bin'),
      ),
      hasLength(1),
    );
    final output = parsed.lines.join('\n');
    expect(output, contains('URI="asset_0.bin"'));
    expect(output, contains('URI="asset_1.mp4"'));
    expect(output, isNot(contains('#EXT-X-BYTERANGE')));
    expect(output, isNot(contains('BYTERANGE=')));
    expect(output, contains('segment_000000.mp4'));
    expect(output, contains('segment_000001.mp4'));
  });

  test('keeps inline data keys without scheduling a network resource', () {
    const media = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="data:application/octet-stream;base64,AA=="
#EXTINF:4,
segment.ts
#EXT-X-ENDLIST
''';
    final parsed = parseOfflineHlsMediaPlaylist(
      media,
      Uri.parse('https://cdn.example.com/video/index.m3u8'),
    );

    expect(parsed.resources, hasLength(1));
    expect(parsed.resources.single.uri.path, '/video/segment.ts');
    expect(parsed.lines.join('\n'), contains('data:application/octet-stream'));
  });
}
