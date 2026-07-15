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

  testWidgets('renders downloaded page paths without a network image lookup', (
    tester,
  ) async {
    final testDirectory = Directory.systemTemp.createTempSync(
      'manga_reader_offline_',
    );
    addTearDown(() {
      if (testDirectory.existsSync()) {
        testDirectory.deleteSync(recursive: true);
      }
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => testDirectory.path,
    );
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await tester.runAsync(() => StorageService().init());

    const chapter = MangaChapter(title: 'Offline chapter', url: 'offline-1');
    const manga = Manga(
      id: 'offline-manga',
      title: 'Offline manga',
      coverUrl: '',
      chapters: [chapter],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MangaReaderScreen(
          manga: manga,
          chapter: chapter,
          chapterIndex: 0,
          chapterImageLoader: (_) async => ['/offline/pages/page-1.jpg'],
          canLoadChapterOverride: (_) => true,
          warmVisiblePage: false,
          mangaPageBuilder: (context, chapterIndex, pageIndex, imageUrl) {
            expect(imageUrl, '/offline/pages/page-1.jpg');
            return Text('offline-page-$pageIndex');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('offline-page-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
