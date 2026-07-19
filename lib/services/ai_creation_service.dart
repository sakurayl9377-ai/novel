import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chapter.dart';
import '../models/novel.dart';
import 'interaction_auth_service.dart';

class AiCreationService {
  AiCreationService({http.Client? client}) : _client = client ?? http.Client();

  static const String sourceId = 'ai-creation';
  static const String sourceName = 'AI 创作区';

  final http.Client _client;

  static bool isAiNovel(Novel novel) => novel.sourceId == sourceId;

  Future<List<Novel>> fetchNovels({String query = ''}) async {
    final uri = Uri.parse('${InteractionAuthService.baseUrl}/ai-novels')
        .replace(
          queryParameters: query.trim().isEmpty ? null : {'q': query.trim()},
        );
    final json = await _get(uri);
    final items = json['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((item) => _novelFromJson(item.cast<String, dynamic>()))
        .toList();
  }

  Future<Novel> fetchNovel(Novel novel) async {
    final id = _numericId(novel.id);
    final json = await _get(
      Uri.parse('${InteractionAuthService.baseUrl}/ai-novels/$id'),
    );
    final item = json['item'];
    if (item is! Map) throw const FormatException('AI 小说详情格式错误');
    return _novelFromJson(item.cast<String, dynamic>());
  }

  Future<List<Chapter>> fetchChapters(Novel novel) async {
    final id = _numericId(novel.id);
    final json = await _get(
      Uri.parse('${InteractionAuthService.baseUrl}/ai-novels/$id/chapters'),
    );
    final items = json['items'];
    if (items is! List) return const [];
    return items.whereType<Map>().map((raw) {
      final item = raw.cast<String, dynamic>();
      return Chapter(
        id: item['id']?.toString() ?? '',
        novelId: novel.id,
        title: item['title']?.toString() ?? '',
        index: (item['index'] as num?)?.toInt() ?? 0,
        url:
            '${InteractionAuthService.baseUrl}/ai-novels/$id/chapters/${item['id']}',
      );
    }).toList();
  }

  Future<String> fetchChapterContent(Novel novel, Chapter chapter) async {
    final id = _numericId(novel.id);
    final json = await _get(
      Uri.parse(
        '${InteractionAuthService.baseUrl}/ai-novels/$id/chapters/${chapter.id}',
      ),
    );
    final item = json['item'];
    if (item is! Map) throw const FormatException('AI 小说章节格式错误');
    return item['content']?.toString() ?? '';
  }

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('AI 创作区请求失败（${response.statusCode}）');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const FormatException('AI 创作区响应格式错误');
    return decoded.cast<String, dynamic>();
  }

  Novel _novelFromJson(Map<String, dynamic> json) {
    final chapterCount = (json['chapterCount'] as num?)?.toInt() ?? 0;
    return Novel(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      author: json['author']?.toString() ?? 'AI 创作者',
      coverUrl: _resolveBackendUrl(json['coverUrl']),
      description: json['description']?.toString() ?? '',
      sourceId: sourceId,
      sourceName: sourceName,
      chapterUrl:
          '${InteractionAuthService.baseUrl}/ai-novels/${_numericId(json['id']?.toString() ?? '')}/chapters',
      status: json['status']?.toString() ?? '连载中',
      chapterCount: chapterCount,
      totalChapters: chapterCount,
    );
  }

  String _resolveBackendUrl(Object? rawValue) {
    final value = rawValue?.toString().trim() ?? '';
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri?.hasScheme ?? false) return value;

    final baseUri = Uri.parse(InteractionAuthService.baseUrl);
    if (value.startsWith('//')) return baseUri.resolve(value).toString();
    if (value.startsWith('/')) {
      return baseUri
          .replace(path: value, query: null, fragment: null)
          .toString();
    }
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path
        : '${baseUri.path}/';
    return baseUri
        .replace(path: basePath, query: null, fragment: null)
        .resolve(value)
        .toString();
  }

  String _numericId(String value) => value.replaceFirst(RegExp(r'^ai-'), '');
}
