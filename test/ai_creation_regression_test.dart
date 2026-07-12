import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:novel_app/services/ai_creation_service.dart';

void main() {
  test(
    'AI creation service reads published novels and chapters from backend',
    () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/ai-novels')) {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'ai-7',
                  'title': '星海录',
                  'author': '星河',
                  'description': 'AI 原创连载',
                  'sourceId': 'ai-creation',
                  'chapterCount': 2,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path.endsWith('/ai-novels/7/chapters')) {
          return http.Response(
            jsonEncode({
              'items': [
                {'id': '11', 'title': '第一章', 'index': 0},
                {'id': '12', 'title': '第二章', 'index': 1},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });
      final service = AiCreationService(client: client);

      final novels = await service.fetchNovels();
      final chapters = await service.fetchChapters(novels.single);

      expect(novels.single.sourceId, AiCreationService.sourceId);
      expect(novels.single.title, '星海录');
      expect(chapters.map((item) => item.title), ['第一章', '第二章']);
    },
  );

  test(
    'novel home shows AI section last and only when published items exist',
    () {
      final source = File('lib/screens/search_screen.dart').readAsStringSync();
      final normalSections = source.indexOf(
        'for (final section in _homeData.sections) _buildGridSection(section)',
      );
      final aiSection = source.indexOf(
        'if (_aiNovels.isNotEmpty) _buildAiCreationSection(isNight)',
      );

      expect(normalSections, greaterThanOrEqualTo(0));
      expect(aiSection, greaterThan(normalSections));
      expect(source, contains("subtitle: '本站后台审核发布'"));
      expect(source, isNot(contains("tooltip: 'AI 创作区'")));
    },
  );

  test('book source provider routes AI novels through the private backend', () {
    final source = File(
      'lib/providers/book_source_provider.dart',
    ).readAsStringSync();

    expect(source, contains('AiCreationService.isAiNovel(novel)'));
    expect(source, contains('_aiCreationService.fetchNovel(novel)'));
    expect(source, contains('_aiCreationService.fetchChapters(novel)'));
    expect(source, contains('_aiCreationService.fetchChapterContent('));
  });
}
