import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/main.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final testDir = Directory.systemTemp.createTempSync('novel_app_test_');
    addTearDown(() {
      if (testDir.existsSync()) {
        testDir.deleteSync(recursive: true);
      }
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return testDir.path;
        }
        return null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (call) async => 1,
    );
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => StorageService().init());

    await tester.pumpWidget(const NovelApp());
    expect(_textFieldWithHint('搜索小说'), findsOneWidget);

    await tester.tap(find.text('我的'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('我的书架'), findsOneWidget);

    tester.widget<ListTile>(find.widgetWithText(ListTile, '我的书架')).onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byTooltip('搜索书架'), findsOneWidget);

    await tester.tap(find.text('动漫'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_textFieldWithHint('搜索动漫'), findsOneWidget);

    await tester.tap(find.text('我的'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('动漫播放历史'), findsOneWidget);
    expect(find.byTooltip('搜索书架'), findsNothing);

    await tester.tap(find.text('小说'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_textFieldWithHint('搜索小说'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_textFieldWithHint('搜索小说'), findsOneWidget);
    expect(_textFieldWithHint('搜索动漫'), findsNothing);
  });
}

Finder _textFieldWithHint(String hintText) {
  return find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == hintText,
  );
}
