import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/main.dart';
import 'package:novel_app/screens/profile_screen.dart';
import 'package:novel_app/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('App smoke test', (WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const flutterTtsChannel = MethodChannel('flutter_tts');
    const audioPlayerChannel = MethodChannel('xyz.luan/audioplayers');
    const audioPlayerGlobalChannel = MethodChannel(
      'xyz.luan/audioplayers.global',
    );
    final testDir = Directory.systemTemp.createTempSync('novel_app_test_');
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        flutterTtsChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audioPlayerChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audioPlayerGlobalChannel,
        null,
      );
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
      flutterTtsChannel,
      (call) async => 1,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioPlayerChannel,
      (call) async => null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioPlayerGlobalChannel,
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => StorageService().init());

    await tester.pumpWidget(const NovelApp());
    expect(_textFieldWithHint('搜索小说'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);
    expect(find.text('动漫'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.byType(ProfileScreen, skipOffstage: false), findsNothing);

    await tester.tap(find.text('漫画'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('漫画'), findsWidgets);

    await tester.tap(find.text('动漫'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('动漫'), findsWidgets);

    await tester.tap(find.text('我的'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ProfileScreen), findsOneWidget);
    final profileState = tester.state(find.byType(ProfileScreen));

    await tester.tap(find.text('小说'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_textFieldWithHint('搜索小说'), findsOneWidget);

    await tester.tap(find.text('我的'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.state(find.byType(ProfileScreen)), same(profileState));

    await tester.tap(find.text('小说'));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_textFieldWithHint('搜索小说'), findsOneWidget);
  });
}

Finder _textFieldWithHint(String hintText) {
  return find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == hintText,
  );
}
