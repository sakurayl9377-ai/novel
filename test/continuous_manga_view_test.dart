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
}
