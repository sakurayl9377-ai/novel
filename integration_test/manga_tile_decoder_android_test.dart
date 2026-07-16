import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_app/features/manga_reader/manga_tile_decoder.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android region decoder reads a tall image in bounded tiles', (
    tester,
  ) async {
    final decoder = MangaTileDecoderService.instance;
    expect(await decoder.isSupported(), isTrue);

    final directory = await getTemporaryDirectory();
    final source = File('${directory.path}/manga-tile-integration.png');
    await source.writeAsBytes(_solidPng(width: 256, height: 9000), flush: true);
    addTearDown(() async {
      if (await source.exists()) await source.delete();
    });

    final info = await decoder.prepareSource(
      MangaTileSourceRequest(
        source: source.path,
        cacheKey: 'android-integration-${source.lengthSync()}',
      ),
    );
    addTearDown(() => decoder.releaseSource(info.sourceId));

    expect(info.width, 256);
    expect(info.height, 9000);
    expect(info.localInput, isTrue);

    final tile = await decoder.decodeTile(
      MangaTileRequest(
        sourceId: info.sourceId,
        sourceRect: const MangaSourceRect(
          x: 0,
          y: 4096,
          width: 256,
          height: 2048,
        ),
        targetWidth: 256,
        quality: 90,
      ),
    );
    final tileFile = File(tile.path);
    expect(await tileFile.exists(), isTrue);
    expect(await tileFile.length(), greaterThan(0));
    expect(tile.width, lessThanOrEqualTo(256));
    expect(tile.height, lessThanOrEqualTo(mangaTileMaxDecodedHeight));
  });
}

Uint8List _solidPng({required int width, required int height}) {
  final scanline = Uint8List(1 + width * 4);
  scanline[0] = 0;
  for (var pixel = 0; pixel < width; pixel++) {
    final offset = 1 + pixel * 4;
    scanline[offset] = 242;
    scanline[offset + 1] = 242;
    scanline[offset + 2] = 242;
    scanline[offset + 3] = 255;
  }
  final raw = BytesBuilder(copy: false);
  for (var row = 0; row < height; row++) {
    raw.add(scanline);
  }

  final header = ByteData(13)
    ..setUint32(0, width, Endian.big)
    ..setUint32(4, height, Endian.big)
    ..setUint8(8, 8)
    ..setUint8(9, 6)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final output = BytesBuilder(copy: false)
    ..add(const <int>[137, 80, 78, 71, 13, 10, 26, 10])
    ..add(_pngChunk('IHDR', header.buffer.asUint8List()))
    ..add(_pngChunk('IDAT', ZLibEncoder(level: 1).convert(raw.takeBytes())))
    ..add(_pngChunk('IEND', Uint8List(0)));
  return output.takeBytes();
}

Uint8List _pngChunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final body = Uint8List.fromList(<int>[...typeBytes, ...data]);
  final output = ByteData(12 + data.length)
    ..setUint32(0, data.length, Endian.big);
  output.buffer.asUint8List().setRange(4, 8, typeBytes);
  output.buffer.asUint8List().setRange(8, 8 + data.length, data);
  output.setUint32(8 + data.length, _crc32(body), Endian.big);
  return output.buffer.asUint8List();
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
