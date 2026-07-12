import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/player/source/hls_variant_resolver.dart';

void main() {
  test('parses and sorts HLS master variants', () {
    const manifest = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=3500000,AVERAGE-BANDWIDTH=3000000,RESOLUTION=1920x1080,FRAME-RATE=60,CODECS="avc1.640028,mp4a.40.2"
high/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480,NAME="流畅"
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1280x720
../720.m3u8
''';
    final variants = HlsVariantResolver().parse(
      manifest,
      Uri.parse('https://media.example.com/show/master.m3u8'),
    );

    expect(variants.map((item) => item.height), [480, 720, 1080]);
    expect(variants.first.label, '流畅');
    expect(variants[1].uri, Uri.parse('https://media.example.com/720.m3u8'));
    expect(variants.last.frameRate, 60);
    expect(variants.last.codecs, contains('avc1'));
  });

  test('rejects non HLS documents', () {
    expect(
      () => HlsVariantResolver().parse(
        '<html>no</html>',
        Uri.parse('https://example.com/master.m3u8'),
      ),
      throwsFormatException,
    );
  });
}
