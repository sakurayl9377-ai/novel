import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/utils/reading_text_range.dart';
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

  testWidgets('one upward gesture loads only one adjacent previous chapter', (
    tester,
  ) async {
    final reportedChapters = <int>[];
    final requestedChapters = <int>[];
    final chapters = List<Chapter>.generate(6, chapter);
    final content = List<String>.filled(420, 'chapter body').join(' ');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: ContinuousChapterView(
              chapters: chapters,
              initialChapterIndex: 5,
              initialContent: content,
              initialTextOffset: 0,
              loadChapterContent: (index) async {
                requestedChapters.add(index);
                return content;
              },
              sectionBuilder: (chapter, index, text, textKey) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(chapter.title),
                  Text(text, key: textKey),
                ],
              ),
              onReadingPositionChanged: (index, text, position) {
                reportedChapters.add(index);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    requestedChapters.clear();
    reportedChapters.clear();

    await tester.drag(find.byType(Scrollable), const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(requestedChapters, contains(4));
    expect(requestedChapters, isNot(contains(3)));
    expect(reportedChapters, contains(4));
    expect(reportedChapters, isNot(contains(3)));
  });

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
    'keeps restoring the persisted text offset while the layout changes',
    (tester) async {
      final content = List<String>.generate(
        220,
        (index) => 'line $index body text',
      ).join('\n');
      final initialOffset = content.indexOf('line 120 body text');
      final controller = ContinuousChapterViewController();
      Key? bodyTextKey;
      var fontSize = 16.0;
      var layoutChangeScheduled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 420,
              child: StatefulBuilder(
                builder: (context, setState) {
                  if (!layoutChangeScheduled) {
                    layoutChangeScheduled = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      setState(() => fontSize = 24);
                    });
                  }
                  return ContinuousChapterView(
                    controller: controller,
                    layoutKey: fontSize,
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
                            style: TextStyle(fontSize: fontSize, height: 1.5),
                          ),
                        ],
                      );
                    },
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
      final anchor = controller.captureAnchor();
      final renderedAnchor = controller.captureRenderedAnchor();
      final leadingAnchor = controller.captureLeadingVisibleAnchor();

      expect(anchor, isNotNull);
      expect(anchor!.chapterIndex, 0);
      expect(anchor.charPosition, closeTo(initialOffset, 24));
      expect(renderedAnchor, isNotNull);
      expect(renderedAnchor!.charPosition, closeTo(initialOffset, 24));
      expect(leadingAnchor, isNotNull);
      expect(
        leadingAnchor!.charPosition,
        lessThan(renderedAnchor.charPosition),
      );
      expect(caretY, closeTo(viewport.top + viewport.height * 0.38, 1));
    },
  );

  testWidgets(
    'leading anchor skips a chapter whose body is above its trailing padding',
    (tester) async {
      const firstContent = '　　上一章最后一段。';
      const secondContent = '　　下一章第一句。第二句。';
      final controller = ContinuousChapterViewController();
      final textKeys = <int, Key>{};

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 260,
              child: ContinuousChapterView(
                controller: controller,
                chapters: [chapter(0), chapter(1)],
                initialChapterIndex: 0,
                initialContent: firstContent,
                initialTextOffset: 0,
                loadChapterContent: (index) async =>
                    index == 1 ? secondContent : '',
                sectionBuilder: (chapter, index, body, textKey) {
                  textKeys[index] = textKey;
                  return SizedBox(
                    key: ValueKey('leading-section-$index'),
                    height: 180,
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

      expect(textKeys.keys, containsAll(<int>[0, 1]));
      final viewport = tester.getRect(find.byType(ContinuousChapterView));
      final firstBody = find.byKey(textKeys[0]!);
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      final target =
          (scrollable.position.pixels +
                  tester.getRect(firstBody).bottom -
                  viewport.top +
                  2)
              .clamp(
                scrollable.position.minScrollExtent,
                scrollable.position.maxScrollExtent,
              )
              .toDouble();
      scrollable.position.jumpTo(target);
      await tester.pump();

      final anchorY = viewport.top + 1;
      expect(tester.getRect(firstBody).bottom, lessThanOrEqualTo(anchorY));
      expect(
        tester.getRect(find.byKey(const ValueKey('leading-section-0'))).bottom,
        greaterThan(anchorY),
      );
      final secondBodyRect = tester.getRect(find.byKey(textKeys[1]!));
      expect(secondBodyRect.top, greaterThan(anchorY));
      expect(secondBodyRect.top, lessThan(viewport.bottom));

      final leading = controller.captureLeadingVisibleAnchor();
      expect(leading, isNotNull);
      expect(leading!.chapterIndex, 1);
      expect(leading.charPosition, 0);
      expect(
        readingParagraphStartForOffset(leading.content, leading.charPosition),
        secondContent.indexOf('下'),
      );
    },
  );

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

      reloadZero.complete('body 0 reloaded');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
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
