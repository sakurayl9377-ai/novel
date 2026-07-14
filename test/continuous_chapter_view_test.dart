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
}
