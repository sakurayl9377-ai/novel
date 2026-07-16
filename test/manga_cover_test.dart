import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/manga_image_service.dart';
import 'package:novel_app/widgets/manga_cover.dart';

void main() {
  test('normalizes HTML entities and protocol-relative manga image URLs', () {
    expect(
      normalizeMangaImageUrl(
        '//static-tw.bzmgcn.com/cover/demo.jpg?w=285&amp;h=375#poster',
      ),
      'https://static-tw.bzmgcn.com/cover/demo.jpg?w=285&h=375',
    );
  });

  test('known Baozi cover CDNs include the stable host fallback', () {
    expect(
      mangaImageCandidates(
        'https://static-tw.baozimh.com/cover/demo.jpg?w=285&h=375',
      ),
      [
        'https://static-tw.baozimh.com/cover/demo.jpg?w=285&h=375',
        'https://static-tw.bzmgcn.com/cover/demo.jpg?w=285&h=375',
      ],
    );
    expect(
      normalizeMangaImageUrl(
        'https://static-tw.baozimh.com/cover/demo.jpg',
        preferStableBaoziHost: true,
      ),
      'https://static-tw.bzmgcn.com/cover/demo.jpg',
    );
  });

  test('manga image headers follow the resolved image host', () {
    final headers = mangaImageHeaders(
      imageUrl: 'https://static-tw.bzmgcn.com/cover/demo.jpg',
    );

    expect(headers['Referer'], 'https://static-tw.bzmgcn.com/');
    expect(headers['Accept'], contains('image/webp'));
    expect(headers['User-Agent'], contains('Android'));
  });

  testWidgets('invalid cover keeps a visible independent retry action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 120,
          height: 180,
          child: MangaCover(imageUrl: 'not-a-network-url'),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('manga-cover-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('manga-cover-retry')));
    await tester.pump();
    expect(find.byKey(const ValueKey('manga-cover-retry')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing cover remains a lightweight placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 120,
          height: 180,
          child: MangaCover(imageUrl: ''),
        ),
      ),
    );

    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-cover-retry')), findsNothing);
  });
}
