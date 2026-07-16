import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/features/reader_core/reader_core.dart';

void main() {
  testWidgets('chrome overlays a stable, full-size content viewport', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var visible = true;
    late StateSetter updateHost;

    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return ReaderShell(
              chromeVisible: visible,
              content: const ColoredBox(
                key: Key('reader-test-content'),
                color: Colors.amber,
              ),
              topChrome: const ReaderChrome.top(child: Text('顶部控制')),
              bottomChrome: const ReaderChrome.bottom(child: Text('底部控制')),
            );
          },
        ),
      ),
    );

    final contentFinder = find.byKey(const Key('reader-test-content'));
    final initialSize = tester.getSize(contentFinder);
    expect(initialSize, tester.getSize(find.byType(Scaffold)));
    expect(find.semantics.byLabel('阅读器顶部控制栏'), findsOne);
    expect(find.semantics.byLabel('阅读器底部控制栏'), findsOne);

    updateHost(() => visible = false);
    await tester.pump();

    expect(tester.getSize(contentFinder), initialSize);
    expect(find.semantics.byLabel('阅读器顶部控制栏'), findsNothing);
    expect(find.semantics.byLabel('阅读器底部控制栏'), findsNothing);

    semantics.dispose();
  });

  testWidgets('hidden chrome cannot intercept content taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        ReaderShell(
          chromeVisible: false,
          onContentTap: () => taps += 1,
          content: const SizedBox.expand(),
          topChrome: ReaderChrome.top(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps += 100,
              child: const SizedBox(height: 56),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(200, 20));
    expect(taps, 1);
  });

  testWidgets('reduced motion removes chrome and HUD transition durations', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ReaderShell(
          chromeVisible: false,
          content: SizedBox.expand(),
          topChrome: ReaderChrome.top(child: Text('顶部')),
          bottomChrome: ReaderChrome.bottom(child: Text('底部')),
          progressHud: ReaderProgressHud(label: '42%'),
        ),
        disableAnimations: true,
      ),
    );

    final chromeOpacities = tester.widgetList<AnimatedOpacity>(
      find.byKey(const Key('reader-chrome-opacity')),
    );
    expect(chromeOpacities, hasLength(2));
    expect(
      chromeOpacities.every((animation) => animation.duration == Duration.zero),
      isTrue,
    );
    final hudOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const Key('reader-progress-hud-opacity')),
    );
    expect(hudOpacity.duration, Duration.zero);
  });

  testWidgets('progress HUD exposes an optional live semantic update', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const ReaderProgressHud(
          label: '42%',
          semanticLabel: '阅读进度 42%',
          announceChanges: true,
        ),
      ),
    );

    expect(find.bySemanticsLabel('阅读进度 42%'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('阅读进度 42%')),
      matchesSemantics(label: '阅读进度 42%', isLiveRegion: true),
    );
    semantics.dispose();
  });

  testWidgets('chrome action has a 48dp target and selected semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        ReaderChrome.top(
          child: Row(
            children: [
              ReaderChromeAction(
                icon: Icons.dark_mode_outlined,
                label: '夜间模式',
                selected: true,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final action = find.bySemanticsLabel('夜间模式');
    expect(action, findsOneWidget);
    expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(action),
      matchesSemantics(
        label: '夜间模式',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('modal sheet provides a bounded surface and close action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => ReaderModalSheet.show<void>(
                context,
                title: const Text('章节目录'),
                semanticLabel: '阅读器章节目录',
                builder: (_) => const SizedBox(
                  height: 240,
                  child: Center(child: Text('第一章')),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('章节目录'), findsOneWidget);
    expect(find.text('第一章'), findsOneWidget);
    expect(find.bySemanticsLabel('阅读器章节目录'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reader-modal-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsNothing);
    semantics.dispose();
  });
}

Widget _host(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: ThemeData(
      extensions: const <ThemeExtension<dynamic>>[ReaderTokens.light],
    ),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 800),
        padding: const EdgeInsets.only(top: 24, bottom: 16),
        disableAnimations: disableAnimations,
      ),
      child: SizedBox(width: 400, height: 800, child: child),
    ),
  );
}
