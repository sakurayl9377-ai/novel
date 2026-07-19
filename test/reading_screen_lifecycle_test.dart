import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('back navigation freezes one final progress snapshot', (
    tester,
  ) async {
    final testDirectory = Directory.systemTemp.createTempSync(
      'reading_screen_lifecycle_',
    );
    final pathProviderChannel = const MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => call.method == 'getApplicationDocumentsDirectory'
          ? testDirectory.path
          : null,
    );
    const flutterTtsChannel = MethodChannel('flutter_tts');
    const audioPlayerChannel = MethodChannel('xyz.luan/audioplayers');
    const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
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

    final saveGate = Completer<void>();
    final readingProvider = _DelayedReadingProvider(saveGate);
    final bookshelfProvider = _RecordingBookshelfProvider();
    final bookSourceProvider = BookSourceProvider();
    final authProvider = InteractionAuthProvider();
    final ttsProvider = _RecordingTtsProvider();
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(readingProvider.dispose);
    addTearDown(bookshelfProvider.dispose);
    addTearDown(bookSourceProvider.dispose);
    addTearDown(authProvider.dispose);
    addTearDown(ttsProvider.dispose);

    final novel = Novel(
      id: 'reader-dispose-regression',
      title: '退出保存回归',
      sourceId: 'local',
      isLocal: true,
      totalChapters: 1,
    );
    final chapter = Chapter(
      id: 'reader-dispose-regression-0',
      novelId: 'reader-dispose-regression',
      title: '第一章',
      index: 0,
      content: '　　第一段正文。\n\n　　第二段正文，用于验证路由销毁后的异步保存。',
    );
    ttsProvider.activate(novel.id, 17);

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
        builder: (_) => ReadingScreen(
          novel: novel,
          chapters: [chapter],
          startCharPosition: 9,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(readingProvider.saveCalls, 0);
    expect(find.byKey(const ValueKey('novel-tts-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('novel-tts-panel-close')));
    await tester.pump();

    // TTS owns the visible reading position while speech is active. The
    // final route save must persist that exact offset rather than the stale
    // page/scroll anchor.
    final popFuture = navigatorKey.currentState!.maybePop();
    await tester.pump();
    expect(readingProvider.saveCalls, 1);
    expect(readingProvider.lastProgress?.charPosition, 17);

    // A late scroll/layout callback while the final database write is still
    // pending must not enqueue a second stale (often zero) progress write.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -80));
    await tester.pump();
    expect(readingProvider.saveCalls, 1);

    saveGate.complete();
    await popFuture;
    await tester.pumpAndSettle();

    expect(bookshelfProvider.updateCalls, 1);
    expect(ttsProvider.stopCalls, 0);
    expect(ttsProvider.isSpeaking, isTrue);
    expect(tester.takeException(), isNull);
  });
}

class _DelayedReadingProvider extends ReadingProvider {
  _DelayedReadingProvider(this.saveGate);

  final Completer<void> saveGate;
  int saveCalls = 0;
  ReadingProgress? lastProgress;

  @override
  Future<void> saveProgress(Novel novel, ReadingProgress progress) async {
    saveCalls += 1;
    lastProgress = progress;
    await saveGate.future;
  }
}

class _RecordingBookshelfProvider extends BookshelfProvider {
  int updateCalls = 0;

  @override
  Future<void> updateNovel(Novel novel) async {
    updateCalls += 1;
  }
}

class _RecordingTtsProvider extends TtsProvider {
  bool _active = false;
  String _owner = '';
  int _offset = -1;
  int stopCalls = 0;

  void activate(String novelId, int offset) {
    _active = true;
    _owner = 'novel:$novelId';
    _offset = offset;
  }

  @override
  bool get isSpeaking => _active;

  @override
  bool get hasActiveReadingSession => _active;

  @override
  int get currentStartOffset => _offset;

  @override
  bool isOwnedBy(String ownerKey) => _active && ownerKey == _owner;

  @override
  Future<void> stopSpeaking({bool clearSleepTimer = true}) async {
    stopCalls += 1;
    _active = false;
  }
}
