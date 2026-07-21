import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/reading_settings.dart';
import 'package:novel_app/widgets/reading_settings_panel.dart';

void main() {
  testWidgets('font-size slider commits its preview when the drag ends', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final previews = <ReadingSettings>[];
    var commits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadingSettingsPanel(
            settings: ReadingSettings(fontSize: 20),
            onPreviewChanged: previews.add,
            onChangeEnd: () => commits += 1,
          ),
        ),
      ),
    );

    final fontSizeSlider = find.byWidgetPredicate(
      (widget) => widget is Slider && widget.min == 14 && widget.max == 34,
      description: 'font-size slider',
    );
    expect(fontSizeSlider, findsOneWidget);

    await tester.drag(fontSizeSlider, const Offset(120, 0));
    await tester.pump();

    expect(previews, isNotEmpty);
    expect(previews.last.fontSize, greaterThan(20));
    expect(commits, 1);
  });
}
