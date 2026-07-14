import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_app/models/manga.dart';
import 'package:novel_app/screens/manga_reader_screen.dart';
import 'package:novel_app/services/storage_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manual manga navigation stays on the selected chapter', (
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

    await tester.drag(find.byType(Scrollable), const Offset(0, 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('1/3 · Chapter 1'), findsOneWidget);

    await tester.tap(find.byTooltip('下一章'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('2/3 · Chapter 2'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);

    await tester.drag(find.byType(Scrollable), const Offset(0, 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('2/3 · Chapter 2'), findsOneWidget);

    await tester.tap(find.byTooltip('上一章'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('1/3 · Chapter 1'), findsOneWidget);

    await tester.tap(find.byTooltip('章节目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chapter 3').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('3/3 · Chapter 3'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);

    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byTooltip('上一章'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('2/3 · Chapter 2'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);

      await tester.tap(find.byTooltip('下一章'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('3/3 · Chapter 3'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
    }

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
