import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/wuhandky_video.dart';
import 'package:novel_app/screens/video_screen.dart';
import 'package:novel_app/services/wuhandky_service.dart';

void main() {
  testWidgets('movie shortcut opens the movie subcategory page', (
    tester,
  ) async {
    final service = _ControlledVideoService(
      categories: {
        '/new.html': Future.value([_item('今日推荐')]),
        '/dianying/': Future.value([_item('电影内容')]),
      },
    );

    await tester.pumpWidget(MaterialApp(home: VideoScreen(service: service)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.tap(find.widgetWithText(ActionChip, '电影'));
    await tester.pump();
    await tester.pump();
    expect(find.text('动作电影'), findsOneWidget);
    expect(find.text('科幻电影'), findsOneWidget);
    expect(find.text('电影内容'), findsWidgets);
  });

  testWidgets('an old search response cannot replace a newer search', (
    tester,
  ) async {
    final firstSearch = Completer<List<WuhandkyVideoItem>>();
    final secondSearch = Completer<List<WuhandkyVideoItem>>();
    final service = _ControlledVideoService(
      categories: {
        '/new.html': Future.value([_item('初始结果')]),
      },
      searches: {'第一次': firstSearch.future, '第二次': secondSearch.future},
    );

    await tester.pumpWidget(MaterialApp(home: VideoScreen(service: service)));
    await tester.pump();
    final searchField = find.descendant(
      of: find.byType(SearchBar),
      matching: find.byType(EditableText),
    );

    await tester.enterText(searchField, '第一次');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(searchField, '第二次');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    secondSearch.complete([_item('第二次结果')]);
    await tester.pump();
    expect(find.text('第二次结果'), findsWidgets);

    firstSearch.complete([_item('第一次旧结果')]);
    await tester.pump();
    expect(find.text('第二次结果'), findsWidgets);
    expect(find.text('第一次旧结果'), findsNothing);
  });
}

WuhandkyVideoItem _item(String title) {
  return WuhandkyVideoItem(title: title, detailUrl: '/$title');
}

class _ControlledVideoService extends WuhandkyService {
  _ControlledVideoService({required this.categories, this.searches = const {}});

  final Map<String, Future<List<WuhandkyVideoItem>>> categories;
  final Map<String, Future<List<WuhandkyVideoItem>>> searches;

  @override
  Future<List<WuhandkyVideoItem>> fetchCategory(String path) {
    return categories[path] ?? Future.value(const []);
  }

  @override
  Future<List<WuhandkyVideoItem>> search(String keyword, {int page = 1}) {
    return searches[keyword] ?? Future.value(const []);
  }

  @override
  Future<String?> resolveCoverUrl({
    required String title,
    required String itemKey,
    String year = '',
  }) async {
    return null;
  }
}
