import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/manga_reader/manga_page_pipeline.dart';
import 'package:novel_app/features/manga_reader/manga_paged_view.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';

void main() {
  testWidgets('paged view renders a double spread and reports source pages', (
    tester,
  ) async {
    final changes = <List<int>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaPagedView(
            spreads: const [
              MangaPageSpread([0, 1]),
              MangaPageSpread([2]),
            ],
            direction: MangaPageDirection.ltr,
            initialPageIndex: 0,
            pageBuilder: (_, pageIndex, _) => Text('page-$pageIndex'),
            endBuilder: (_) => const Text('end'),
            onPageChanged: (first, last) => changes.add([first, last]),
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.text('page-0'), findsOneWidget);
    expect(find.text('page-1'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(find.text('page-2'), findsOneWidget);
    expect(changes.last, [2, 2]);
  });

  testWidgets('tall source pages scroll vertically without crop slots', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaPagedView(
            spreads: const [
              MangaPageSpread([0], aspectRatios: [0.22]),
            ],
            direction: MangaPageDirection.ltr,
            initialPageIndex: 0,
            pageBuilder: (context, index, width) => ColoredBox(
              color: Colors.blue,
              child: SizedBox(width: width, height: double.infinity),
            ),
            endBuilder: (_) => const SizedBox.shrink(),
            onPageChanged: (_, _) {},
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manga-paged-tall-scroll')), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('double tap zoom wins before horizontal page movement', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaPagedView(
            spreads: const [
              MangaPageSpread([0]),
              MangaPageSpread([1]),
            ],
            direction: MangaPageDirection.ltr,
            initialPageIndex: 0,
            pageBuilder: (_, pageIndex, _) => Text('page-$pageIndex'),
            endBuilder: (_) => const SizedBox.shrink(),
            onPageChanged: (_, _) {},
            onTap: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('page-0'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('page-0'));
    await tester.pump(const Duration(milliseconds: 400));
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.physics, isA<NeverScrollableScrollPhysics>());
  });
}
