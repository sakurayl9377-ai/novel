import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/models/reading_progress.dart';
import 'package:novel_app/models/tts_settings.dart';
import 'package:novel_app/providers/tts_provider.dart';
import 'package:novel_app/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const flutterTtsChannel = MethodChannel('flutter_tts');
  const audioPlayerChannel = MethodChannel('xyz.luan/audioplayers');
  const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(flutterTtsChannel, (_) async => 1);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioPlayerChannel, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioGlobalChannel, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(flutterTtsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioPlayerChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioGlobalChannel, null);
  });

  test(
    'reading session keeps chapter context while switching in background',
    () async {
      final provider = _NoStorageTtsProvider();
      addTearDown(provider.dispose);
      final novel = Novel(id: 'tts-session', title: '后台连续朗读');
      final chapters = [
        Chapter(
          id: 'chapter-1',
          novelId: novel.id,
          title: '第一章',
          index: 0,
          content: '第一章正文',
        ),
        Chapter(
          id: 'chapter-2',
          novelId: novel.id,
          title: '第二章',
          index: 1,
          content: '第二章正文',
        ),
      ];
      final savedProgress = <ReadingProgress>[];

      final started = await provider.startReadingSession(
        novel: novel,
        chapters: chapters,
        chapterIndex: 0,
        content: chapters[0].content,
        startOffset: 2,
        loadChapterContent: (chapter) async => chapter.content,
        saveProgress: (progress) async => savedProgress.add(progress),
        canOpenChapter: (_) => true,
      );

      expect(started, isTrue);
      expect(provider.hasActiveReadingSession, isTrue);
      expect(provider.activeNovel?.id, novel.id);
      expect(provider.activeChapterIndex, 0);
      expect(provider.currentStartOffset, 2);

      final changed = await provider.skipReadingChapter(1);

      expect(changed, isTrue);
      expect(provider.activeChapterIndex, 1);
      expect(provider.activeChapterTitle, '第二章');
      expect(provider.activeChapterContent, chapters[1].content);
      expect(provider.currentStartOffset, 0);
      expect(savedProgress.map((item) => item.chapterIndex), [0, 1]);

      await provider.stopSpeaking();
      expect(provider.hasActiveReadingSession, isFalse);
      expect(provider.activeNovel, isNull);
    },
  );

  test(
    'completed chapter automatically continues while reader is closed',
    () async {
      final provider = _NoStorageTtsProvider();
      addTearDown(provider.dispose);
      final novel = Novel(id: 'tts-auto-next', title: '自动续章');
      final chapters = [
        Chapter(
          id: 'auto-1',
          novelId: novel.id,
          title: '第一章',
          index: 0,
          content: '第一章正文',
        ),
        Chapter(
          id: 'auto-2',
          novelId: novel.id,
          title: '第二章',
          index: 1,
          content: '第二章正文',
        ),
      ];

      expect(
        await provider.startReadingSession(
          novel: novel,
          chapters: chapters,
          chapterIndex: 0,
          content: chapters[0].content,
          startOffset: 0,
          loadChapterContent: (chapter) async => chapter.content,
          saveProgress: (_) async {},
          canOpenChapter: (_) => true,
        ),
        isTrue,
      );

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Future<void> emit(String callback) => messenger.handlePlatformMessage(
        'flutter_tts',
        const StandardMethodCodec().encodeMethodCall(MethodCall(callback)),
        null,
      );
      await emit('speak.onStart');
      await emit('speak.onComplete');

      for (
        var attempt = 0;
        attempt < 50 &&
            (provider.activeChapterIndex != 1 || !provider.isSpeaking);
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(provider.activeChapterIndex, 1);
      expect(provider.activeChapterTitle, '第二章');
      expect(provider.isSpeaking, isTrue);
    },
  );

  test(
    'switching engines restarts the active chapter at the same offset',
    () async {
      final service = _RecordingTtsService();
      final provider = _NoStorageTtsProvider(ttsService: service);
      addTearDown(provider.dispose);
      final novel = Novel(id: 'tts-engine-switch', title: '引擎无缝切换');
      final chapter = Chapter(
        id: 'engine-chapter-1',
        novelId: novel.id,
        title: '第一章',
        index: 0,
        content: '0123456789',
      );

      expect(
        await provider.startReadingSession(
          novel: novel,
          chapters: [chapter],
          chapterIndex: 0,
          content: chapter.content,
          startOffset: 2,
          loadChapterContent: (chapter) async => chapter.content,
          saveProgress: (_) async {},
          canOpenChapter: (_) => true,
        ),
        isTrue,
      );
      service.onProgress?.call(3, 4, '5');
      expect(provider.currentStartOffset, 5);

      final switched = await provider.updateSettings(
        provider.settings.copyWith(engine: TtsSettings.engineIflytek),
      );

      expect(switched, isTrue);
      expect(provider.settings.engine, TtsSettings.engineIflytek);
      expect(provider.hasActiveReadingSession, isTrue);
      expect(provider.isSpeaking, isTrue);
      expect(provider.currentStartOffset, 5);
      expect(service.spokenTexts, ['23456789', '56789']);
      expect(service.enginesAtSpeak, [
        TtsSettings.engineSystem,
        TtsSettings.engineIflytek,
      ]);
      expect(
        provider.persistedSettings.single.engine,
        TtsSettings.engineIflytek,
      );
    },
  );

  test(
    'failed engine switch restores the previous engine and playback',
    () async {
      final service = _RecordingTtsService(
        failingEngine: TtsSettings.engineIflytek,
      );
      final provider = _NoStorageTtsProvider(ttsService: service);
      addTearDown(provider.dispose);
      final novel = Novel(id: 'tts-engine-fallback', title: '切换失败回退');
      final chapter = Chapter(
        id: 'fallback-chapter-1',
        novelId: novel.id,
        title: '第一章',
        index: 0,
        content: 'abcdefghij',
      );

      expect(
        await provider.startReadingSession(
          novel: novel,
          chapters: [chapter],
          chapterIndex: 0,
          content: chapter.content,
          startOffset: 1,
          loadChapterContent: (chapter) async => chapter.content,
          saveProgress: (_) async {},
          canOpenChapter: (_) => true,
        ),
        isTrue,
      );
      service.onProgress?.call(3, 4, 'e');

      final switched = await provider.updateSettings(
        provider.settings.copyWith(engine: TtsSettings.engineIflytek),
      );

      expect(switched, isFalse);
      expect(provider.settings.engine, TtsSettings.engineSystem);
      expect(provider.hasActiveReadingSession, isTrue);
      expect(provider.isSpeaking, isTrue);
      expect(provider.currentStartOffset, 4);
      expect(service.spokenTexts, ['bcdefghij', 'efghij', 'efghij']);
      expect(service.enginesAtSpeak, [
        TtsSettings.engineSystem,
        TtsSettings.engineIflytek,
        TtsSettings.engineSystem,
      ]);
      expect(provider.lastErrorMessage, '模拟的新引擎启动失败');
      expect(provider.persistedSettings, isEmpty);
    },
  );

  test('paused reading resumes with the newly selected engine', () async {
    final service = _RecordingTtsService();
    final provider = _NoStorageTtsProvider(ttsService: service);
    addTearDown(provider.dispose);
    final novel = Novel(id: 'tts-paused-switch', title: '暂停后切换');
    final chapter = Chapter(
      id: 'paused-chapter-1',
      novelId: novel.id,
      title: '第一章',
      index: 0,
      content: '0123456789',
    );

    expect(
      await provider.startReadingSession(
        novel: novel,
        chapters: [chapter],
        chapterIndex: 0,
        content: chapter.content,
        startOffset: 0,
        loadChapterContent: (chapter) async => chapter.content,
        saveProgress: (_) async {},
        canOpenChapter: (_) => true,
      ),
      isTrue,
    );
    service.onProgress?.call(4, 5, '4');
    expect(await provider.pauseSpeaking(), isTrue);

    expect(
      await provider.updateSettings(
        provider.settings.copyWith(engine: TtsSettings.engineIflytek),
      ),
      isTrue,
    );
    expect(provider.isPaused, isTrue);
    expect(provider.currentStartOffset, 4);
    expect(service.spokenTexts, ['0123456789']);

    expect(await provider.playReadingSession(), isTrue);
    expect(provider.isSpeaking, isTrue);
    expect(provider.isPaused, isFalse);
    expect(service.spokenTexts, ['0123456789', '456789']);
    expect(service.enginesAtSpeak.last, TtsSettings.engineIflytek);
  });
}

class _NoStorageTtsProvider extends TtsProvider {
  _NoStorageTtsProvider({super.ttsService});

  final List<TtsSettings> persistedSettings = [];

  @override
  Future<void> loadSettings() async {}

  @override
  Future<void> persistTtsSettings(TtsSettings settings) async {
    persistedSettings.add(settings);
  }
}

class _RecordingTtsService extends TtsService {
  _RecordingTtsService({this.failingEngine});

  final String? failingEngine;
  final List<String> spokenTexts = [];
  final List<String> enginesAtSpeak = [];
  String _error = '';

  @override
  String get lastErrorMessage => _error;

  @override
  Future<bool> speak(String text) async {
    spokenTexts.add(text);
    enginesAtSpeak.add(settings.engine);
    if (settings.engine == failingEngine) {
      _error = '模拟的新引擎启动失败';
      return false;
    }
    _error = '';
    onStart?.call();
    return true;
  }

  @override
  Future<bool> stop() async => true;

  @override
  Future<bool> pause() async => true;

  @override
  Future<void> dispose() async {}
}
