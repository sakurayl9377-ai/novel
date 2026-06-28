import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga.dart';

class MangaService {
  static final Uri siteUri = Uri.parse('https://cn.bzmgcn.com/');
  static const String _homeHtmlCacheKey = 'manga_home_html_cache_v1';
  static const String _homeHtmlCacheTimeKey = 'manga_home_html_cache_time_v1';
  static const String _chapterImagesCachePrefix =
      'manga_chapter_images_cache_v1_';
  static const Duration _homeCacheTtl = Duration(hours: 4);
  static const Duration _chapterImagesCacheTtl = Duration(days: 7);
  static const Map<String, String> _baseHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.7',
  };
  static const List<MangaCategory> categories = [
    MangaCategory(
      title: '全部',
      url: '/classify?type=all&region=all&state=all&filter=%2a',
      icon: 'all',
    ),
    MangaCategory(title: '最新', url: '/list/new', icon: 'new'),
    MangaCategory(
      title: '国漫',
      url: '/classify?type=all&region=cn&state=all&filter=%2a',
      icon: 'cn',
    ),
    MangaCategory(
      title: '日漫',
      url: '/classify?type=all&region=jp&state=all&filter=%2a',
      icon: 'jp',
    ),
    MangaCategory(
      title: '韩漫',
      url: '/classify?type=all&region=kr&state=all&filter=%2a',
      icon: 'kr',
    ),
  ];

  Future<MangaHomeData> fetchHome({bool forceRefresh = false}) async {
    final cachedHtml = await _readCachedHomeHtml(allowExpired: false);
    if (!forceRefresh && cachedHtml != null) {
      final document = html_parser.parse(cachedHtml);
      return _BaoziHomeParser(siteUri).parse(document);
    }

    try {
      final response = await http
          .get(siteUri, headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final html = _decodeBody(response);
      await _writeCachedHomeHtml(html);
      final document = html_parser.parse(html);
      return _BaoziHomeParser(siteUri).parse(document);
    } catch (_) {
      final fallbackHtml = await _readCachedHomeHtml(allowExpired: true);
      if (fallbackHtml == null) rethrow;
      final document = html_parser.parse(fallbackHtml);
      return _BaoziHomeParser(siteUri).parse(document);
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

  Future<MangaListResult> fetchList(String url, {int page = 1}) async {
    final uri = _listPageUri(url, page);
    final response = await http
        .get(uri, headers: _headers(referer: siteUri.toString()))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final document = html_parser.parse(_decodeBody(response));
    final items = _BaoziHomeParser(siteUri).parseListItems(document);
    return MangaListResult(
      items: items,
      page: page,
      pageCount: page,
      hasMore: items.isNotEmpty,
    );
  }

  Future<List<MangaHomeItem>> search(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];

    final uri = siteUri.replace(path: '/search', queryParameters: {'q': query});
    final response = await http
        .get(uri, headers: _headers(referer: siteUri.toString()))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final document = html_parser.parse(_decodeBody(response));
    return _BaoziHomeParser(siteUri).parseListItems(document);
  }

  Future<Manga> fetchDetail(String id) async {
    final comicId = id.trim();
    if (comicId.isEmpty) throw Exception('invalid manga id');

    final uri = siteUri.resolve('/comic/$comicId');
    final response = await http
        .get(uri, headers: _headers(referer: siteUri.toString()))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final document = html_parser.parse(_decodeBody(response));
    return _BaoziDetailParser(siteUri).parse(document, comicId);
  }

  Future<List<String>> fetchChapterImages(
    MangaChapter chapter, {
    bool forceRefresh = false,
  }) async {
    final uri = _pageUri(chapter.url);
    if (!forceRefresh) {
      final cachedImages = await _readCachedChapterImages(
        uri,
        allowExpired: false,
      );
      if (cachedImages != null) return cachedImages;
    }

    try {
      final response = await http
          .get(uri, headers: _headers(referer: siteUri.toString()))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final document = html_parser.parse(_decodeBody(response));
      final images = _BaoziDetailParser(siteUri).parseDirectImages(document);
      if (images.isNotEmpty) {
        await _writeCachedChapterImages(uri, images);
      }
      return images;
    } catch (_) {
      final fallbackImages = await _readCachedChapterImages(
        uri,
        allowExpired: true,
      );
      if (fallbackImages == null) rethrow;
      return fallbackImages;
    }
  }

  Future<void> warmChapterImages(MangaChapter chapter) async {
    try {
      await fetchChapterImages(chapter);
    } catch (_) {
      // Warming is best-effort; the reader will surface the real error later.
    }
  }

  Future<List<String>?> _readCachedChapterImages(
    Uri uri, {
    required bool allowExpired,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_chapterImagesCacheKey(uri));
    if (raw == null || raw.isEmpty) return null;

    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = data['cachedAt'] as int? ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
      if (!allowExpired && age > _chapterImagesCacheTtl.inMilliseconds) {
        return null;
      }
      final images = (data['images'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where((url) => url.isNotEmpty)
          .toList();
      return images.isEmpty ? null : images;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCachedChapterImages(Uri uri, List<String> images) async {
    if (images.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _chapterImagesCacheKey(uri),
      jsonEncode({
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
        'images': images,
      }),
    );
  }

  String _chapterImagesCacheKey(Uri uri) {
    return _chapterImagesCachePrefix + base64Url.encode(utf8.encode('$uri'));
  }

  Uri _listPageUri(String url, int page) {
    final uri = _pageUri(url);
    if (page <= 1) return uri;
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'page': page.toString()},
    );
  }

  Uri _pageUri(String url) {
    final uri = siteUri.resolve(url.replaceAll('&amp;', '&'));
    if (_isBaoziPageHost(uri.host) && uri.host != siteUri.host) {
      return uri.replace(host: siteUri.host);
    }
    return uri;
  }

  bool _isBaoziPageHost(String host) {
    return host == 'cn.bzmgcn.com' ||
        host == 'cn.cnbzmg.com' ||
        host == 'www.bzmgcn.com' ||
        host == 'www.baozimh.com';
  }

  Map<String, String> _headers({String referer = ''}) {
    return {..._baseHeaders, if (referer.isNotEmpty) 'Referer': referer};
  }

  String _decodeBody(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    }
  }
}

class MangaHomeData {
  const MangaHomeData({
    required this.featured,
    required this.sections,
    required this.categories,
  });

  const MangaHomeData.empty()
    : featured = const [],
      sections = const [],
      categories = MangaService.categories;

  final List<MangaHomeItem> featured;
  final List<MangaHomeSection> sections;
  final List<MangaCategory> categories;

  bool get isEmpty => featured.isEmpty && sections.isEmpty;
}

class MangaCategory {
  const MangaCategory({
    required this.title,
    required this.url,
    required this.icon,
  });

  final String title;
  final String url;
  final String icon;
}

class MangaHomeSection {
  const MangaHomeSection({
    required this.title,
    required this.items,
    this.moreUrl = '',
  });

  final String title;
  final List<MangaHomeItem> items;
  final String moreUrl;

  bool get hasMore => moreUrl.isNotEmpty;
}

class MangaListResult {
  const MangaListResult({
    required this.items,
    required this.page,
    required this.pageCount,
    required this.hasMore,
  });

  final List<MangaHomeItem> items;
  final int page;
  final int pageCount;
  final bool hasMore;
}

class MangaHomeItem {
  const MangaHomeItem({
    required this.title,
    required this.url,
    this.id = '',
    this.imageUrl = '',
    this.status = '',
    this.author = '',
    this.latestChapter = '',
    this.description = '',
  });

  final String id;
  final String title;
  final String url;
  final String imageUrl;
  final String status;
  final String author;
  final String latestChapter;
  final String description;
}

class _BaoziHomeParser {
  const _BaoziHomeParser(this.baseUri);

  final Uri baseUri;

  MangaHomeData parse(dom.Document document) {
    final allItems = parseListItems(document);
    final sections = _parseSections(document);
    return MangaHomeData(
      featured: allItems.take(8).toList(),
      sections: sections.isNotEmpty
          ? sections.take(6).toList()
          : _fallbackSections(allItems),
      categories: MangaService.categories,
    );
  }

  List<MangaHomeItem> parseListItems(dom.Document document) {
    final cards = document.querySelectorAll('.comics-card');
    if (cards.isNotEmpty) {
      return _dedupeItems(
        cards
            .map(_parseCard)
            .where((item) => item.id.isNotEmpty && item.title.isNotEmpty),
      );
    }

    return _dedupeItems(
      document
          .querySelectorAll('a[href*="/comic/"]')
          .map(_parseComicLink)
          .where((item) => item.id.isNotEmpty && item.title.isNotEmpty),
    );
  }

  List<MangaHomeSection> _parseSections(dom.Document document) {
    final sections = <MangaHomeSection>[];
    final seenTitles = <String>{};
    final seenSignatures = <String>{};

    for (final head in document.querySelectorAll('.catalog-head')) {
      final title = _cleanText(
        head.querySelector('.catalog-title')?.text ?? head.text,
      ).replaceAll('更多', '').trim();
      if (!_isUsefulSectionTitle(title) || !seenTitles.add(title)) continue;

      final module = _sectionModule(head);
      if (module == null) continue;
      final items = _itemsIn(module);
      if (items.length < 3) continue;

      final signature = items.take(4).map((item) => item.id).join(',');
      if (!seenSignatures.add(signature)) continue;
      sections.add(
        MangaHomeSection(
          title: title,
          items: items.take(12).toList(),
          moreUrl: _sectionMoreUrl(head, module),
        ),
      );
    }

    return sections;
  }

  List<MangaHomeSection> _fallbackSections(List<MangaHomeItem> items) {
    if (items.isEmpty) return const [];
    return [
      MangaHomeSection(
        title: '热门漫画',
        items: items.take(12).toList(),
        moreUrl: _absolutePageUrl('/classify'),
      ),
      if (items.length > 12)
        MangaHomeSection(
          title: '最新推荐',
          items: items.skip(12).take(12).toList(),
          moreUrl: _absolutePageUrl('/list/new'),
        ),
    ];
  }

  dom.Element? _sectionModule(dom.Element head) {
    dom.Element? module = head.parent;
    for (var depth = 0; depth < 4 && module != null; depth++) {
      if (module.querySelectorAll('.comics-card, a[href*="/comic/"]').length >=
          3) {
        return module;
      }
      module = module.parent;
    }
    return head.parent;
  }

  List<MangaHomeItem> _itemsIn(dom.Element module) {
    final cards = module.querySelectorAll('.comics-card');
    if (cards.isNotEmpty) {
      return _dedupeItems(
        cards
            .map(_parseCard)
            .where((item) => item.id.isNotEmpty && item.title.isNotEmpty),
      );
    }
    return _dedupeItems(
      module
          .querySelectorAll('a[href*="/comic/"]')
          .map(_parseComicLink)
          .where((item) => item.id.isNotEmpty && item.title.isNotEmpty),
    );
  }

  MangaHomeItem _parseCard(dom.Element card) {
    final poster =
        card.querySelector('a.comics-card__poster[href*="/comic/"]') ??
        card.querySelector('a[href*="/comic/"]');
    final info =
        card.querySelector('a.comics-card__info[href*="/comic/"]') ?? poster;
    final href = poster?.attributes['href'] ?? info?.attributes['href'] ?? '';
    final title = _cleanCardTitle(
      info?.querySelector('h3')?.text ??
          info?.querySelector('.comics-card__title')?.text ??
          poster?.attributes['title'] ??
          poster?.attributes['aria-label'] ??
          poster?.querySelector('amp-img,img')?.attributes['alt'] ??
          card.text,
    );
    final image = _imageUrl(poster ?? card);
    final tag = _cleanText(card.querySelector('.tab')?.text ?? '');
    final latest = _cleanText(card.querySelector('.tags')?.text ?? '');

    return MangaHomeItem(
      id: _extractComicId(href),
      title: title,
      url: _absolutePageUrl(href),
      imageUrl: image,
      status: tag,
      latestChapter: latest,
    );
  }

  MangaHomeItem _parseComicLink(dom.Element element) {
    final href = element.attributes['href'] ?? '';
    final title = _cleanCardTitle(
      element.querySelector('h3')?.text ??
          element.attributes['title'] ??
          element.attributes['aria-label'] ??
          element.querySelector('amp-img,img')?.attributes['alt'] ??
          element.text,
    );
    final latest = _cleanText(element.querySelector('.tags,small')?.text ?? '');
    return MangaHomeItem(
      id: _extractComicId(href),
      title: title,
      url: _absolutePageUrl(href),
      imageUrl: _imageUrl(element),
      latestChapter: latest,
    );
  }

  String _sectionMoreUrl(dom.Element head, dom.Element module) {
    for (final link in head.querySelectorAll('a[href]')) {
      final href = link.attributes['href'] ?? '';
      if (_isListUrl(href)) return _absolutePageUrl(href);
    }
    for (final link in module.querySelectorAll('a[href]')) {
      final href = link.attributes['href'] ?? '';
      if (_isListUrl(href)) return _absolutePageUrl(href);
    }
    final title = _cleanText(head.text);
    if (title.contains('最新')) return _absolutePageUrl('/list/new');
    return _absolutePageUrl('/classify');
  }

  bool _isListUrl(String href) {
    return href.contains('/classify') || href.contains('/list/');
  }

  bool _isUsefulSectionTitle(String title) {
    if (title.length < 2 || title.length > 20) return false;
    const blocked = {'首页', '漫画', '搜索', '登录', '注册'};
    return !blocked.contains(title);
  }

  String _imageUrl(dom.Element element) {
    final images = element.querySelectorAll('amp-img,img');
    for (final image in images) {
      final url = _absoluteAssetUrl(
        image.attributes['data-src'] ??
            image.attributes['data-original'] ??
            image.attributes['src'] ??
            '',
      );
      if (url.isNotEmpty && !url.contains('default_cover')) return url;
    }
    return images.isEmpty
        ? ''
        : _absoluteAssetUrl(images.first.attributes['src'] ?? '');
  }

  String _extractComicId(String value) {
    final normalized = value.replaceAll('&amp;', '&');
    final match = RegExp(
      r'/comic/(?!chapter/)([^/?#]+)',
    ).firstMatch(normalized);
    return Uri.decodeComponent(match?.group(1)?.trim() ?? '');
  }

  List<MangaHomeItem> _dedupeItems(Iterable<MangaHomeItem> items) {
    final seen = <String>{};
    final deduped = <MangaHomeItem>[];
    for (final item in items) {
      if (item.title.isEmpty || item.url.isEmpty) continue;
      final key = item.id.isNotEmpty ? 'id:${item.id}' : item.url;
      if (!seen.add(key)) continue;
      deduped.add(item);
    }
    return deduped;
  }

  String _absolutePageUrl(String rawUrl) {
    return _absoluteUrl(rawUrl, normalizePageHost: true);
  }

  String _absoluteAssetUrl(String rawUrl) {
    return _absoluteUrl(rawUrl, normalizePageHost: false);
  }

  String _absoluteUrl(String rawUrl, {required bool normalizePageHost}) {
    final value = rawUrl.replaceAll('&amp;', '&').trim();
    if (value.isEmpty || value.startsWith('data:')) return '';
    final resolved = value.startsWith('//')
        ? 'https:$value'
        : baseUri.resolve(value).toString();
    final uri = Uri.tryParse(resolved);
    if (uri == null) return resolved;
    if (normalizePageHost && _isBaoziPageHost(uri.host)) {
      return uri.replace(host: baseUri.host).toString();
    }
    return uri.toString();
  }

  bool _isBaoziPageHost(String host) {
    return host == 'cn.bzmgcn.com' ||
        host == 'cn.cnbzmg.com' ||
        host == 'www.bzmgcn.com' ||
        host == 'www.baozimh.com';
  }

  String _cleanCardTitle(String text) {
    final value = _cleanText(text).replaceFirst(RegExp(r'^🍱\s*'), '');
    final updateIndex = value.indexOf('更新至');
    if (updateIndex > 0) return value.substring(0, updateIndex).trim();
    return value.split('  ').first.trim();
  }

  String _cleanText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

class _BaoziDetailParser {
  const _BaoziDetailParser(this.baseUri);

  final Uri baseUri;

  Manga parse(dom.Document document, String id) {
    final meta = _parseMeta(document);
    final title = _cleanTitle(
      meta['og:novel:book_name'] ??
          document.querySelector('h1')?.text ??
          meta['og:title'] ??
          document.querySelector('title')?.text ??
          '',
    );
    final cover = _firstNotEmpty([
      _absoluteAssetUrl(meta['og:image'] ?? ''),
      _imageUrl(document.querySelector('amp-img,img')),
    ]);
    final chapters = _dedupeChapters(_parseChapters(document, id));
    final description = _cleanDescription(
      title,
      meta['description'] ?? meta['og:description'] ?? '',
    );

    return Manga(
      id: id,
      title: title.isEmpty ? '漫画详情' : title,
      coverUrl: cover,
      author: meta['og:novel:author'] ?? '',
      status: meta['og:novel:status'] ?? '',
      latestChapter: meta['og:novel:latest_chapter_name'] ?? '',
      description: description,
      chapters: chapters,
    );
  }

  List<String> parseDirectImages(dom.Document document) {
    final urls = <String>[];
    final seen = <String>{};
    for (final image in document.querySelectorAll('amp-img,img')) {
      final url = _imageUrl(image);
      if (!_looksLikePageImage(url) || !seen.add(url)) continue;
      urls.add(url);
    }

    final html = document.outerHtml;
    final pattern = RegExp(
      r'''https?:\/\/[^'"<>\s]+?\.(?:jpg|jpeg|png|webp)(?:\?[^'"<>\s]*)?''',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(html)) {
      final url = _absoluteAssetUrl(match.group(0) ?? '');
      if (!_looksLikePageImage(url) || !seen.add(url)) continue;
      urls.add(url);
    }
    return urls;
  }

  Map<String, String> _parseMeta(dom.Document document) {
    final meta = <String, String>{};
    for (final element in document.querySelectorAll('meta')) {
      final key =
          element.attributes['property'] ?? element.attributes['name'] ?? '';
      final value = element.attributes['content'] ?? '';
      if (key.isNotEmpty && value.isNotEmpty) {
        meta[key] = _cleanText(value.replaceAll('&amp;', '&'));
      }
    }
    return meta;
  }

  Iterable<MangaChapter> _parseChapters(dom.Document document, String id) {
    final links = document.querySelectorAll('a[href*="/user/page_direct"]');
    final normalizedId = _comicBaseId(id);

    return links.map((element) {
      final href = (element.attributes['href'] ?? '').replaceAll('&amp;', '&');
      final uri = baseUri.resolve(href);
      final comicId = uri.queryParameters['comic_id'] ?? '';
      final slot = int.tryParse(uri.queryParameters['chapter_slot'] ?? '') ?? 0;
      final sectionSlot = uri.queryParameters['section_slot'] ?? '0';
      final title = _cleanText(element.text);
      if (!_sameComicId(comicId, id, normalizedId)) {
        return const MangaChapter(title: '', url: '');
      }

      return MangaChapter(
        title: title.isEmpty ? '第${slot + 1}话' : title,
        url: _absolutePageUrl(href),
        id: int.tryParse('$sectionSlot$slot') ?? slot,
      );
    });
  }

  List<MangaChapter> _dedupeChapters(Iterable<MangaChapter> chapters) {
    final bySlot = <String, MangaChapter>{};
    for (final chapter in chapters) {
      if (chapter.title.isEmpty || chapter.url.isEmpty) continue;
      final slotKey =
          Uri.tryParse(chapter.url)?.queryParameters['chapter_slot'] ??
          chapter.url;
      bySlot.putIfAbsent(slotKey, () => chapter);
    }
    final list = bySlot.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  bool _sameComicId(String value, String exactId, String baseId) {
    if (value.isEmpty) return false;
    return value == exactId || value == baseId || _comicBaseId(value) == baseId;
  }

  String _comicBaseId(String value) {
    return value.replaceFirst(RegExp(r'_[a-z0-9]+$'), '');
  }

  String _imageUrl(dom.Element? image) {
    if (image == null) return '';
    final srcset = image.attributes['srcset'] ?? '';
    if (srcset.isNotEmpty) {
      final first = srcset.split(',').first.trim().split(' ').first;
      final url = _absoluteAssetUrl(first);
      if (url.isNotEmpty) return url;
    }
    return _absoluteAssetUrl(
      image.attributes['data-src'] ??
          image.attributes['data-original'] ??
          image.attributes['src'] ??
          '',
    );
  }

  bool _looksLikePageImage(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('default_cover') || lower.contains('/cover/')) {
      return false;
    }
    return lower.contains('/scomic/') &&
        RegExp(r'\.(?:jpg|jpeg|png|webp)(?:\?|$)').hasMatch(lower);
  }

  String _absolutePageUrl(String rawUrl) {
    return _absoluteUrl(rawUrl, normalizePageHost: true);
  }

  String _absoluteAssetUrl(String rawUrl) {
    return _absoluteUrl(rawUrl, normalizePageHost: false);
  }

  String _absoluteUrl(String rawUrl, {required bool normalizePageHost}) {
    final value = rawUrl.replaceAll('&amp;', '&').trim();
    if (value.isEmpty || value.startsWith('data:')) return '';
    final resolved = value.startsWith('//')
        ? 'https:$value'
        : baseUri.resolve(value).toString();
    final uri = Uri.tryParse(resolved);
    if (uri == null) return resolved;
    if (normalizePageHost && _isBaoziPageHost(uri.host)) {
      return uri.replace(host: baseUri.host).toString();
    }
    return uri.toString();
  }

  bool _isBaoziPageHost(String host) {
    return host == 'cn.bzmgcn.com' ||
        host == 'cn.cnbzmg.com' ||
        host == 'www.bzmgcn.com' ||
        host == 'www.baozimh.com';
  }

  String _cleanTitle(String text) {
    return _cleanText(text)
        .replaceFirst(RegExp(r'^🍱\s*'), '')
        .replaceFirst(RegExp(r'漫画\s*-\s*包子漫画$'), '')
        .replaceFirst(RegExp(r'\s*-\s*包子漫画$'), '')
        .trim();
  }

  String _cleanDescription(String title, String text) {
    final value = _cleanText(text);
    if (title.isEmpty) return value;
    return value
        .replaceFirst(RegExp('^《${RegExp.escape(title)}》[^，,]*[，,]?'), '')
        .trim();
  }

  String _cleanText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _firstNotEmpty(List<String> values) {
    for (final value in values) {
      if (value.isNotEmpty) return value;
    }
    return '';
  }
}
