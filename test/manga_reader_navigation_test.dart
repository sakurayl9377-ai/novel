import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/manga.dart';
import 'package:novel_app/screens/manga_reader_screen.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets(
    'next previous and catalog navigation keep the selected chapter',
    (tester) async {
      final testDir = Directory.systemTemp.createTempSync('manga_reader_test_');
      addTearDown(() {
        if (testDir.existsSync()) testDir.deleteSync(recursive: true);
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationDocumentsDirectory' ||
          'getTemporaryDirectory' ||
          'getApplicationSupportDirectory' ||
          'getApplicationCacheDirectory' => testDir.path,
          _ => null,
        },
      );
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await tester.runAsync(() => StorageService().init());
      const chapters = [
        MangaChapter(title: 'Chapter 1', url: 'chapter-1'),
        MangaChapter(title: 'Chapter 2', url: 'chapter-2'),
        MangaChapter(title: 'Chapter 3', url: 'chapter-3'),
      ];
      const manga = Manga(
        id: 'navigation-test',
        title: 'Navigation Test',
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
            mangaPageBuilder: (_, _, _, _) => const SizedBox(height: 900),
            chapterImageLoader: (chapter) async => [
              'https://example.invalid/${chapter.url}.jpg',
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('1/3 · Chapter 1'), findsOneWidget);

      final nextButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right),
      );
      expect(nextButton.onPressed, isNotNull);
      nextButton.onPressed!();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      final textsAfterNext = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .where((text) => text.isNotEmpty)
          .join(' | ');
      expect(
        find.textContaining('2/3 · Chapter 2'),
        findsOneWidget,
        reason: textsAfterNext,
      );
      expect(find.textContaining('1/3 · Chapter 1'), findsNothing);

      final previousButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_left),
      );
      expect(previousButton.onPressed, isNotNull);
      previousButton.onPressed!();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(find.textContaining('1/3 · Chapter 1'), findsOneWidget);

      await tester.tap(find.byTooltip('章节目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chapter 3').last);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(find.textContaining('3/3 · Chapter 3'), findsOneWidget);
      expect(find.textContaining('1/3 · Chapter 1'), findsNothing);
    },
  );
}
