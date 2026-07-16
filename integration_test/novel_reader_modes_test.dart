import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_app/features/novel_reader/novel_paged_view.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/providers/book_source_provider.dart';
import 'package:novel_app/providers/bookshelf_provider.dart';
import 'package:novel_app/providers/interaction_auth_provider.dart';
import 'package:novel_app/providers/reading_provider.dart';
import 'package:novel_app/providers/tts_provider.dart';
import 'package:novel_app/screens/reading_screen.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:novel_app/widgets/continuous_chapter_view.dart';
import 'package:provider/provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('novel reader switches all four modes without losing the route', (
    tester,
  ) async {
    await StorageService().init();
    final readingProvider = ReadingProvider();
    readingProvider.previewSettings(
      readingProvider.settings.copyWith(
        pageMode: NovelPageMode.verticalScroll,
        useSystemBrightness: true,
      ),
    );
    final chapters = List<Chapter>.generate(
      3,
      (chapterIndex) => Chapter(
        id: 'local-$chapterIndex',
        novelId: 'reader-mode-integration',
        title: '第 ${chapterIndex + 1} 章 本地测试',
        index: chapterIndex,
        content: List.generate(
          80,
          (paragraph) => '　　第 $chapterIndex 章第 $paragraph 段，用于验证滚动、分页和字符锚点。',
        ).join('\n\n'),
      ),
    );
    final novel = Novel(
      id: 'reader-mode-integration',
      title: '阅读器模式集成测试',
      sourceId: 'local',
      isLocal: true,
      totalChapters: chapters.length,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReadingProvider>.value(value: readingProvider),
          ChangeNotifierProvider(create: (_) => BookshelfProvider()),
          ChangeNotifierProvider(create: (_) => BookSourceProvider()),
          ChangeNotifierProvider(create: (_) => InteractionAuthProvider()),
          ChangeNotifierProvider(create: (_) => TtsProvider()),
        ],
        child: MaterialApp(
          home: ReadingScreen(
            novel: novel,
            chapters: chapters,
            startChapterIndex: 1,
            startCharPosition: 36,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ContinuousChapterView), findsOneWidget);
    expect(find.text(chapters[1].title), findsWidgets);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await tester.pump(const Duration(milliseconds: 350));

    for (final mode in <NovelPageMode>[
      NovelPageMode.horizontalSlide,
      NovelPageMode.cover,
      NovelPageMode.simulation,
    ]) {
      readingProvider.previewSettings(
        readingProvider.settings.copyWith(pageMode: mode),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NovelPagedView), findsOneWidget);
      expect(readingProvider.settings.pageMode, mode);
      await tester.drag(find.byType(PageView), const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(find.byType(ReadingScreen), findsOneWidget);
    }

    readingProvider.previewSettings(
      readingProvider.settings.copyWith(pageMode: NovelPageMode.verticalScroll),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ContinuousChapterView), findsOneWidget);
    expect(find.text(chapters[1].title), findsWidgets);

    await tester.tapAt(tester.getCenter(find.byType(ReadingScreen)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.byTooltip('添加书签'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    readingProvider.dispose();
  });
}
