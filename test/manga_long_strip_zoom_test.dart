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

  testWidgets('long-strip zoom owns drag gestures until reset', (tester) async {
    final testDirectory = Directory.systemTemp.createTempSync(
      'manga_long_strip_zoom_',
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
        readingMode: MangaReadingMode.longStrip,
      ).encode(),
    });
    await tester.runAsync(() => StorageService().init());

    const chapter = MangaChapter(title: 'Chapter 1', url: 'chapter-1');
    const manga = Manga(
      id: 'long-strip-zoom',
      title: 'Long Strip Zoom',
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
          chapterImageLoader: (_) async => const ['page-0'],
          mangaPageBuilder: (_, _, _, _) => const SizedBox(
            height: 1200,
            child: Center(child: Text('page-0')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final listFinder = find.byKey(
      const ValueKey<String>('manga-chapter-chapter-1'),
    );
    expect(
      tester.widget<ListView>(listFinder).physics,
      isA<ClampingScrollPhysics>(),
    );

    const zoomTap = Offset(400, 300);
    await tester.tapAt(zoomTap);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(zoomTap);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.widget<ListView>(listFinder).physics,
      isA<NeverScrollableScrollPhysics>(),
    );

    await tester.tapAt(zoomTap);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(zoomTap);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<ListView>(listFinder).physics,
      isA<ClampingScrollPhysics>(),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
