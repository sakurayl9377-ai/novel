import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/models/reading_progress.dart';
import 'package:novel_app/providers/book_source_provider.dart';
import 'package:novel_app/providers/bookshelf_provider.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/providers/reading_provider.dart';
import 'package:novel_app/screens/book_detail_screen.dart';
import 'package:novel_app/services/novel_offline_cache_service.dart';
import 'package:novel_app/widgets/novel_cache_sheet.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('book details expose a full-book download entry', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpBookDetails(tester);

    expect(find.text('下载整书'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('下载整书'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(NovelCacheSheet), findsOneWidget);
    expect(find.text('整书下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in <double>[1.5, 2.0]) {
    testWidgets('book detail bottom bar supports ${scale}x system text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            bottomNavigationBar: BookDetailBottomBar(
              isOnShelf: false,
              isBusy: false,
              canDownload: true,
              actionLabel: '开始阅读',
              onDownload: () {},
              onToggleShelf: () {},
              onOpenReading: () {},
            ),
          ),
        ),
      );

      expect(find.byTooltip('下载整书'), findsOneWidget);
      expect(find.byTooltip('加入书架'), findsOneWidget);
      expect(find.text('开始阅读'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('download sheet remains scrollable on a short landscape screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _bookFixture();
    final provider = _DetailBookSourceProvider(fixture.novel, fixture.chapters);
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NovelCacheSheet(
            novel: fixture.novel,
            chapters: fixture.chapters,
            currentChapterIndex: 0,
            provider: provider,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('下载全本'),
      100,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('下载全本').hitTestable(), findsOneWidget);
    await tester.tap(find.text('下载全本').hitTestable());
    await tester.pump();
    expect(find.text('下载整书？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming full-book download pins and caches the book', (
    tester,
  ) async {
    final fixture = _bookFixture();
    final provider = _DetailBookSourceProvider(fixture.novel, fixture.chapters);
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NovelCacheSheet(
            novel: fixture.novel,
            chapters: fixture.chapters,
            currentChapterIndex: 0,
            provider: provider,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载全本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();

    expect(provider.pinCalls, 1);
    expect(provider.cacheCalls, 1);
    expect(provider.lastRange, NovelCacheBatchRange.full);
    expect(find.text('下载完成：1 章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpBookDetails(
  WidgetTester tester, {
  double textScale = 1,
}) async {
  final fixture = _bookFixture();
  final sourceProvider = _DetailBookSourceProvider(
    fixture.novel,
    fixture.chapters,
  );
  final bookshelfProvider = BookshelfProvider();
  final readingProvider = _DetailReadingProvider();
  final authProvider = InteractionAuthProvider();
  addTearDown(sourceProvider.dispose);
  addTearDown(bookshelfProvider.dispose);
  addTearDown(readingProvider.dispose);
  addTearDown(authProvider.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<BookSourceProvider>.value(value: sourceProvider),
        ChangeNotifierProvider<BookshelfProvider>.value(
          value: bookshelfProvider,
        ),
        ChangeNotifierProvider<ReadingProvider>.value(value: readingProvider),
        ChangeNotifierProvider<InteractionAuthProvider>.value(
          value: authProvider,
        ),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: BookDetailScreen(novel: fixture.novel),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

({Novel novel, List<Chapter> chapters}) _bookFixture() {
  final novel = Novel(
    id: 'download-entry-book',
    title: 'Download entry',
    sourceId: 'test-source',
    chapterUrl: 'https://example.com/book/1',
  );
  return (
    novel: novel,
    chapters: <Chapter>[
      Chapter(
        id: 'chapter-1',
        novelId: novel.id,
        title: 'Chapter 1',
        index: 0,
        url: 'https://example.com/book/1/1',
      ),
    ],
  );
}

class _DetailBookSourceProvider extends BookSourceProvider {
  _DetailBookSourceProvider(this.novel, this.chapters);

  final Novel novel;
  final List<Chapter> chapters;
  int pinCalls = 0;
  int cacheCalls = 0;
  NovelCacheBatchRange? lastRange;

  @override
  Future<Novel> getBookDetail(Novel novel) async => this.novel;

  @override
  Future<List<Chapter>> getChapterList(Novel novel) async => chapters;

  @override
  Future<NovelOfflineStatus> getOfflineStatus(Novel novel) async =>
      NovelOfflineStatus(
        contentKey: 'test',
        chapters: const <NovelOfflineChapterStatus>[],
        pinnedChapterId: null,
        totalBytes: 0,
      );

  @override
  Future<void> pinCurrentChapter(Novel novel, Chapter chapter) async {
    pinCalls += 1;
  }

  @override
  Future<NovelCacheBatchResult> cacheChapters(
    Novel novel,
    List<Chapter> chapters, {
    required NovelCacheBatchRange range,
    int startIndex = 0,
    NovelCacheProgressCallback? onProgress,
    NovelCacheCancellationCheck? shouldCancel,
  }) async {
    cacheCalls += 1;
    lastRange = range;
    final requested = range
        .chapterIndices(chapterCount: chapters.length, startIndex: startIndex)
        .length;
    return NovelCacheBatchResult(
      requested: requested,
      saved: requested,
      failedChapterIds: const <String>[],
    );
  }
}

class _DetailReadingProvider extends ReadingProvider {
  @override
  Future<ReadingProgress?> loadProgress(Novel novel) async => null;
}
