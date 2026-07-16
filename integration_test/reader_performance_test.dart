import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_app/features/manga_reader/manga_reader_preferences.dart';
import 'package:novel_app/features/novel_reader/novel_paged_view.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/models/manga.dart';
import 'package:novel_app/screens/manga_reader_screen.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:novel_app/widgets/continuous_chapter_view.dart';

const _freezeThresholdMs = 700.0;
const _steadyFrameBudgetMicros = 16700;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('offline reader scenarios stay below the frozen-frame budget', (
    tester,
  ) async {
    final summaries = <String, Object?>{};

    await _mountNovelScroll(tester);
    summaries['novel_scroll'] = await _measure(
      binding,
      'novel_scroll',
      () => _exerciseVerticalScroll(
        tester,
        find.byKey(const ValueKey<String>('perf-novel-scroll')),
      ),
    );

    await _mountNovelPaged(tester);
    summaries['novel_paged'] = await _measure(
      binding,
      'novel_paged',
      () => _exercisePages(
        tester,
        find.byKey(const ValueKey<String>('novel-pages')),
        forwardTurns: 8,
        backwardTurns: 5,
      ),
    );

    final storage = StorageService();
    await storage.init();
    await _mountManga(tester, storage, MangaReadingMode.longStrip);
    summaries['manga_long_strip'] = await _measure(
      binding,
      'manga_long_strip',
      () => _exerciseVerticalScroll(
        tester,
        find.byKey(const ValueKey<String>('manga-chapter-perf-manga-chapter')),
      ),
    );

    await _mountManga(tester, storage, MangaReadingMode.paged);
    summaries['manga_paged'] = await _measure(
      binding,
      'manga_paged',
      () => _exercisePages(
        tester,
        find.byKey(const ValueKey<String>('manga-paged-view')),
        forwardTurns: 8,
        backwardTurns: 5,
      ),
    );

    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['reader_performance_summary'] = <String, Object?>{
      'device_target': 'Pixel 10 Pro emulator',
      'build_mode': 'profile',
      'frame_budget_ms': 16.7,
      'freeze_threshold_ms': _freezeThresholdMs,
      'scenarios': summaries,
    };
    debugPrint(
      'READER_PERFORMANCE_SUMMARY\n'
      '${const JsonEncoder.withIndent('  ').convert(summaries)}',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });
}

Future<Map<String, Object?>> _measure(
  IntegrationTestWidgetsFlutterBinding binding,
  String reportKey,
  Future<void> Function() action,
) async {
  await binding.watchPerformance(action, reportKey: reportKey);
  final raw = binding.reportData?[reportKey];
  expect(
    raw,
    isA<Map>(),
    reason: '$reportKey did not produce FrameTiming data',
  );
  final summary = Map<String, dynamic>.from(raw! as Map);
  final frameCount = (summary['frame_count'] as num).toInt();
  final worstBuild = (summary['worst_frame_build_time_millis'] as num)
      .toDouble();
  final worstRaster = (summary['worst_frame_rasterizer_time_millis'] as num)
      .toDouble();
  final buildTimes = (summary['frame_build_times'] as List)
      .cast<num>()
      .map((value) => value.toInt())
      .toList(growable: false);
  final rasterTimes = (summary['frame_rasterizer_times'] as List)
      .cast<num>()
      .map((value) => value.toInt())
      .toList(growable: false);

  expect(
    frameCount,
    greaterThan(20),
    reason: '$reportKey sampled too few frames',
  );
  expect(
    worstBuild,
    lessThan(_freezeThresholdMs),
    reason: '$reportKey produced a frozen build frame',
  );
  expect(
    worstRaster,
    lessThan(_freezeThresholdMs),
    reason: '$reportKey produced a frozen raster frame',
  );

  final readable = <String, Object?>{
    'frame_count': frameCount,
    'build': _stageSummary(summary, 'build', buildTimes),
    'raster': _stageSummary(summary, 'rasterizer', rasterTimes),
    'frozen_frame':
        worstBuild >= _freezeThresholdMs || worstRaster >= _freezeThresholdMs,
  };
  debugPrint('READER_PERF $reportKey ${jsonEncode(readable)}');
  return readable;
}

Map<String, Object?> _stageSummary(
  Map<String, dynamic> summary,
  String stage,
  List<int> timesMicros,
) {
  final overBudget = timesMicros
      .where((value) => value > _steadyFrameBudgetMicros)
      .length;
  return <String, Object?>{
    'average_ms': summary['average_frame_${stage}_time_millis'],
    'p90_ms': summary['90th_percentile_frame_${stage}_time_millis'],
    'p99_ms': summary['99th_percentile_frame_${stage}_time_millis'],
    'worst_ms': summary['worst_frame_${stage}_time_millis'],
    'over_16_7ms_count': overBudget,
    'over_16_7ms': overBudget > 0,
  };
}

Future<void> _mountNovelScroll(WidgetTester tester) async {
  final chapters = List<Chapter>.generate(
    5,
    (index) => Chapter(
      id: 'perf-novel-$index',
      novelId: 'perf-novel',
      title: 'Chapter ${index + 1}',
      index: index,
      content: _novelBody(index),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF3E9D3),
        body: SafeArea(
          child: ContinuousChapterView(
            key: const ValueKey<String>('perf-novel-scroll'),
            chapters: chapters,
            initialChapterIndex: 2,
            initialContent: chapters[2].content,
            initialTextOffset: 0,
            loadChapterContent: (index) async => chapters[index].content,
            sectionBuilder: (chapter, index, content, textKey) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(26, 34, 26, 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      chapter.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 23,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF352F28),
                      ),
                    ),
                    const SizedBox(height: 26),
                    Text(
                      content,
                      key: textKey,
                      textAlign: TextAlign.justify,
                      style: const TextStyle(
                        fontSize: 23,
                        height: 2.2,
                        color: Color(0xFF352F28),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _mountNovelPaged(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF3E9D3),
        body: SafeArea(
          child: NovelPagedView(
            content: _novelBody(9),
            chapterTitle: 'Synthetic pagination chapter',
            mode: NovelPageMode.simulation,
            textStyle: const TextStyle(
              fontSize: 23,
              height: 2.2,
              color: Color(0xFF352F28),
            ),
            paragraphSpacing: 0.85,
            horizontalPadding: 26,
            initialTextOffset: 0,
            onPositionChanged: (_, _) {},
            onPositionSettled: (_, _) {},
            onNeedNextChapter: () async {},
            onNeedPreviousChapter: () async {},
            onToggleControls: () {},
            pageBackgroundColor: const Color(0xFFF3E9D3),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _mountManga(
  WidgetTester tester,
  StorageService storage,
  MangaReadingMode mode,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  await storage.setString(
    MangaReaderPreferences.storageKey,
    MangaReaderPreferences(
      readingMode: mode,
      spreadMode: MangaSpreadMode.double,
      pageDirection: MangaPageDirection.ltr,
    ).encode(),
  );

  const chapter = MangaChapter(
    title: 'Synthetic chapter',
    url: 'perf-manga-chapter',
  );
  const pageCount = 28;
  final images = List<String>.generate(
    pageCount,
    (index) => 'offline-page-$index',
  );
  const manga = Manga(
    id: 'perf-manga',
    title: 'Synthetic offline manga',
    chapters: <MangaChapter>[chapter],
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MangaReaderScreen(
        manga: manga,
        chapter: chapter,
        chapterIndex: 0,
        warmVisiblePage: false,
        canLoadChapterOverride: (_) => true,
        chapterImageLoader: (_) async => images,
        mangaPageBuilder: (_, _, pageIndex, _) {
          return _SyntheticMangaPage(
            pageIndex: pageIndex,
            longStrip: mode == MangaReadingMode.longStrip,
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _exerciseVerticalScroll(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  for (var index = 0; index < 6; index++) {
    await tester.timedDrag(
      finder,
      const Offset(0, -520),
      const Duration(milliseconds: 620),
      frequency: 60,
    );
    await tester.pump(const Duration(milliseconds: 80));
  }
  for (var index = 0; index < 3; index++) {
    await tester.timedDrag(
      finder,
      const Offset(0, 420),
      const Duration(milliseconds: 540),
      frequency: 60,
    );
    await tester.pump(const Duration(milliseconds: 80));
  }
  await tester.pumpAndSettle();
}

Future<void> _exercisePages(
  WidgetTester tester,
  Finder finder, {
  required int forwardTurns,
  required int backwardTurns,
}) async {
  expect(finder, findsOneWidget);
  for (var index = 0; index < forwardTurns; index++) {
    await tester.timedDrag(
      finder,
      const Offset(-300, 0),
      const Duration(milliseconds: 360),
      frequency: 60,
    );
    await tester.pumpAndSettle();
  }
  for (var index = 0; index < backwardTurns; index++) {
    await tester.timedDrag(
      finder,
      const Offset(300, 0),
      const Duration(milliseconds: 360),
      frequency: 60,
    );
    await tester.pumpAndSettle();
  }
}

String _novelBody(int chapterIndex) {
  return List<String>.generate(180, (paragraph) {
    return 'Paragraph ${paragraph + 1} of chapter ${chapterIndex + 1}. '
        'The reader keeps a stable character anchor while text moves through '
        'the viewport. This deterministic offline passage exercises justified '
        'layout, paragraph spacing, repaint boundaries, and page transitions.';
  }).join('\n\n');
}

class _SyntheticMangaPage extends StatelessWidget {
  const _SyntheticMangaPage({required this.pageIndex, required this.longStrip});

  final int pageIndex;
  final bool longStrip;

  @override
  Widget build(BuildContext context) {
    final page = RepaintBoundary(
      child: CustomPaint(
        painter: _SyntheticMangaPainter(pageIndex),
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              child: Text(
                'PAGE ${pageIndex + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (longStrip) {
      return SizedBox(height: 1080 + (pageIndex % 3) * 120, child: page);
    }
    return SizedBox.expand(child: page);
  }
}

class _SyntheticMangaPainter extends CustomPainter {
  const _SyntheticMangaPainter(this.pageIndex);

  final int pageIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final baseHue = (pageIndex * 31) % 360;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            HSVColor.fromAHSV(1, baseHue.toDouble(), 0.42, 0.92).toColor(),
            HSVColor.fromAHSV(1, (baseHue + 75) % 360, 0.58, 0.42).toColor(),
          ],
        ).createShader(rect),
    );

    final panelPaint = Paint()..color = Colors.white.withValues(alpha: 0.17);
    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black.withValues(alpha: 0.42);
    final rowHeight = size.height / 9;
    for (var row = 0; row < 8; row++) {
      final inset = 18.0 + (row % 3) * 14;
      final panel = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          inset,
          rowHeight * row + 22,
          size.width - inset * 2,
          rowHeight - 12,
        ),
        const Radius.circular(14),
      );
      canvas.drawRRect(panel, panelPaint);
      canvas.drawRRect(panel, outlinePaint);
    }

    final accent = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.72);
    final path = Path()..moveTo(size.width * 0.12, size.height * 0.14);
    for (var point = 1; point <= 18; point++) {
      final x = size.width * (0.12 + (point % 5) * 0.19);
      final y = size.height * (0.14 + point * 0.043);
      path.lineTo(x, y);
    }
    canvas.drawPath(path, accent);
  }

  @override
  bool shouldRepaint(covariant _SyntheticMangaPainter oldDelegate) {
    return pageIndex != oldDelegate.pageIndex;
  }
}
