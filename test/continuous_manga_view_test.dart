import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/manga.dart';
import 'package:novel_app/widgets/continuous_manga_view.dart';

void main() {
  testWidgets('preloads adjacent chapters and preserves the current position', (
    tester,
  ) async {
    final controller = ScrollController();
    final loaded = <int>[];
    final reported = <int>[];
    const chapters = [
      MangaChapter(title: 'Chapter 1', url: 'https://example.com/1'),
      MangaChapter(title: 'Chapter 2', url: 'https://example.com/2'),
      MangaChapter(title: 'Chapter 3', url: 'https://example.com/3'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 600,
            child: ContinuousMangaView(
              controller: controller,
              chapters: chapters,
              initialChapterIndex: 1,
              initialImages: const ['https://example.invalid/current.jpg'],
              canLoadChapter: (_) => true,
              loadChapterImages: (index) async {
                loaded.add(index);
                return ['https://example.invalid/$index.jpg'];
              },
              onPositionChanged: (position) {
                reported.add(position.chapterIndex);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(loaded, containsAll(<int>[0, 2]));
    expect(controller.offset, greaterThan(600));
    expect(reported, isNotEmpty);
    expect(reported.last, 1);

    await tester.pump(const Duration(milliseconds: 100));
    controller.jumpTo(controller.offset * 0.5);
    await tester.pump();
    expect(reported.last, 0);
    expect(controller.offset, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 100));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(reported.last, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('a delayed previous chapter does not cancel an active drag', (
    tester,
  ) async {
    final controller = ScrollController();
    final previousChapter = Completer<List<String>>();
    const chapters = [
      MangaChapter(title: 'Chapter 1', url: 'https://example.com/1'),
      MangaChapter(title: 'Chapter 2', url: 'https://example.com/2'),
      MangaChapter(title: 'Chapter 3', url: 'https://example.com/3'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinuousMangaView(
            controller: controller,
            chapters: chapters,
            initialChapterIndex: 1,
            initialImages: const [
              'https://example.invalid/current-a.jpg',
              'https://example.invalid/current-b.jpg',
            ],
            canLoadChapter: (_) => true,
            loadChapterImages: (index) {
              if (index == 0) return previousChapter.future;
              return Future.value(['https://example.invalid/$index.jpg']);
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final gesture = await tester.startGesture(const Offset(400, 400));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    final beforeInsert = controller.offset;

    previousChapter.complete(const ['https://example.invalid/previous.jpg']);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final afterInsert = controller.offset;
    expect(afterInsert, greaterThan(beforeInsert + 500));

    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(controller.offset, greaterThan(afterInsert + 40));
    await gesture.up();
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('restores the saved anchor without advancing the page', (
    tester,
  ) async {
    final controller = ScrollController();
    ContinuousMangaPosition? settledPosition;
    const chapters = [
      MangaChapter(title: 'Chapter 1', url: 'https://example.com/1'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinuousMangaView(
            controller: controller,
            chapters: chapters,
            initialChapterIndex: 0,
            initialImages: const [
              'https://example.invalid/0.jpg',
              'https://example.invalid/1.jpg',
              'https://example.invalid/2.jpg',
              'https://example.invalid/3.jpg',
              'https://example.invalid/4.jpg',
            ],
            initialPageIndex: 3,
            initialPageOffsetRatio: 0.4,
            canLoadChapter: (_) => false,
            loadChapterImages: (_) async => const <String>[],
            onPositionSettled: (position) => settledPosition = position,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(settledPosition, isNotNull);
    expect(settledPosition!.pageIndex, 3);
    expect(settledPosition!.pageOffsetRatio, closeTo(0.4, 0.02));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test('adjacent loading does not rebuild just to show hidden load state', () {
    final source = File(
      'lib/widgets/continuous_manga_view.dart',
    ).readAsStringSync();

    expect(source, contains('_loading.add(chapterIndex);'));
    expect(
      source,
      isNot(contains('_loading.add(chapterIndex);\n    if (mounted) setState')),
    );
    expect(source, contains('Timer(const Duration(milliseconds: 60)'));
  });
}
