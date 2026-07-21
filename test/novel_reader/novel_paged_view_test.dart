import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/novel_reader/novel_paged_view.dart';
import 'package:novel_app/features/reader_core/reader_modes.dart';
import 'package:novel_app/utils/reading_text_range.dart';

void main() {
  final content = List.generate(
    80,
    (index) => '　　这是第$index段正文，用于验证真实分页、字符锚点和虚拟化翻页。',
  ).join('\n\n');

  Widget app({
    required NovelPageMode mode,
    required NovelPagedViewController controller,
    required int initialOffset,
    TextRange activeRange = TextRange.empty,
    void Function(int page, int offset)? onChanged,
    ValueChanged<int>? onListenFromOffset,
    VoidCallback? onToggleControls,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          height: 720,
          child: NovelPagedView(
            controller: controller,
            content: content,
            chapterTitle: '第一章 测试章节',
            mode: mode,
            textStyle: const TextStyle(fontSize: 20, height: 1.75),
            paragraphSpacing: 0.85,
            horizontalPadding: 24,
            initialTextOffset: initialOffset,
            activeTextRange: activeRange,
            onPositionChanged: onChanged ?? (_, _) {},
            onPositionSettled: (_, _) {},
            onNeedNextChapter: () async {},
            onNeedPreviousChapter: () async {},
            onToggleControls: onToggleControls ?? () {},
            onListenFromOffset: onListenFromOffset,
          ),
        ),
      ),
    );
  }

  for (final mode in <NovelPageMode>[
    NovelPageMode.horizontalSlide,
    NovelPageMode.cover,
    NovelPageMode.simulation,
  ]) {
    testWidgets('${mode.code} renders and turns from the exact anchor', (
      tester,
    ) async {
      final controller = NovelPagedViewController();
      final changes = <(int, int)>[];
      await tester.pumpWidget(
        app(
          mode: mode,
          controller: controller,
          initialOffset: content.length ~/ 3,
          onChanged: (page, offset) => changes.add((page, offset)),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.currentPage, greaterThan(0));
      final previous = controller.currentPage;
      final turn = controller.nextPage();
      await tester.pumpAndSettle();
      expect(await turn, isTrue);
      expect(controller.currentPage, previous + 1);
      expect(changes.last.$2, greaterThan(0));
      // PageView.builder keeps only a small current/adjacent working set.
      expect(find.byType(RichText).evaluate().length, lessThan(8));
    });
  }

  testWidgets('simulation curl follows the drag and settles by threshold', (
    tester,
  ) async {
    final controller = NovelPagedViewController();
    await tester.pumpWidget(
      app(
        mode: NovelPageMode.simulation,
        controller: controller,
        initialOffset: content.length ~/ 3,
        onListenFromOffset: (_) {},
      ),
    );
    await tester.pumpAndSettle();

    final initialPage = controller.currentPage;
    final pageView = find.byType(PageView);
    final gesture = await tester.startGesture(tester.getCenter(pageView));
    await gesture.moveBy(const Offset(-28, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-72, 0));
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.byKey(const ValueKey('novel-paper-curl-front')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('novel-paper-curl-overlay')),
      findsOneWidget,
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.currentPage, initialPage);
    expect(
      find.byKey(const ValueKey('novel-paper-curl-overlay')),
      findsNothing,
    );

    await tester.drag(pageView, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.currentPage, initialPage + 1);
    expect(find.byType(RichText).evaluate().length, lessThan(8));
  });

  testWidgets(
    'paged paragraph menu preserves taps and reports paragraph start',
    (tester) async {
      final controller = NovelPagedViewController();
      var toggleCount = 0;
      int? listenOffset;
      await tester.pumpWidget(
        app(
          mode: NovelPageMode.horizontalSlide,
          controller: controller,
          initialOffset: 0,
          onToggleControls: () => toggleCount++,
          onListenFromOffset: (offset) => listenOffset = offset,
        ),
      );
      await tester.pumpAndSettle();

      final pageView = find.byType(PageView);
      await tester.tapAt(tester.getCenter(pageView));
      await tester.pump();
      expect(toggleCount, 1);

      final richText = find.byType(RichText).hitTestable().first;
      await tester.longPressAt(tester.getCenter(richText));
      await tester.pumpAndSettle();
      expect(find.text('从本段听'), findsOneWidget);

      await tester.tap(find.text('从本段听'));
      await tester.pumpAndSettle();
      expect(listenOffset, isNotNull);
      expect(content[listenOffset!], '这');
      expect(
        readingParagraphStartForOffset(content, listenOffset!),
        listenOffset,
      );
    },
  );

  testWidgets('TTS active paragraph follows to its paginated page', (
    tester,
  ) async {
    final controller = NovelPagedViewController();
    await tester.pumpWidget(
      app(
        mode: NovelPageMode.horizontalSlide,
        controller: controller,
        initialOffset: 0,
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.currentPage, 0);

    final target = content.length - 80;
    await tester.pumpWidget(
      app(
        mode: NovelPageMode.horizontalSlide,
        controller: controller,
        initialOffset: 0,
        activeRange: TextRange(start: target, end: target + 40),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.currentPage, greaterThan(0));
  });

  testWidgets('updated initial offset relocates the existing paged view', (
    tester,
  ) async {
    final controller = NovelPagedViewController();
    await tester.pumpWidget(
      app(
        mode: NovelPageMode.horizontalSlide,
        controller: controller,
        initialOffset: 0,
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.currentPage, 0);

    final target = content.length * 3 ~/ 4;
    await tester.pumpWidget(
      app(
        mode: NovelPageMode.horizontalSlide,
        controller: controller,
        initialOffset: target,
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.currentPage, greaterThan(0));
    expect(controller.currentCharPosition, lessThanOrEqualTo(target));
  });

  testWidgets('switching page effects never shares one PageController', (
    tester,
  ) async {
    final controller = NovelPagedViewController();
    await tester.pumpWidget(
      app(
        mode: NovelPageMode.horizontalSlide,
        controller: controller,
        initialOffset: content.length ~/ 2,
      ),
    );
    await tester.pumpAndSettle();

    for (final mode in <NovelPageMode>[
      NovelPageMode.cover,
      NovelPageMode.simulation,
      NovelPageMode.horizontalSlide,
    ]) {
      await tester.pumpWidget(
        app(
          mode: mode,
          controller: controller,
          initialOffset: content.length ~/ 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(PageView), findsOneWidget);
    }
  });
}
