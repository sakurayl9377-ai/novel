import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/widgets/wuhandky_cover_image.dart';

void main() {
  test('creates an http fallback for an https cover', () {
    expect(
      WuhandkyCoverImage.httpFallbackFor('https://pic.example.com/cover.jpg'),
      'http://pic.example.com/cover.jpg',
    );
  });

  testWidgets('empty covers request the server fallback exactly once', (
    tester,
  ) async {
    final result = Completer<String?>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WuhandkyCoverImage(
          imageUrl: '',
          title: '待补全封面',
          resolveFallback: () {
            calls += 1;
            return result.future;
          },
        ),
      ),
    );
    await tester.pump();

    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    result.complete(null);
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(calls, 1);
  });
}
