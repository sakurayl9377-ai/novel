import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/providers/tts_provider.dart';
import 'package:novel_app/widgets/tts_mini_player.dart';
import 'package:provider/provider.dart';

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

  testWidgets('mini player exposes persistent reading controls on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tts = _FakeTtsProvider();
    addTearDown(tts.dispose);
    var openCalls = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<TtsProvider>.value(
        value: tts,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: TtsMiniPlayer(onOpenReader: () => openCalls += 1),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('tts-mini-player')), findsOneWidget);
    expect(find.text('悬浮播放器测试书'), findsOneWidget);
    expect(find.text('第二章 返回主页继续听'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('tts-mini-previous')));
    await tester.pump();
    expect(tts.skipDeltas, [-1]);

    await tester.tap(find.byKey(const ValueKey('tts-mini-play-pause')));
    await tester.pump();
    expect(tts.pauseCalls, 1);

    await tester.tap(find.byKey(const ValueKey('tts-mini-play-pause')));
    await tester.pump();
    expect(tts.playCalls, 1);

    await tester.tap(find.byKey(const ValueKey('tts-mini-next')));
    await tester.pump();
    expect(tts.skipDeltas, [-1, 1]);

    await tester.tap(find.byKey(const ValueKey('tts-mini-open-reader')));
    expect(openCalls, 1);

    await tester.tap(find.byKey(const ValueKey('tts-mini-close')));
    await tester.pump();
    expect(tts.stopCalls, 1);
    expect(find.byKey(const ValueKey('tts-mini-player')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _FakeTtsProvider extends TtsProvider {
  _FakeTtsProvider();

  @override
  Future<void> loadSettings() async {}

  final Novel _novel = Novel(
    id: 'mini-player-novel',
    title: '悬浮播放器测试书',
    author: '测试作者',
  );
  late final List<Chapter> _chapters = [
    Chapter(
      id: 'chapter-1',
      novelId: _novel.id,
      title: '第一章',
      index: 0,
      content: '第一章正文',
    ),
    Chapter(
      id: 'chapter-2',
      novelId: _novel.id,
      title: '第二章 返回主页继续听',
      index: 1,
      content: '第二章正文',
    ),
    Chapter(
      id: 'chapter-3',
      novelId: _novel.id,
      title: '第三章',
      index: 2,
      content: '第三章正文',
    ),
  ];

  bool _active = true;
  bool _playing = true;
  int pauseCalls = 0;
  int playCalls = 0;
  int stopCalls = 0;
  final List<int> skipDeltas = [];

  @override
  bool get hasActiveReadingSession => _active;

  @override
  Novel? get activeNovel => _active ? _novel : null;

  @override
  List<Chapter> get activeChapters => _chapters;

  @override
  int get activeChapterIndex => 1;

  @override
  String get activeChapterTitle => _chapters[1].title;

  @override
  double get activeChapterProgress => 0.42;

  @override
  bool get isSpeaking => _active && _playing;

  @override
  bool get isPaused => _active && !_playing;

  @override
  bool get canSkipToPreviousChapter => _active;

  @override
  bool get canSkipToNextChapter => _active;

  @override
  Future<bool> skipReadingChapter(int delta) async {
    skipDeltas.add(delta);
    return true;
  }

  @override
  Future<bool> pauseSpeaking() async {
    pauseCalls += 1;
    _playing = false;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> playReadingSession() async {
    playCalls += 1;
    _playing = true;
    notifyListeners();
    return true;
  }

  @override
  Future<void> stopSpeaking({bool clearSleepTimer = true}) async {
    stopCalls += 1;
    _active = false;
    _playing = false;
    notifyListeners();
  }
}
