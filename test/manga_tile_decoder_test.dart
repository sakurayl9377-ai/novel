import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/manga_reader/manga_tile_decoder.dart';
import 'package:novel_app/features/manga_reader/manga_tiled_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late MangaTileDecoderService decoder;
  late TestDefaultBinaryMessenger messenger;
  late List<MethodCall> calls;

  const sourceId =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  setUp(() {
    channel = MethodChannel(
      'com.novel.novel_app/manga_tiles_test_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    decoder = MangaTileDecoderService.forTesting(channel);
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    calls = <MethodCall>[];
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('prepares a source without returning original image bytes', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'isSupported') return true;
      return <String, Object?>{
        'sourceId': sourceId,
        'width': 1440,
        'height': 12000,
        'mimeType': 'image/jpeg',
        'byteLength': 25000000,
        'localInput': false,
      };
    });

    expect(await decoder.isSupported(), isTrue);
    final info = await decoder.prepareSource(
      const MangaTileSourceRequest(
        source: 'https://img.example.com/long.jpg',
        referer: 'https://reader.example.com/chapter/1',
        cacheKey: 'book-1/chapter-1/page-3',
      ),
    );

    expect(info.width, 1440);
    expect(info.height, 12000);
    expect(info.aspectRatio, closeTo(0.12, 0.0001));
    expect(info.isTall, isTrue);
    expect(calls.last.method, 'prepareSource');
    expect(calls.last.arguments, <String, Object?>{
      'source': 'https://img.example.com/long.jpg',
      'referer': 'https://reader.example.com/chapter/1',
      'cacheKey': 'book-1/chapter-1/page-3',
    });
    expect(
      (calls.last.arguments as Map<Object?, Object?>).keys,
      isNot(contains('bytes')),
    );
  });

  test('decodes a bounded region to a cached file path', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <String, Object?>{
        'sourceId': sourceId,
        'tileKey': '0_2048_1440_2048_1080_92_s2',
        'path': '/data/user/0/app/cache/manga_region_tiles/tile.webp',
        'width': 720,
        'height': 1024,
        'sampleSize': 2,
        'sourceX': 0,
        'sourceY': 2048,
        'sourceWidth': 1440,
        'sourceHeight': 2048,
      };
    });

    final tile = await decoder.decodeTile(
      const MangaTileRequest(
        sourceId: sourceId,
        sourceRect: MangaSourceRect(x: 0, y: 2048, width: 1440, height: 2048),
        targetWidth: 1080,
      ),
    );

    expect(tile.path, endsWith('tile.webp'));
    expect(tile.sampleSize, 2);
    expect(tile.sourceRect.y, 2048);
    expect(calls.single.method, 'decodeTile');
    expect(calls.single.arguments, <String, Object?>{
      'sourceId': sourceId,
      'x': 0,
      'y': 2048,
      'width': 1440,
      'height': 2048,
      'targetWidth': 1080,
      'quality': 92,
    });
  });

  test('release and prune use metadata-only channel messages', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'pruneCache') {
        return <String, Object?>{
          'removedFiles': 4,
          'removedBytes': 1024,
          'retainedBytes': 4096,
        };
      }
      return true;
    });

    await decoder.releaseSource(sourceId);
    final result = await decoder.pruneCache(
      maxBytes: 64 * 1024 * 1024,
      maxAge: const Duration(days: 7),
    );

    expect(calls.first.method, 'releaseSource');
    expect(calls.first.arguments, {'sourceId': sourceId});
    expect(calls.last.method, 'pruneCache');
    expect(calls.last.arguments, {
      'maxBytes': 64 * 1024 * 1024,
      'maxAgeMs': const Duration(days: 7).inMilliseconds,
    });
    expect(result.removedFiles, 4);
    expect(result.retainedBytes, 4096);
  });

  test('maps native failures to a stable decoder exception', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'DECODE_FAILED', message: 'bad region');
    });

    expect(
      () => decoder.decodeTile(
        const MangaTileRequest(
          sourceId: sourceId,
          sourceRect: MangaSourceRect(x: 0, y: 0, width: 100, height: 100),
          targetWidth: 100,
        ),
      ),
      throwsA(
        isA<MangaTileDecoderException>()
            .having((error) => error.code, 'code', 'DECODE_FAILED')
            .having((error) => error.message, 'message', 'bad region'),
      ),
    );
  });

  test('rejects malformed native metadata', () {
    expect(
      () => MangaTileSourceInfo.fromChannel(<String, Object?>{
        'sourceId': 'unsafe/path',
        'width': 1440,
        'height': 12000,
        'mimeType': 'image/jpeg',
        'byteLength': 10,
        'localInput': true,
      }),
      throwsA(
        isA<MangaTileDecoderException>().having(
          (error) => error.code,
          'code',
          'INVALID_RESPONSE',
        ),
      ),
    );
  });

  test('tile layout covers every source row with bounded slices', () {
    const info = MangaTileSourceInfo(
      sourceId: sourceId,
      width: 1440,
      height: 100000,
      mimeType: 'image/jpeg',
      byteLength: 1,
      localInput: false,
    );

    final slices = buildMangaTileSlices(
      source: info,
      displayWidth: 360,
      tileExtent: 512,
    );

    expect(slices.first.sourceRect.y, 0);
    expect(slices.last.sourceRect.bottom, info.height);
    expect(slices.every((slice) => slice.sourceRect.height <= 32768), isTrue);
    for (var index = 1; index < slices.length; index++) {
      expect(slices[index - 1].sourceRect.bottom, slices[index].sourceRect.y);
    }
    expect(
      slices.fold<double>(0, (sum, slice) => sum + slice.displayHeight),
      closeTo(25000, 0.001),
    );
  });

  testWidgets('tall image requests only tiles near the scroll viewport', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('manga_tile_widget_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final tileFile = File('${directory.path}/tile.png');
    tileFile.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
      ),
      flush: true,
    );
    final fake = _FakeMangaTileDecoder(tileFile.path);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              MangaTiledImage(
                source: 'https://img.example.com/tall.jpg',
                decoder: fake,
                tileExtent: 400,
                preloadExtent: 0,
                evictionExtent: 1200,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(fake.requests, isNotEmpty);
    expect(fake.requests.length, lessThan(20));
    expect(
      fake.requests.every((request) => request.sourceRect.y < 5000),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(fake.releasedSourceIds, contains(sourceId));
  });
}

class _FakeMangaTileDecoder implements MangaTileDecoder {
  _FakeMangaTileDecoder(this.tilePath);

  final String tilePath;
  final requests = <MangaTileRequest>[];
  final releasedSourceIds = <String>[];

  @override
  Future<MangaDecodedTile> decodeTile(MangaTileRequest request) async {
    requests.add(request);
    return MangaDecodedTile(
      sourceId: request.sourceId,
      tileKey: 'tile-${request.sourceRect.y}',
      path: tilePath,
      width: 400,
      height: 400,
      sampleSize: 1,
      sourceRect: request.sourceRect,
    );
  }

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<MangaTileSourceInfo> prepareSource(
    MangaTileSourceRequest request,
  ) async => const MangaTileSourceInfo(
    sourceId:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    width: 1000,
    height: 20000,
    mimeType: 'image/jpeg',
    byteLength: 100,
    localInput: false,
  );

  @override
  Future<MangaTileCachePruneResult> pruneCache({
    int? maxBytes,
    Duration? maxAge,
  }) async => const MangaTileCachePruneResult(
    removedFiles: 0,
    removedBytes: 0,
    retainedBytes: 0,
  );

  @override
  Future<void> releaseSource(String sourceId) async {
    releasedSourceIds.add(sourceId);
  }
}
