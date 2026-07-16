import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/manga_reader/manga_reader_preferences.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';
import 'package:novel_app/models/manga.dart';
import 'package:novel_app/screens/manga_reader_screen.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('paged mode stays single-page while double mode is disabled', (
    tester,
  ) async {
    final testDirectory = Directory.systemTemp.createTempSync(
      'manga_reader_modes_',
    );
    addTearDown(() {
      if (testDirectory.existsSync()) {
        testDirectory.deleteSync(recursive: true);
      }
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => testDirectory.path,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      MangaReaderPreferences.storageKey: const MangaReaderPreferences(
        readingMode: MangaReadingMode.paged,
        spreadMode: MangaSpreadMode.double,
      ).encode(),
    });
    await tester.runAsync(() => StorageService().init());

    const chapter = MangaChapter(title: 'Chapter 1', url: 'chapter-1');
    const manga = Manga(
      id: 'mode-test',
      title: 'Mode Test',
      chapters: [chapter],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MangaReaderScreen(
          manga: manga,
          chapter: chapter,
          chapterIndex: 0,
          canLoadChapterOverride: (_) => true,
          warmVisiblePage: false,
          chapterImageLoader: (_) async => const [
            'page-0',
            'page-1',
            'page-2',
            'page-3',
          ],
          mangaPageBuilder: (_, _, pageIndex, _) => Text('page-$pageIndex'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('page-0'), findsOneWidget);
    expect(find.text('page-1'), findsNothing);
    expect(find.text('page-2'), findsNothing);
    expect(find.byKey(const Key('reader-shell-content-layer')), findsOneWidget);
  });
}
