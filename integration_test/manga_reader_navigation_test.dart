import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_app/models/manga.dart';
import 'package:novel_app/screens/manga_reader_screen.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:novel_app/widgets/continuous_manga_view.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manga navigation remains on the selected chapter', (
    tester,
  ) async {
    await StorageService().init();
    const chapters = [
      MangaChapter(title: 'Chapter 1', url: 'chapter-1'),
      MangaChapter(title: 'Chapter 2', url: 'chapter-2'),
      MangaChapter(title: 'Chapter 3', url: 'chapter-3'),
    ];
    const manga = Manga(
      id: 'android-navigation-test',
      title: 'Android Navigation Test',
      chapters: chapters,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MangaReaderScreen(
          manga: manga,
          chapter: chapters.first,
          chapterIndex: 0,
          canLoadChapterOverride: (_) => true,
          warmVisiblePage: false,
          mangaPageBuilder: (_, _, _, _) => const SizedBox(height: 1200),
          chapterImageLoader: (chapter) async => [
            'https://example.invalid/${chapter.url}.jpg',
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('1/3 · Chapter 1'), findsOneWidget);

    await tester.tap(find.byTooltip('下一章'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('2/3 · Chapter 2'), findsOneWidget);
    expect(find.textContaining('1/3 · Chapter 1'), findsNothing);

    await tester.tap(find.byTooltip('上一章'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('1/3 · Chapter 1'), findsOneWidget);

    await tester.tap(find.byTooltip('章节目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chapter 3').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('3/3 · Chapter 3'), findsOneWidget);
    expect(find.textContaining('1/3 · Chapter 1'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('upward swipe enters the previous chapter near its ending', (
    tester,
  ) async {
    final controller = ScrollController();
    final reportedChapters = <int>[];
    const chapters = [
      MangaChapter(title: 'Chapter 1', url: 'chapter-1'),
      MangaChapter(title: 'Chapter 2', url: 'chapter-2'),
      MangaChapter(title: 'Chapter 3', url: 'chapter-3'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinuousMangaView(
            controller: controller,
            chapters: chapters,
            initialChapterIndex: 1,
            initialImages: const ['current-page'],
            canLoadChapter: (_) => true,
            loadChapterImages: (index) async => ['page-$index'],
            pageBuilder: (_, _, _, _) => const SizedBox(height: 4000),
            onPositionChanged: (position) {
              reportedChapters.add(position.chapterIndex);
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(reportedChapters.last, 1);

    await tester.drag(find.byType(Scrollable), const Offset(0, 700));
    await tester.pump(const Duration(milliseconds: 500));
    expect(reportedChapters.last, 0);
    expect(controller.offset, greaterThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('history restore keeps the saved page and in-page offset', (
    tester,
  ) async {
    final controller = ScrollController();
    ContinuousMangaPosition? restored;
    const chapter = MangaChapter(title: 'Chapter 1', url: 'chapter-1');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinuousMangaView(
            controller: controller,
            chapters: const [chapter],
            initialChapterIndex: 0,
            initialImages: const ['p0', 'p1', 'p2', 'p3', 'p4'],
            initialPageIndex: 3,
            initialPageOffsetRatio: 0.4,
            canLoadChapter: (_) => false,
            loadChapterImages: (_) async => const <String>[],
            pageBuilder: (_, _, _, _) => const SizedBox(height: 4000),
            onPositionSettled: (position) => restored = position,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(restored, isNotNull);
    expect(restored!.pageIndex, 3);
    expect(restored!.pageOffsetRatio, closeTo(0.4, 0.03));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
