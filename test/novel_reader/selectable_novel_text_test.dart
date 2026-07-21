import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/novel_reader/selectable_novel_text.dart';

void main() {
  testWidgets(
    'native selection forwards one body tap but not drag or long press',
    (tester) async {
      var tapCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => tapCount++,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 280,
                  child: SelectableNovelText(
                    text: '　　第一句。第二句。',
                    style: const TextStyle(fontSize: 20),
                    paragraphSpacing: 0.8,
                    onTap: () => tapCount++,
                    onListenFromOffset: _ignoreOffset,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final richText = find.byType(RichText).last;
      await tester.tap(richText);
      await tester.pump();
      expect(tapCount, 1);

      await tester.drag(richText, const Offset(0, -40));
      await tester.pump();
      expect(tapCount, 1);

      await tester.longPress(richText);
      await tester.pumpAndSettle();
      expect(find.text('从本段听'), findsOneWidget);
      expect(tapCount, 1);
    },
  );

  testWidgets('selection toolbar offers listen from paragraph', (tester) async {
    int? selectedOffset;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: SelectableNovelText(
                text: '　　第一句。第二句。',
                globalStartOffset: 40,
                style: const TextStyle(fontSize: 20),
                paragraphSpacing: 0.8,
                onListenFromOffset: (offset) => selectedOffset = offset,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(RichText).last);
    await tester.pumpAndSettle();

    expect(find.text('从本段听'), findsOneWidget);
    await tester.tap(find.text('从本段听'));
    await tester.pumpAndSettle();

    expect(selectedOffset, 42);
  });

  testWidgets('toolbar copy returns canonical indentation instead of glyphs', (
    tester,
  ) async {
    const text = '　　第一句。第二句。';
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: SelectableNovelText(
                text: text,
                style: TextStyle(fontSize: 20),
                paragraphSpacing: 0.8,
              ),
            ),
          ),
        ),
      ),
    );

    final richText = find.byType(RichText).last;
    await tester.longPressAt(tester.getTopLeft(richText) + const Offset(5, 12));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Copy'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(copied, isNotNull);
    expect(copied, isNotEmpty);
    expect(text.startsWith(copied!), isTrue);
    expect(copied, isNot(contains('国')));
  });

  testWidgets('control-a control-c copies the complete canonical source', (
    tester,
  ) async {
    const text = '　　第一句。\n\n　　第二段！';
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: SelectableNovelText(
              text: text,
              style: TextStyle(fontSize: 20),
              paragraphSpacing: 0.8,
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(RichText).last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(copied, text);
  });

  testWidgets('paged share action sends canonical paragraph text', (
    tester,
  ) async {
    const text = '　　第一句。\n\n　　第二段！';
    String? sharedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Share.invoke') {
            sharedText = call.arguments as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: SelectableNovelText(
              text: text,
              style: TextStyle(fontSize: 20),
              paragraphSpacing: 0.8,
              useNativeSelection: false,
              onListenFromOffset: _ignoreOffset,
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.byType(RichText).last);
    await tester.pump(const Duration(milliseconds: 300));
    if (find.text('Share').evaluate().isEmpty) {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.text('Share'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(sharedText, isNotNull);
    expect(sharedText, isNotEmpty);
    expect(text.contains(sharedText!), isTrue);
    expect(sharedText, isNot(contains('国')));
  });
}

void _ignoreOffset(int _) {}
