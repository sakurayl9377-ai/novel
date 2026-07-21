import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/novel_reader/novel_paged_view.dart';
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
import 'package:novel_app/utils/reading_text_range.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('manual pause then page turn restarts TTS from the new page', (
    tester,
  ) async {
    final testDirectory = Directory.systemTemp.createTempSync(
      'reading_screen_manual_pause_',
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
      if (testDirectory.existsSync()) {
        testDirectory.deleteSync(recursive: true);
      }
    });
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await tester.runAsync(() => StorageService().init());

    final readingProvider = _ImmediateReadingProvider();
    readingProvider.previewSettings(
      readingProvider.settings.copyWith(
        pageMode: NovelPageMode.horizontalSlide,
      ),
    );
    final bookshelfProvider = _NoopBookshelfProvider();
    final bookSourceProvider = BookSourceProvider();
    final authProvider = InteractionAuthProvider();
    final ttsProvider = _ManualPauseTtsProvider();
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(readingProvider.dispose);
    addTearDown(bookshelfProvider.dispose);
    addTearDown(bookSourceProvider.dispose);
    addTearDown(authProvider.dispose);
    addTearDown(ttsProvider.dispose);

    final novel = Novel(
      id: 'manual-pause-page-turn',
      title: 'Manual pause regression',
      sourceId: 'local',
      isLocal: true,
      totalChapters: 1,
    );
    final content = List<String>.generate(
      180,
      (index) =>
          '  Paragraph ${index + 1} has enough text to create several pages.',
    ).join('\n\n');
    final chapter = Chapter(
      id: 'manual-pause-page-turn-0',
      novelId: novel.id,
      title: 'Chapter 1',
      index: 0,
      content: content,
    );
    ttsProvider.activate(novel.id, content, 17);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReadingProvider>.value(value: readingProvider),
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
        builder: (_) => ReadingScreen(novel: novel, chapters: [chapter]),
      ),
    );
    await tester.pumpAndSettle();

    final pagedView = tester.widget<NovelPagedView>(
      find.byType(NovelPagedView),
    );
    final pagedController = pagedView.controller!;
    expect(pagedController.currentPage, 0);

    const pausedSpeechOffset = 60;
    ttsProvider.advanceTo(pausedSpeechOffset);
    await tester.tap(find.text('暂停'));
    await tester.pumpAndSettle();
    expect(ttsProvider.pauseCalls, 1);

    final turn = pagedController.nextPage();
    await tester.pumpAndSettle();
    expect(await turn, isTrue);
    expect(pagedController.currentPage, 1);
    final newPageOffset = pagedController.currentCharPosition!;
    expect(newPageOffset, greaterThan(pausedSpeechOffset));

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    expect(ttsProvider.playCalls, 0);
    expect(ttsProvider.stopCalls, 1);
    expect(ttsProvider.startCalls, 1);
    expect(
      ttsProvider.lastStartOffset,
      skipReadingTextEdgeWhitespace(content, newPageOffset),
    );
    expect(tester.takeException(), isNull);
  });
}

class _ImmediateReadingProvider extends ReadingProvider {
  _ImmediateReadingProvider()
    : super(settingsSaver: (_, _) async {}, settingsLoader: (_) async => null);

  @override
  Future<void> saveProgress(Novel novel, ReadingProgress progress) async {}
}

class _NoopBookshelfProvider extends BookshelfProvider {
  @override
  Future<void> updateNovel(Novel novel) async {}
}

class _ManualPauseTtsProvider extends TtsProvider {
  bool _active = false;
  bool _paused = false;
  String _owner = '';
  String _content = '';
  int _offset = -1;
  int pauseCalls = 0;
  int stopCalls = 0;
  int playCalls = 0;
  int startCalls = 0;
  int? lastStartOffset;

  void activate(String novelId, String content, int offset) {
    _active = true;
    _paused = false;
    _owner = 'novel:$novelId';
    _content = content;
    _offset = offset;
  }

  void advanceTo(int offset) {
    _offset = offset;
  }

  @override
  bool get isSpeaking => _active && !_paused;

  @override
  bool get isPaused => _active && _paused;

  @override
  bool get hasActiveReadingSession => _active;

  @override
  int get activeChapterIndex => 0;

  @override
  String get activeChapterContent => _content;

  @override
  int get currentStartOffset => _offset;

  @override
  bool isOwnedBy(String ownerKey) => _active && ownerKey == _owner;

  @override
  Future<bool> pauseSpeaking() async {
    pauseCalls += 1;
    _paused = true;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> playReadingSession() async {
    playCalls += 1;
    _paused = false;
    notifyListeners();
    return true;
  }

  @override
  Future<void> stopSpeaking({bool clearSleepTimer = true}) async {
    stopCalls += 1;
    _active = false;
    _paused = false;
  }

  @override
  Future<bool> startReadingSession({
    required Novel novel,
    required List<Chapter> chapters,
    required int chapterIndex,
    required String content,
    required int startOffset,
    required TtsChapterContentLoader loadChapterContent,
    required TtsProgressSaver saveProgress,
    required TtsChapterAccessCheck canOpenChapter,
  }) async {
    startCalls += 1;
    lastStartOffset = startOffset;
    activate(novel.id, content, startOffset);
    return true;
  }
}
