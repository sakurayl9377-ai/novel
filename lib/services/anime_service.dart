import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/anime.dart';

class AnimeService {
  static final Uri siteUri = Uri.parse('https://www.yinhuadm.xyz/');
  static final Uri _apiUri = siteUri.resolve('/api.php/provide/vod/');
  static const String _homeHtmlCacheKey = 'anime_home_html_cache_v1';
  static const String _homeHtmlCacheTimeKey = 'anime_home_html_cache_time_v1';
  static const Duration _homeCacheTtl = Duration(hours: 4);
  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8',
  };

  Future<AnimeHomeData> fetchHome({bool forceRefresh = false}) async {
    final cachedHtml = await _readCachedHomeHtml(allowExpired: false);
    if (!forceRefresh && cachedHtml != null) {
      final document = html_parser.parse(cachedHtml);
      return _AnimeHomeParser(siteUri).parse(document);
    }

    try {
      final response = await http
          .get(siteUri, headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final html = utf8.decode(response.bodyBytes);
      await _writeCachedHomeHtml(html);
      final document = html_parser.parse(html);
      return _AnimeHomeParser(siteUri).parse(document);
    } catch (_) {
      final fallbackHtml = await _readCachedHomeHtml(allowExpired: true);
      if (fallbackHtml == null) rethrow;
      final document = html_parser.parse(fallbackHtml);
      return _AnimeHomeParser(siteUri).parse(document);
    }
  }

  Future<String?> _readCachedHomeHtml({required bool allowExpired}) async {
    final prefs = await SharedPreferences.getInstance();
    final html = prefs.getString(_homeHtmlCacheKey);
    if (html == null || html.isEmpty) return null;
    if (allowExpired) return html;

    final cachedAt = prefs.getInt(_homeHtmlCacheTimeKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
    return age <= _homeCacheTtl.inMilliseconds ? html : null;
  }

  Future<void> _writeCachedHomeHtml(String html) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_homeHtmlCacheKey, html);
    await prefs.setInt(
      _homeHtmlCacheTimeKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<AnimeListResult> fetchList(String url, {int page = 1}) async {
    final typeId = _extractTypeId(url);
    if (typeId != null) {
      return _fetchCategory(typeId, page: page);
    }
    return _fetchHtmlList(url, page: page);
  }

  Future<List<Anime>> search(String keyword, {int page = 1}) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];

    final uri = _apiUri.replace(
      queryParameters: {'ac': 'detail', 'wd': query, 'pg': page.toString()},
    );
    final data = await _fetchApi(uri);
    final list = data['list'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((item) => Anime.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<Anime> fetchDetail(int id) async {
    final uri = _apiUri.replace(
      queryParameters: {'ac': 'detail', 'ids': id.toString()},
    );
    final data = await _fetchApi(uri);
    final list = data['list'];
    if (list is! List || list.isEmpty || list.first is! Map) {
      throw Exception('detail not found');
    }
    return Anime.fromJson(Map<String, dynamic>.from(list.first as Map));
  }

  Future<AnimeListResult> _fetchCategory(
    int typeId, {
    required int page,
  }) async {
    final uri = _apiUri.replace(
      queryParameters: {
        'ac': 'detail',
        't': typeId.toString(),
        'pg': page.toString(),
      },
    );
    final data = await _fetchApi(uri);
    final list = data['list'];
    final items = list is List
        ? list
              .whereType<Map>()
              .map((item) => Anime.fromJson(Map<String, dynamic>.from(item)))
              .map(_homeItemFromAnime)
              .toList()
        : <AnimeHomeItem>[];
    final pageCount = _asInt(data['pagecount']);
    final currentPage = _asInt(data['page']);
    return AnimeListResult(
      items: items,
      page: currentPage > 0 ? currentPage : page,
      pageCount: pageCount > 0 ? pageCount : page,
      hasMore: pageCount == 0 || page < pageCount,
    );
  }

  Future<AnimeListResult> _fetchHtmlList(
    String url, {
    required int page,
  }) async {
    final uri = _listPageUri(url, page);
    final response = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final document = html_parser.parse(utf8.decode(response.bodyBytes));
    final items = _AnimeHomeParser(siteUri).parseListItems(document);
    return AnimeListResult(
      items: items,
      page: page,
      pageCount: page,
      hasMore: items.isNotEmpty,
    );
  }

  Future<Map<String, dynamic>> _fetchApi(Uri uri) async {
    final response = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw Exception('invalid response');
    }
    return decoded;
  }

  AnimeHomeItem _homeItemFromAnime(Anime anime) {
    return AnimeHomeItem(
      id: anime.id,
      title: anime.title,
      url: siteUri.resolve('/v/${anime.id}.html').toString(),
      imageUrl: anime.coverUrl,
      status: anime.status,
      description: anime.description,
    );
  }

  int? _extractTypeId(String url) {
    final uri = siteUri.resolve(url);
    final match = RegExp(r'^/s/(\d+)\.html$').firstMatch(uri.path);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  Uri _listPageUri(String url, int page) {
    final uri = siteUri.resolve(url);
    if (page <= 1) return uri;

    final labelMatch = RegExp(r'^/label/([^/]+)\.html$').firstMatch(uri.path);
    if (labelMatch != null) {
      return uri.replace(path: '/label/${labelMatch.group(1)}/page/$page.html');
    }

    return uri.replace(
      queryParameters: {...uri.queryParameters, 'pg': page.toString()},
    );
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class AnimeHomeData {
  const AnimeHomeData({
    required this.hotSearches,
    required this.featured,
    required this.sections,
    required this.rankings,
    this.rankingsMoreUrl = '',
  });

  const AnimeHomeData.empty()
    : hotSearches = const [],
      featured = const [],
      sections = const [],
      rankings = const [],
      rankingsMoreUrl = '';

  final List<AnimeHomeItem> hotSearches;
  final List<AnimeHomeItem> featured;
  final List<AnimeHomeSection> sections;
  final List<AnimeRankingGroup> rankings;
  final String rankingsMoreUrl;

  bool get isEmpty =>
      hotSearches.isEmpty &&
      featured.isEmpty &&
      sections.isEmpty &&
      rankings.isEmpty;
}

class AnimeHomeSection {
  const AnimeHomeSection({
    required this.title,
    required this.items,
    this.moreUrl = '',
  });

  final String title;
  final List<AnimeHomeItem> items;
  final String moreUrl;

  bool get hasMore => moreUrl.isNotEmpty;
}

class AnimeListResult {
  const AnimeListResult({
    required this.items,
    required this.page,
    required this.pageCount,
    required this.hasMore,
  });

  final List<AnimeHomeItem> items;
  final int page;
  final int pageCount;
  final bool hasMore;
}

class AnimeRankingGroup {
  const AnimeRankingGroup({required this.title, required this.items});

  final String title;
  final List<AnimeHomeItem> items;
}

class AnimeHomeItem {
  const AnimeHomeItem({
    required this.title,
    required this.url,
    this.id = 0,
    this.imageUrl = '',
    this.status = '',
    this.description = '',
  });

  final int id;
  final String title;
  final String url;
  final String imageUrl;
  final String status;
  final String description;
}

class _AnimeHomeParser {
  const _AnimeHomeParser(this.baseUri);

  final Uri baseUri;

  AnimeHomeData parse(dom.Document document) {
    final hotSearches = document
        .querySelectorAll('.search-tag a')
        .map(_parseLinkItem)
        .where((item) => item.title.isNotEmpty && item.url.isNotEmpty)
        .take(8)
        .toList();

    final featured = document
        .querySelectorAll('.swiper-small .swiper-slide')
        .map(_parseSwiperItem)
        .where((item) => item.title.isNotEmpty)
        .take(8)
        .toList();

    final sections = <AnimeHomeSection>[];
    final seenTitles = <String>{};
    for (final module in document.querySelectorAll('.module')) {
      final title = _cleanText(
        module.querySelector('.module-title')?.text ?? '',
      );
      if (title.isEmpty || title.contains('热榜') || title.contains('友情链接')) {
        continue;
      }
      final items = module
          .querySelectorAll('a.module-poster-item')
          .map(_parsePosterItem)
          .where((item) => item.title.isNotEmpty)
          .toList();
      if (items.isEmpty || seenTitles.contains(title)) continue;
      seenTitles.add(title);
      sections.add(
        AnimeHomeSection(
          title: title,
          items: items.take(12).toList(),
          moreUrl: _moduleMoreUrl(module, title),
        ),
      );
      if (sections.length >= 4) break;
    }

    final rankings = document
        .querySelectorAll('.module-paper-item')
        .map(_parseRankingGroup)
        .where((group) => group.items.isNotEmpty)
        .take(3)
        .toList();

    return AnimeHomeData(
      hotSearches: hotSearches,
      featured: featured,
      sections: sections,
      rankings: rankings,
      rankingsMoreUrl: _absoluteUrl(
        document
                .querySelector('.module-shadow .module-heading-more')
                ?.attributes['href'] ??
            '/label/hot.html',
      ),
    );
  }

  List<AnimeHomeItem> parseListItems(dom.Document document) {
    final items = <AnimeHomeItem>[
      ...document
          .querySelectorAll('a.module-poster-item')
          .map(_parsePosterItem),
      ...document.querySelectorAll('.module-card-item').map(_parseCardItem),
      ...document.querySelectorAll('a[href]').map(_parseVideoLinkItem),
    ];
    return _dedupeItems(items);
  }

  AnimeHomeItem _parseLinkItem(dom.Element element) {
    return AnimeHomeItem(
      id: _extractId(element.attributes['href'] ?? ''),
      title: _cleanText(element.text),
      url: _absoluteUrl(element.attributes['href'] ?? ''),
    );
  }

  AnimeHomeItem _parseSwiperItem(dom.Element element) {
    final link = element.querySelector('.pic a, .title a, a');
    final href = link?.attributes['href'] ?? '';
    final image = element.querySelector('img');
    final status = _cleanText(element.querySelector('.ins p')?.text ?? '');
    final paragraphs = element.querySelectorAll('.ins p');
    final description = paragraphs.length > 1
        ? _cleanText(paragraphs[1].text)
        : '';

    return AnimeHomeItem(
      id: _extractId(href),
      title: _cleanText(
        element.querySelector('.title a')?.text ??
            image?.attributes['alt'] ??
            '',
      ),
      url: _absoluteUrl(href),
      imageUrl: _absoluteUrl(
        image?.attributes['data-original'] ?? image?.attributes['src'] ?? '',
      ),
      status: status,
      description: description,
    );
  }

  AnimeHomeItem _parsePosterItem(dom.Element element) {
    final href = element.attributes['href'] ?? '';
    final image = element.querySelector('img');
    return AnimeHomeItem(
      id: _extractId(href),
      title: _cleanText(
        element.attributes['title'] ??
            element.querySelector('.module-poster-item-title')?.text ??
            image?.attributes['alt'] ??
            '',
      ),
      url: _absoluteUrl(href),
      imageUrl: _absoluteUrl(
        image?.attributes['data-original'] ?? image?.attributes['src'] ?? '',
      ),
      status: _cleanText(
        element.querySelector('.module-item-note')?.text ?? '',
      ),
    );
  }

  AnimeHomeItem _parseCardItem(dom.Element element) {
    final link =
        element.querySelector('a.module-card-item-poster[href]') ??
        element.querySelector('.module-card-item-title a[href]') ??
        element.querySelector('a[href]');
    final href = link?.attributes['href'] ?? '';
    final image = element.querySelector('img');
    return AnimeHomeItem(
      id: _extractId(href),
      title: _cleanText(
        element.querySelector('.module-card-item-title a')?.text ??
            element.querySelector('strong')?.text ??
            image?.attributes['alt'] ??
            link?.attributes['title'] ??
            '',
      ),
      url: _absoluteUrl(href),
      imageUrl: _absoluteUrl(
        image?.attributes['data-original'] ?? image?.attributes['src'] ?? '',
      ),
      status: _cleanText(
        element.querySelector('.module-item-note')?.text ?? '',
      ),
    );
  }

  AnimeHomeItem _parseVideoLinkItem(dom.Element element) {
    final href = element.attributes['href'] ?? '';
    if (_extractId(href) <= 0) {
      return AnimeHomeItem(title: '', url: _absoluteUrl(href));
    }
    final image = element.querySelector('img');
    final title = _cleanText(
      element.attributes['title'] ?? image?.attributes['alt'] ?? element.text,
    );
    return AnimeHomeItem(
      id: _extractId(href),
      title: _isMeaningfulTitle(title) ? title : '',
      url: _absoluteUrl(href),
      imageUrl: _absoluteUrl(
        image?.attributes['data-original'] ?? image?.attributes['src'] ?? '',
      ),
    );
  }

  AnimeRankingGroup _parseRankingGroup(dom.Element element) {
    final title = _cleanText(
      element.querySelector('.module-paper-item-title')?.text ?? '',
    );
    final items = element
        .querySelectorAll('.module-paper-item-main a')
        .map((link) {
          final href = link.attributes['href'] ?? '';
          final title = _cleanText(
            link.querySelector('.module-paper-item-infotitle')?.text ??
                link.text,
          );
          final status = _cleanText(
            link.querySelector('.module-paper-item-info p')?.text ?? '',
          );
          return AnimeHomeItem(
            id: _extractId(href),
            title: title,
            status: status,
            url: _absoluteUrl(href),
          );
        })
        .where((item) => item.title.isNotEmpty)
        .toList();

    return AnimeRankingGroup(title: title, items: items);
  }

  int _extractId(String value) {
    return int.tryParse(
          RegExp(r'/v/(\d+)\.html').firstMatch(value)?.group(1) ?? '',
        ) ??
        0;
  }

  String _moduleMoreUrl(dom.Element module, String title) {
    final href =
        module.querySelector('.module-heading-more')?.attributes['href'] ??
        module.querySelector('.module-title a[href]')?.attributes['href'] ??
        '';
    if (href.trim().isNotEmpty) return _absoluteUrl(href);
    if (title.contains('追番周表')) return _absoluteUrl('/label/week.html');
    return '';
  }

  List<AnimeHomeItem> _dedupeItems(Iterable<AnimeHomeItem> items) {
    final seen = <String>{};
    final deduped = <AnimeHomeItem>[];
    for (final item in items) {
      if (item.title.isEmpty || item.url.isEmpty) continue;
      final key = item.id > 0 ? 'id:${item.id}' : item.url;
      if (!seen.add(key)) continue;
      deduped.add(item);
    }
    return deduped;
  }

  bool _isMeaningfulTitle(String value) {
    if (value.isEmpty || value == '详情') return false;
    if (RegExp(r'^\d+$').hasMatch(value)) return false;
    if (value.startsWith('更新至') || value.endsWith('集')) return false;
    if (value == '已完结' || value == '完结') return false;
    return true;
  }

  String _absoluteUrl(String rawUrl) {
    final value = rawUrl.trim();
    if (value.isEmpty || value.startsWith('data:')) return '';
    if (value.startsWith('//')) return 'https:$value';
    return baseUri.resolve(value).toString();
  }

  String _cleanText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').replaceAll('hotop', '').trim();
  }
}
