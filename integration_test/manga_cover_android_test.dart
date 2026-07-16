import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_app/widgets/manga_cover.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('downloaded manga cover is decoded and painted on Android', (
    tester,
  ) async {
    final bytes = await _buildCoverPng();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('image', 'png')
        ..headers.contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    const boundaryKey = ValueKey('manga-cover-boundary');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 180,
              child: RepaintBoundary(
                key: boundaryKey,
                child: MangaCover(
                  imageUrl:
                      'http://127.0.0.1:${server.port}/cover.png?w=285&h=375',
                ),
              ),
            ),
          ),
        ),
      ),
    );

    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byKey(const ValueKey('manga-cover-retry')), findsNothing);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    final image = await boundary.toImage();
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(rgba, isNotNull);

    final colors = <int>{};
    final data = rgba!.buffer.asUint8List();
    for (var y = 15; y < image.height; y += 30) {
      for (var x = 10; x < image.width; x += 20) {
        final offset = (y * image.width + x) * 4;
        colors.add(
          data[offset] << 24 |
              data[offset + 1] << 16 |
              data[offset + 2] << 8 |
              data[offset + 3],
        );
      }
    }
    image.dispose();
    expect(colors.length, greaterThan(3));
  });
}

Future<Uint8List> _buildCoverPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 120, 180),
    Paint()..color = const Color(0xFF123B68),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 60, 120, 60),
    Paint()..color = const Color(0xFFDB7A25),
  );
  canvas.drawCircle(
    const Offset(60, 90),
    35,
    Paint()..color = const Color(0xFFF5D36A),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 140, 120, 40),
    Paint()..color = const Color(0xFF2E7D5B),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(120, 180);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
