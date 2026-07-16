import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/wuhandky_video.dart';
import 'interaction_auth_service.dart';
import 'site_domain_service.dart';

class WuhandkyService {
  static const homeCategories = <(String, String)>[
    ('电影', '/dianying/'),
    ('电视剧', '/dianshiju/'),
    ('动漫', '/dongman/'),
    ('综艺', '/zongyi/'),
  ];
  static final Map<String, String> _resolvedCoverCache = <String, String>{};
  static final Map<String, Future<String?>> _resolvingCoverRequests =
      <String, Future<String?>>{};
  static const Set<String> _httpImageHosts = {
    'pic.fzmmx.com',
    'pic.danzhoufdc.com',
    'pic.monidai.com',
    'img.ukuapi.com',
  };
  static final Uri siteUri = Uri.parse('https://www.wuhandky.com/');
  static const SiteDomainConfig _domain = SiteDomainConfig(
    key: 'video_wuhandky',
    primaryOrigin: 'https://www.wuhandky.com',
    fallbackOrigins: ['http://www.wuhandky.com'],
  );
  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
    'Referer': 'https://www.wuhandky.com/',
  };

  final SiteDomainService _domainService = SiteDomainService.instance;

  Future<List<WuhandkyVideoItem>> fetchCategory(String path) async {
    final response = await _get(_resolve(path));
    return parseList(
      utf8.decode(response.bodyBytes),
      baseUri: response.request?.url,
    );
  }

  Future<WuhandkyVideoHome> fetchHome() async {
    final results = await Future.wait([
      fetchCategory('/new.html'),
      for (final category in homeCategories) fetchCategory(category.$2),
    ]);
    return WuhandkyVideoHome(
      featured: results.first.take(6).toList(growable: false),
      sections: [
        for (var index = 0; index < homeCategories.length; index++)
          WuhandkyVideoSection(
            title: homeCategories[index].$1,
            path: homeCategories[index].$2,
            items: results[index + 1].take(12).toList(growable: false),
          ),
      ],
    );
  }

  Future<List<WuhandkyVideoItem>> search(String keyword, {int page = 1}) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final response = await _get(
      _resolve('/search/${Uri.encodeComponent(query)}-$page.html'),
    );
    return parseList(
      utf8.decode(response.bodyBytes),
      baseUri: response.request?.url,
    );
  }

  Future<WuhandkyVideoDetail> fetchDetail(String url) async {
    final response = await _get(_resolve(url));
    return parseDetail(utf8.decode(response.bodyBytes), response.request!.url);
  }

  Future<String> resolveEpisodeUrl(String pageUrl) async {
    final response = await _get(_resolve(pageUrl));
    final html = utf8.decode(response.bodyBytes);
    final match = RegExp(
      r'var\s+zanpiancms_player\s*=\s*(\{.*?\})\s*;',
      dotAll: true,
    ).firstMatch(html);
    if (match == null) throw Exception('未找到播放地址');
    final data = jsonDecode(match.group(1)!) as Map<String, dynamic>;
    var url = data['url']?.toString().trim() ?? '';
    final encrypt = int.tryParse(data['encrypt']?.toString() ?? '') ?? 0;
    if (encrypt == 1) {
      url = Uri.decodeComponent(url);
    } else if (encrypt == 2) {
      url = Uri.decodeComponent(utf8.decode(base64Decode(url)));
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        !{'http', 'https'}.contains(uri.scheme)) {
      throw Exception('播放地址无效');
    }
    return uri.toString();
  }

  Future<String?> resolveCoverUrl({
    required String title,
    required String itemKey,
    String year = '',
    String candidateUrl = '',
  }) async {
    final normalizedKey = _stableItemKey(itemKey);
    if (normalizedKey.isEmpty || title.trim().isEmpty) return null;
    final cached = _resolvedCoverCache[normalizedKey];
    if (cached != null && cached.isNotEmpty) return cached;
    final pending = _resolvingCoverRequests[normalizedKey];
    if (pending != null) return pending;
    final request = _resolveCoverUrl(
      title: title,
      itemKey: normalizedKey,
      year: year,
      candidateUrl: candidateUrl,
    );
    _resolvingCoverRequests[normalizedKey] = request;
    try {
      return await request;
    } finally {
      _resolvingCoverRequests.remove(normalizedKey);
    }
  }

  Future<String?> _resolveCoverUrl({
    required String title,
    required String itemKey,
    required String year,
    required String candidateUrl,
  }) async {
    try {
      final uri =
          Uri.parse(
            '${InteractionAuthService.baseUrl}/video-covers/resolve',
          ).replace(
            queryParameters: {
              'source': 'wuhandky',
              'itemKey': itemKey,
              'title': title.trim(),
              if (year.trim().isNotEmpty) 'year': year.trim(),
              if (candidateUrl.trim().isNotEmpty)
                'candidateUrl': candidateUrl.trim(),
            },
          );
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(utf8.decode(response.bodyBytes));
      if (payload is! Map) return null;
      final coverUrl = payload['coverUrl']?.toString().trim() ?? '';
      final parsed = Uri.tryParse(coverUrl);
      if (parsed == null ||
          !parsed.hasScheme ||
          !{'http', 'https'}.contains(parsed.scheme)) {
        return null;
      }
      _resolvedCoverCache[itemKey] = coverUrl;
      return coverUrl;
    } catch (_) {
      return null;
    }
  }

  String _stableItemKey(String value) {
    final normalized = value.trim();
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return normalized;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    return '${uri.path}$query';
  }

  List<WuhandkyVideoItem> parseList(String html, {Uri? baseUri}) {
    final document = html_parser.parse(html);
    final resolvedBase = baseUri ?? siteUri;
    final seen = <String>{};
    final items = <WuhandkyVideoItem>[];
    for (final anchor in document.querySelectorAll(
      'a.video-pic[href*="/album/"]',
    )) {
      final href = anchor.attributes['href']?.trim() ?? '';
      final title = anchor.attributes['title']?.trim() ?? '';
      if (href.isEmpty || title.isEmpty || !seen.add(href)) continue;
      items.add(
        WuhandkyVideoItem(
          title: title,
          detailUrl: resolvedBase.resolve(href).toString(),
          coverUrl: _normalizeImage(
            anchor.attributes['data-original'] ??
                _backgroundImage(anchor.attributes['style'] ?? ''),
            resolvedBase,
          ),
          note: anchor.querySelector('.note')?.text.trim() ?? '',
          score: anchor.querySelector('.score')?.text.trim() ?? '',
        ),
      );
    }
    return items;
  }

  WuhandkyVideoDetail parseDetail(String html, Uri pageUri) {
    final document = html_parser.parse(html);
    final title = _meta(document, 'meta[property="og:title"]', 'content');
    final info = document.querySelector('ul.info.clearfix');
    final infoText = info?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    final sources = <WuhandkyPlaySource>[];
    for (final tab in document.querySelectorAll(
      '#playTab a[href^="#con_playlist_"]',
    )) {
      final selector = tab.attributes['href'] ?? '';
      if (selector.isEmpty) continue;
      final episodes = document
          .querySelectorAll('$selector li a[href]')
          .map(
            (anchor) => WuhandkyEpisode(
              title: anchor.text.trim(),
              pageUrl: pageUri.resolve(anchor.attributes['href']!).toString(),
            ),
          )
          .where((episode) => episode.title.isNotEmpty)
          .toList()
          .reversed
          .toList();
      if (episodes.isEmpty) continue;
      sources.add(
        WuhandkyPlaySource(
          name: tab.text.trim().isEmpty
              ? '线路${sources.length + 1}'
              : tab.text.trim(),
          episodes: episodes,
        ),
      );
    }
    return WuhandkyVideoDetail(
      title: title.isEmpty
          ? document.querySelector('title')?.text.trim() ?? '影视详情'
          : title,
      detailUrl: pageUri.toString(),
      coverUrl: _normalizeImage(
        _meta(document, 'meta[property="og:image"]', 'content'),
        pageUri,
      ),
      status: _labelValue(infoText, ['清晰：', '状态：'], ['类型：', '主演：']),
      category: _labelValue(infoText, ['类型：'], ['主演：', '导演：']),
      actors: _labelValue(infoText, ['主演：'], ['导演：', '国家/地区：']),
      director: _labelValue(infoText, ['导演：'], ['国家/地区：', '语言/字幕：']),
      area: _labelValue(infoText, ['国家/地区：'], ['语言/字幕：', '上映时间：']),
      year: _yearValue(infoText),
      description:
          info?.querySelector('.details-content-all')?.text.trim() ??
          _meta(document, 'meta[name="description"]', 'content'),
      sources: sources,
    );
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      final response = await _domainService.get(
        _domain,
        uri,
        headers: _headers,
        timeout: const Duration(seconds: 15),
      );
      _ensureSuccess(response);
      return response;
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (message.contains('handshake') ||
          message.contains('certificate') ||
          message.contains('tls')) {
        throw Exception('影视源安全连接异常，请切换网络后重试');
      }
      rethrow;
    }
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode != 200) {
      throw Exception('源站请求失败（HTTP ${response.statusCode}）');
    }
  }

  Uri _resolve(String value) => siteUri.resolve(value.trim());

  String _meta(dom.Document document, String selector, String attribute) =>
      document.querySelector(selector)?.attributes[attribute]?.trim() ?? '';

  String _normalizeImage(String value, Uri baseUri) {
    var normalized = value.trim();
    final embeddedHttp = normalized.indexOf('http', 1);
    if (embeddedHttp > 0) normalized = normalized.substring(embeddedHttp);
    if (normalized.startsWith('//')) normalized = 'https:$normalized';
    if (normalized.isEmpty) return '';
    final resolved = baseUri.resolve(normalized);
    if (resolved.scheme == 'https' && _httpImageHosts.contains(resolved.host)) {
      return resolved.replace(scheme: 'http').toString();
    }
    return resolved.toString();
  }

  String _backgroundImage(String style) =>
      RegExp(
        r'url\(([^)]+)\)',
      ).firstMatch(style)?.group(1)?.replaceAll(RegExp("['\"]"), '').trim() ??
      '';

  String _labelValue(String text, List<String> labels, List<String> endings) {
    var start = -1;
    var labelLength = 0;
    for (final label in labels) {
      final index = text.indexOf(label);
      if (index >= 0 && (start < 0 || index < start)) {
        start = index;
        labelLength = label.length;
      }
    }
    if (start < 0) return '';
    final valueStart = start + labelLength;
    var end = text.length;
    for (final ending in endings) {
      final index = text.indexOf(ending, valueStart);
      if (index >= 0 && index < end) end = index;
    }
    return text.substring(valueStart, end).trim();
  }

  String _yearValue(String text) {
    final value = _labelValue(
      text,
      const ['上映时间：'],
      const ['更新时间：', '影视/评论：', '剧情介绍：'],
    );
    return RegExp(r'(?:19|20)\d{2}').firstMatch(value)?.group(0) ?? value;
  }
}
