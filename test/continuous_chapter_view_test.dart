import 'package:flutter/material.dart';
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

  testWidgets('preloads adjacent chapters into one continuous scroll view', (
    tester,
  ) async {
    final requestedIndexes = <int>[];
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
              sectionBuilder: (chapter, index, content) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Text(chapter.title), Text(content)],
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

    expect(requestedIndexes, containsAll(<int>[0, 2]));
    expect(find.text('Chapter 0'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsOneWidget);

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
              sectionBuilder: (chapter, index, content) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Text(chapter.title), Text(content)],
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
                sectionBuilder: (chapter, index, content) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [Text(chapter.title), Text(content)],
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
    },
  );
}
