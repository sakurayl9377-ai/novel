import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/widgets/continuous_chapter_view.dart';

void main() {
  Chapter chapter(int index) {
    return Chapter(
      id: 'chapter-$index',
      novelId: 'novel-1',
      title: 'Chapter $index',
      index: index,
    );
  }

  testWidgets('preloads following data without building an offscreen chapter', (
    tester,
  ) async {
    final requestedIndexes = <int>[];
    final builtIndexes = <int>{};
    final positions = <int>[];
    final chapters = List<Chapter>.generate(3, chapter);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: ContinuousChapterView(
              chapters: chapters,
              initialChapterIndex: 1,
              initialContent: List<String>.filled(
                120,
                'current chapter',
              ).join(' '),
              initialTextOffset: 0,
              loadChapterContent: (index) async {
                requestedIndexes.add(index);
                return List<String>.filled(100, 'chapter $index').join(' ');
              },
              sectionBuilder: (chapter, index, content, textKey) {
                builtIndexes.add(index);
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(chapter.title),
                      Text(content, key: textKey),
                    ],
                  ),
                );
              },
              onReadingPositionChanged: (index, content, charPosition) {
                positions.add(index);
              },
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(requestedIndexes, contains(2));
    expect(requestedIndexes, isNot(contains(0)));
    expect(find.text('Chapter 0'), findsNothing);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsNothing);
    expect(builtIndexes, {1});
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);

    await tester.drag(find.byType(Scrollable), const Offset(0, -350));
    await tester.pump();

    expect(positions, isNotEmpty);
  });

  testWidgets('programmatic TTS follow-scroll never reports a chapter switch', (
    tester,
  ) async {
    final positions = <int>[];
    final chapters = List<Chapter>.generate(3, chapter);
    final currentContent = List<String>.filled(
      320,
      'current chapter',
    ).join(' ');

    Widget buildReader({int? activeTextOffset}) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: ContinuousChapterView(
              chapters: chapters,
              initialChapterIndex: 1,
              initialContent: currentContent,
              initialTextOffset: 0,
              activeChapterIndex: activeTextOffset == null ? null : 1,
              activeTextOffset: activeTextOffset,
              loadChapterContent: (index) async =>
                  List<String>.filled(260, 'chapter $index').join(' '),
              sectionBuilder: (chapter, index, content, textKey) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(chapter.title),
                      Text(content, key: textKey),
                    ],
                  ),
                );
              },
              onReadingPositionChanged: (index, content, charPosition) {
                positions.add(index);
              },
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildReader());
    await tester.pumpAndSettle();
    positions.clear();

    await tester.pumpWidget(
      buildReader(activeTextOffset: currentContent.length - 1),
    );
    await tester.pumpAndSettle();

    expect(positions, isEmpty);
  });

  testWidgets(
    'a manual upward swipe enters the previous chapter near its end',
    (tester) async {
      final positions = <(int, int)>[];
      final controller = ContinuousChapterViewController();
      final chapters = List<Chapter>.generate(3, chapter);
      final previousContent = List<String>.filled(
        500,
        'previous chapter',
      ).join(' ');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 420,
              child: ContinuousChapterView(
                controller: controller,
                chapters: chapters,
                initialChapterIndex: 1,
                initialContent: List<String>.filled(
                  400,
                  'current chapter',
                ).join(' '),
                initialTextOffset: 0,
                loadChapterContent: (index) async {
                  if (index == 0) return previousContent;
                  return List<String>.filled(400, 'chapter $index').join(' ');
                },
                sectionBuilder: (chapter, index, content, textKey) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(chapter.title),
                        Text(content, key: textKey),
                      ],
                    ),
                  );
                },
                onReadingPositionChanged: (index, content, charPosition) {
                  positions.add((index, charPosition));
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(Scrollable), const Offset(0, 460));
      await tester.pumpAndSettle();

      final previousPositions = positions
          .where((position) => position.$1 == 0)
          .toList();
      expect(previousPositions, isNotEmpty);
      expect(
        previousPositions.first.$2,
        greaterThan(previousContent.length * 0.7),
      );
      final visibleAnchor = controller.captureAnchor();
      expect(visibleAnchor?.chapterIndex, 0);
      expect(
        visibleAnchor?.charPosition,
        greaterThan(previousContent.length * 0.7),
      );

      positions.clear();
      for (var attempt = 0; attempt < 8; attempt++) {
        await tester.drag(find.byType(Scrollable), const Offset(0, -360));
        await tester.pumpAndSettle();
        if (positions.any((position) => position.$1 == 1)) break;
      }
      final currentChapterPositions = positions
          .where((position) => position.$1 == 1)
          .toList();
      expect(currentChapterPositions, isNotEmpty);
      expect(
        currentChapterPositions.last.$2,
        lessThan(
          List<String>.filled(400, 'current chapter').join(' ').length * 0.3,
        ),
      );
    },
  );

  testWidgets(
    'reading progress is measured from the body text, not its header',
    (tester) async {
      final positions = <int>[];
      final content = List<String>.generate(
        120,
        (index) => '第$index行正文内容',
      ).join('\n');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 420,
              child: ContinuousChapterView(
                chapters: [chapter(0)],
                initialChapterIndex: 0,
                initialContent: content,
                initialTextOffset: 0,
                loadChapterContent: (_) async => '',
                sectionBuilder: (chapter, index, body, textKey) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 320),
                      Text(
                        body,
                        key: textKey,
                        style: const TextStyle(fontSize: 20, height: 1.5),
                      ),
                    ],
                  );
                },
                onReadingPositionChanged: (_, _, charPosition) {
                  positions.add(charPosition);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(Scrollable), const Offset(0, -24));
      await tester.pumpAndSettle();

      expect(positions, isNotEmpty);
      expect(positions.last, lessThanOrEqualTo(2));
    },
  );

  testWidgets('restores the exact body-text offset at the reading anchor', (
    tester,
  ) async {
    final content = List<String>.generate(
      180,
      (index) => 'line $index body text',
    ).join('\n');
    final initialOffset = content.indexOf('line 90 body text');
    Key? bodyTextKey;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: ContinuousChapterView(
              chapters: [chapter(0)],
              initialChapterIndex: 0,
              initialContent: content,
              initialTextOffset: initialOffset,
              loadChapterContent: (_) async => '',
              sectionBuilder: (chapter, index, body, textKey) {
                bodyTextKey = textKey;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 96),
                    Text(
                      body,
                      key: textKey,
                      style: const TextStyle(fontSize: 20, height: 1.5),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final paragraph = tester.renderObject<RenderParagraph>(
      find.byKey(bodyTextKey!),
    );
    final caret = paragraph.getOffsetForCaret(
      TextPosition(offset: initialOffset),
      Rect.zero,
    );
    final caretY = paragraph.localToGlobal(caret).dy;
    final viewport = tester.getRect(find.byType(ContinuousChapterView));

    expect(caretY, closeTo(viewport.top + viewport.height * 0.38, 1));
  });

  testWidgets(
    'keeps five chapters while scrolling forward across a long novel',
    (tester) async {
      final chapters = List<Chapter>.generate(30, chapter);
      final requestedIndexes = <int>[];
      final settledChapterIndexes = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 420,
              child: ContinuousChapterView(
                chapters: chapters,
                initialChapterIndex: 0,
                initialContent: 'body 0',
                initialTextOffset: 0,
                loadChapterContent: (index) async {
                  requestedIndexes.add(index);
                  return 'body $index';
                },
                sectionBuilder: (chapter, index, body, textKey) {
                  return SizedBox(
                    key: ValueKey('bounded-section-$index'),
                    height: 720,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(body, key: textKey),
                    ),
                  );
                },
                onReadingPositionSettled: (index, _, _) {
                  settledChapterIndexes.add(index);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      int retainedChapterCount() => List<int>.generate(30, (index) => index)
          .where(
            (index) => find
                .byKey(ValueKey('bounded-section-$index'))
                .evaluate()
                .isNotEmpty,
          )
          .length;

      for (var gesture = 0; gesture < 32; gesture++) {
        await tester.drag(find.byType(Scrollable), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(retainedChapterCount(), lessThanOrEqualTo(5));
      }

      expect(requestedIndexes.toSet().length, greaterThan(12));
      expect(find.byKey(const ValueKey('bounded-section-0')), findsNothing);
      expect(settledChapterIndexes, isNotEmpty);
      for (var index = 1; index < settledChapterIndexes.length; index++) {
        expect(
          settledChapterIndexes[index],
          greaterThanOrEqualTo(settledChapterIndexes[index - 1]),
          reason: 'forward scrolling must not jump back to an evicted chapter',
        );
      }
    },
  );

  testWidgets(
    'top and bottom eviction preserve the visible anchor and allow reload',
    (tester) async {
      final chapters = List<Chapter>.generate(8, chapter);
      final loadFive = Completer<String>();
      final reloadZero = Completer<String>();
      final requestedIndexes = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 420,
              child: ContinuousChapterView(
                chapters: chapters,
                initialChapterIndex: 0,
                initialContent: 'body 0',
                initialTextOffset: 0,
                loadChapterContent: (index) {
                  requestedIndexes.add(index);
                  if (index == 5) return loadFive.future;
                  if (index == 0) return reloadZero.future;
                  return Future<String>.value('body $index');
                },
                sectionBuilder: (chapter, index, body, textKey) {
                  return SizedBox(
                    key: ValueKey('eviction-section-$index'),
                    height: 360,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(body, key: textKey),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (
        var gesture = 0;
        gesture < 12 && !requestedIndexes.contains(5);
        gesture++
      ) {
        await tester.drag(find.byType(Scrollable), const Offset(0, -280));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(requestedIndexes, contains(5));
      expect(find.byKey(const ValueKey('eviction-section-0')), findsNothing);

      Finder anchoredSectionFinder() {
        final viewport = tester.getRect(find.byType(ContinuousChapterView));
        final anchorY = viewport.top + viewport.height * 0.38;
        for (var index = 0; index < chapters.length; index++) {
          final finder = find.byKey(ValueKey('eviction-section-$index'));
          if (finder.evaluate().isEmpty) continue;
          final rect = tester.getRect(finder);
          if (rect.top <= anchorY && rect.bottom > anchorY) return finder;
        }
        throw TestFailure('No retained chapter contains the reading anchor');
      }

      final forwardAnchor = anchoredSectionFinder();
      final forwardAnchorTop = tester.getTopLeft(forwardAnchor).dy;
      loadFive.complete('body 5');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.byKey(const ValueKey('eviction-section-0')), findsNothing);
      expect(tester.getTopLeft(forwardAnchor).dy, closeTo(forwardAnchorTop, 1));

      for (
        var gesture = 0;
        gesture < 12 && requestedIndexes.where((index) => index == 0).isEmpty;
        gesture++
      ) {
        await tester.drag(find.byType(Scrollable), const Offset(0, 120));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(requestedIndexes.where((index) => index == 0), hasLength(1));

      final backwardAnchor = anchoredSectionFinder();
      final backwardAnchorTop = tester.getTopLeft(backwardAnchor).dy;
      reloadZero.complete('body 0 reloaded');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        tester.getTopLeft(backwardAnchor).dy,
        closeTo(backwardAnchorTop, 1),
      );
      for (
        var gesture = 0;
        gesture < 6 &&
            find.byKey(const ValueKey('eviction-section-0')).evaluate().isEmpty;
        gesture++
      ) {
        await tester.drag(find.byType(Scrollable), const Offset(0, 120));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const ValueKey('eviction-section-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('eviction-section-5')), findsNothing);
      final retainedCount = List<int>.generate(8, (index) => index)
          .where(
            (index) => find
                .byKey(ValueKey('eviction-section-$index'))
                .evaluate()
                .isNotEmpty,
          )
          .length;
      expect(retainedCount, inInclusiveRange(1, 3));
    },
  );
}
