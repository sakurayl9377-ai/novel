import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/models/reading_progress.dart';
import 'package:novel_app/providers/book_source_provider.dart';
import 'package:novel_app/providers/bookshelf_provider.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/providers/reading_provider.dart';
import 'package:novel_app/providers/tts_provider.dart';
import 'package:novel_app/screens/reading_screen.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'vertical restore uses the persisted chapter fraction as redundancy',
    () {
      expect(
        resolveNovelRestorePosition(
          contentLength: 10000,
          charPosition: 18,
          chapterFraction: 0.18,
          verticalScroll: true,
        ),
        1800,
      );
    },
  );

  testWidgets('all novel page modes preserve a non-zero exit position', (
    tester,
  ) async {
    final testDirectory = Directory.systemTemp.createTempSync(
      'novel_reader_modes_',
    );
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    const flutterTtsChannel = MethodChannel('flutter_tts');
    const audioPlayerChannel = MethodChannel('xyz.luan/audioplayers');
    const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory'
          ? testDirectory.path
          : null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      flutterTtsChannel,
      (_) async => 1,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioPlayerChannel,
      (_) async => null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioGlobalChannel,
      (_) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProviderChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        flutterTtsChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audioPlayerChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audioGlobalChannel,
        null,
      );
      if (testDirectory.existsSync()) testDirectory.deleteSync(recursive: true);
    });
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await tester.runAsync(() => StorageService().init());

    final content = List.generate(
      120,
      (index) => '　　测试正文第 $index 段，用于验证小说阅读进度。',
    ).join('\n\n');
    final novel = Novel(
      id: 'mode-progress-local',
      title: '模式进度测试',
      sourceId: 'local',
      isLocal: true,
      totalChapters: 2,
    );
    final chapters = List.generate(
      2,
      (index) => Chapter(
        id: 'mode-progress-$index',
        novelId: novel.id,
        title: '第 ${index + 1} 章',
        index: index,
        content: content,
      ),
    );

    for (final mode in NovelPageMode.values) {
      final readingProvider = _RecordingReadingProvider();
      readingProvider.previewSettings(
        readingProvider.settings.copyWith(pageMode: mode),
      );
      final bookshelfProvider = _NoopBookshelfProvider();
      final bookSourceProvider = BookSourceProvider();
      final authProvider = InteractionAuthProvider();
      final ttsProvider = TtsProvider();
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ReadingProvider>.value(
              value: readingProvider,
            ),
            ChangeNotifierProvider<BookshelfProvider>.value(
              value: bookshelfProvider,
            ),
            ChangeNotifierProvider<BookSourceProvider>.value(
              value: bookSourceProvider,
            ),
            ChangeNotifierProvider<InteractionAuthProvider>.value(
              value: authProvider,
            ),
            ChangeNotifierProvider<TtsProvider>.value(value: ttsProvider),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const SizedBox.shrink(),
          ),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ReadingScreen(
            novel: novel,
            chapters: chapters,
            startChapterIndex: 1,
            startCharPosition: 180,
          ),
        ),
      );
      await tester.pumpAndSettle();

      navigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();

      expect(readingProvider.lastProgress, isNotNull, reason: mode.name);
      expect(readingProvider.lastProgress!.chapterIndex, 1, reason: mode.name);
      expect(
        readingProvider.lastProgress!.charPosition,
        greaterThan(0),
        reason: mode.name,
      );
      if (mode == NovelPageMode.verticalScroll) {
        expect(
          readingProvider.lastProgress!.charPosition,
          closeTo(180, 40),
          reason: 'vertical restore anchor: ${mode.name}',
        );
      }

      final firstExit = readingProvider.lastProgress!;
      readingProvider.lastProgress = null;
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ReadingScreen(
            novel: novel,
            chapters: chapters,
            startChapterIndex: firstExit.chapterIndex,
            startCharPosition: firstExit.charPosition,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await navigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();

      expect(readingProvider.lastProgress, isNotNull, reason: mode.name);
      expect(
        readingProvider.lastProgress!.chapterIndex,
        firstExit.chapterIndex,
        reason: 're-entry chapter: ${mode.name}',
      );
      expect(
        readingProvider.lastProgress!.charPosition,
        closeTo(firstExit.charPosition, 40),
        reason: 're-entry anchor: ${mode.name}',
      );

      readingProvider.dispose();
      bookshelfProvider.dispose();
      bookSourceProvider.dispose();
      authProvider.dispose();
      ttsProvider.dispose();
    }
  });
}

class _RecordingReadingProvider extends ReadingProvider {
  ReadingProgress? lastProgress;

  @override
  Future<void> saveProgress(Novel novel, ReadingProgress progress) async {
    lastProgress = progress;
  }
}

class _NoopBookshelfProvider extends BookshelfProvider {
  @override
  Future<void> updateNovel(Novel novel) async {}
}
