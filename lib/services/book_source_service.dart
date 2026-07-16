import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../models/chapter.dart';
import '../models/content_progress.dart';
import '../models/novel.dart';
import 'interaction_auth_service.dart';
import 'novel_cover_service.dart';
import 'site_domain_service.dart';
import 'storage_service.dart';
import 'swr_cache.dart';

class BookSourceService {
  static final http.Client _sharedHttpClient = http.Client();
  static const String _homeCachePrefix = 'novel_home_cache_v2_';
  static const Duration _homeCacheTtl = Duration(hours: 4);
  static final SwrCache<String, NovelHomeData> _homeMemoryCache = SwrCache(
    freshTtl: const Duration(minutes: 5),
    staleTtl: const Duration(hours: 4),
    maxEntries: 8,
  );
  static final SwrCache<String, List<Novel>> _categoryCache = SwrCache(
    freshTtl: const Duration(minutes: 10),
    staleTtl: const Duration(hours: 2),
    maxEntries: 80,
  );
  static final SwrCache<String, _BqgBookApiMeta> _bookApiMetaCache = SwrCache(
    freshTtl: const Duration(minutes: 30),
    staleTtl: const Duration(hours: 12),
    maxEntries: 120,
  );
  static final SwrCache<String, List<Chapter>> _chapterListCache = SwrCache(
    freshTtl: const Duration(minutes: 15),
    staleTtl: const Duration(hours: 12),
    maxEntries: 48,
  );
  static const String _bqgPrimaryOrigin = 'https://www.bqg475.cc';
  static const String _bqgApexOrigin = 'https://bqg475.cc';
  static const String _bqgBackupOrigin = 'https://www.bqg7777.xyz';
  static const String _bqgApiOrigin = 'https://apibi.cc';
  static const String _bqgWwwApiOrigin = 'https://www.apibi.cc';
  static const String _bqgWebOrigin = 'https://www.bqg691.cc';
  static const String _bqgLegacyOrigin = 'https://www.bqg995.xyz';
  static const String _wenku8PrimaryOrigin = 'https://www.wenku8.cc';
  static const String _wenku8BackupOrigin = 'https://www.wenku8.net';
  static const List<String> _bqgChapterApiOrigins = [
    _bqgPrimaryOrigin,
    _bqgApexOrigin,
    _bqgBackupOrigin,
    _bqgApiOrigin,
    _bqgWwwApiOrigin,
    _bqgWebOrigin,
    _bqgLegacyOrigin,
  ];
  static const SiteDomainConfig _bqgDomain = SiteDomainConfig(
    key: 'novel_bqg',
    primaryOrigin: _bqgPrimaryOrigin,
    fallbackOrigins: [
      _bqgApexOrigin,
      _bqgBackupOrigin,
      _bqgApiOrigin,
      _bqgWwwApiOrigin,
      _bqgWebOrigin,
      _bqgLegacyOrigin,
    ],
  );
  static final BookSource bqg995Source = BookSource(
    id: 'builtin_bqg995',
    name: '笔趣阁',
    baseUrl: _bqgPrimaryOrigin,
    searchUrl: '$_bqgPrimaryOrigin/api/search?q={keyword}',
    enabled: true,
    weight: 100,
  );
  static final BookSource wenku8Source = BookSource(
    id: 'builtin_wenku8',
    name: '轻小说文库',
    baseUrl: _wenku8PrimaryOrigin,
    searchUrl: '$_wenku8PrimaryOrigin/wap/article/search.php',
    chapterListUrl:
        '$_wenku8PrimaryOrigin/wap/article/readbook.php?aid={bookId}',
    contentUrl:
        '$_wenku8PrimaryOrigin/wap/article/readchapter.php?aid={bookId}&cid={chapterId}',
    enabled: true,
    weight: 90,
  );

  BookSourceService({this.httpClient});

  final http.Client? httpClient;
  final StorageService _storage = StorageService();
  final SiteDomainService _domainService = SiteDomainService.instance;

  static Map<String, int> get cacheTelemetryMetadata => {
    ..._homeMemoryCache.stats.toTelemetryMetadata(prefix: 'novelHome'),
    ..._categoryCache.stats.toTelemetryMetadata(prefix: 'novelCategory'),
    ..._bookApiMetaCache.stats.toTelemetryMetadata(prefix: 'novelDetail'),
    ..._chapterListCache.stats.toTelemetryMetadata(prefix: 'novelCatalog'),
  };

  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) {
    return (httpClient ?? _sharedHttpClient).get(uri, headers: headers);
  }

  Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return (httpClient ?? _sharedHttpClient).post(
      uri,
      headers: headers,
      body: body,
    );
  }

  bool isBqg995Source(BookSource source) {
    final host = Uri.tryParse(source.baseUrl)?.host.toLowerCase() ?? '';
    return _isKnownBqgHost(host);
  }

  bool isWenku8Source(BookSource source) {
    if (source.id == wenku8Source.id) return true;
    final host = Uri.tryParse(source.baseUrl)?.host.toLowerCase() ?? '';
    return _isKnownWenku8Host(host);
  }

  Future<List<BookSource>> ensureBuiltinSources() async {
    final sources = await getAllSources();
    BookSource? savedBqg;
    BookSource? savedWenku8;
    for (final source in sources) {
      if (source.id == bqg995Source.id) {
        savedBqg ??= source;
      } else if (source.id == wenku8Source.id) {
        savedWenku8 ??= source;
      }
    }

    final currentOrigin = await _domainService.currentOrigin(_bqgDomain);
    final normalized = (savedBqg ?? bqg995Source).copyWith(
      name: bqg995Source.name,
      baseUrl: currentOrigin,
      searchUrl: '$currentOrigin/api/search?q={keyword}',
      enabled: savedBqg?.enabled ?? bqg995Source.enabled,
      weight: bqg995Source.weight,
    );
    final normalizedWenku8 = (savedWenku8 ?? wenku8Source).copyWith(
      name: wenku8Source.name,
      baseUrl: _wenku8PrimaryOrigin,
      searchUrl: wenku8Source.searchUrl,
      chapterListUrl: wenku8Source.chapterListUrl,
      contentUrl: wenku8Source.contentUrl,
      enabled: savedWenku8?.enabled ?? wenku8Source.enabled,
      weight: wenku8Source.weight,
    );
    await updateSource(normalized);
    await updateSource(normalizedWenku8);

    final merged = <BookSource>[
      for (final source in sources)
        if (source.id != normalized.id && source.id != normalizedWenku8.id)
          source,
      normalized,
      normalizedWenku8,
    ];
    merged.sort((left, right) => right.weight.compareTo(left.weight));
    return merged;
  }

  @Deprecated('Use ensureBuiltinSources instead.')
  Future<List<BookSource>> ensureOnlyBqg995Source() => ensureBuiltinSources();

  Future<NovelHomeData> fetchHome({
    bool forceRefresh = false,
    String? sourceId,
  }) async {
    var sources = await _searchableSources(await getAllSources());
    if (sourceId != null && sourceId.isNotEmpty) {
      sources = sources.where((source) => source.id == sourceId).toList();
    }

    for (final source in sources) {
      final cacheKey = _homeCacheKey(source);
      try {
        if (!forceRefresh && _homeMemoryCache.containsUsable(cacheKey)) {
          return _homeMemoryCache.get(
            cacheKey,
            loader: () => _fetchHomeFromSource(source),
          );
        }

        if (!forceRefresh) {
          final cached = await _readCachedHome(source, allowExpired: false);
          if (cached != null && !cached.isEmpty) {
            _homeMemoryCache.put(cacheKey, cached);
            unawaited(
              _homeMemoryCache.refresh(
                cacheKey,
                loader: () => _fetchHomeFromSource(source),
              ),
            );
            return cached;
          }
        }

        return forceRefresh
            ? await _homeMemoryCache.refresh(
                cacheKey,
                loader: () => _fetchHomeFromSource(source),
              )
            : await _homeMemoryCache.get(
                cacheKey,
                loader: () => _fetchHomeFromSource(source),
              );
      } catch (_) {
        final cached = await _readCachedHome(source, allowExpired: true);
        if (cached != null && !cached.isEmpty) {
          _homeMemoryCache.put(cacheKey, cached);
          return cached;
        }
        continue;
      }
    }

    return const NovelHomeData.empty();
  }

  Future<NovelHomeData> _fetchHomeFromSource(BookSource source) async {
    final data = isWenku8Source(source)
        ? await _fetchWenku8Home(source)
        : _isBqgApiSource(source)
        ? await _fetchBqgApiHome(source)
        : await _fetchHtmlHome(source);
    if (data.isEmpty) throw StateError('novel home is empty');
    await _writeCachedHome(source, data);
    return data;
  }

  Future<List<Novel>> fetchCategory(NovelCategory category) async {
    final cacheKey = category.apiSort.isNotEmpty
        ? 'api:${category.apiSort}'
        : 'url:${category.url}';
    return _categoryCache.get(
      cacheKey,
      loader: () => _fetchCategoryUncached(category),
    );
  }

  Future<List<Novel>> _fetchCategoryUncached(NovelCategory category) async {
    if (category.sourceId == wenku8Source.id ||
        category.apiSort.startsWith('wenku8-home:')) {
      return _fetchWenku8HomeCategory(category);
    }
    if (category.apiSort.isNotEmpty) {
      return _fetchBqgApiCategory(category);
    }

    if (category.url.isEmpty) return const [];
    final source = BookSource(
      id: category.sourceId,
      name: category.sourceName,
      baseUrl: category.sourceBaseUrl,
    );
    final response = await _get(
      Uri.parse(category.url),
      headers: _headers(category.sourceBaseUrl),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return const [];
    final document = html_parser.parse(_decodeBody(response));
    return _parseHtmlNovelItems(document, source).take(60).toList();
  }

  Future<Novel> fetchBookDetail(Novel novel) async {
    if (_isWenku8Novel(novel)) {
      return _fetchWenku8BookDetail(novel);
    }
    if (!_isBqgNovel(novel)) return novel;

    final bookId = _extractBookId(novel.chapterUrl) ?? _extractBqgId(novel.id);
    if (bookId == null) return novel;

    final meta = await _getBookApiMeta(novel, bookId);
    return meta?.novel ?? novel;
  }

  Future<NovelHomeData> _fetchWenku8Home(BookSource source) async {
    for (final origin in _wenku8OriginCandidates(source.baseUrl)) {
      try {
        final response = await _get(
          Uri.parse('$origin/wap/'),
          headers: _headers('$origin/wap/'),
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) continue;

        final responseOrigin = _originOfResponse(response, fallback: origin);
        final parsed = _parseWenku8Home(
          _decodeBody(response),
          source.copyWith(baseUrl: responseOrigin),
        );
        if (!parsed.isEmpty) return parsed;
      } catch (_) {
        continue;
      }
    }
    return const NovelHomeData.empty();
  }

  NovelHomeData _parseWenku8Home(String wml, BookSource source) {
    final grouped = <String, List<Novel>>{};
    final categoryUrls = <String, String>{};
    final categorySorts = <String, String>{};
    var currentSection = '';

    for (final rawLine in wml.split(
      RegExp(r'<br\s*/?>', caseSensitive: false),
    )) {
      final lineText = _cleanHtmlText(rawLine);
      final sectionMatch = RegExp(r'【([^】]+)】').firstMatch(lineText);
      if (sectionMatch != null) {
        currentSection = sectionMatch.group(1)!.trim();
        grouped.putIfAbsent(currentSection, () => <Novel>[]);
      }
      if (currentSection.isEmpty) continue;

      final fragment = html_parser.parseFragment(rawLine);
      for (final anchor in fragment.querySelectorAll('a')) {
        final href = anchor.attributes['href'] ?? '';
        final categorySort = Uri.tryParse(
          _normalizeUrl(source.baseUrl, href),
        )?.queryParameters['sort'];
        if (currentSection.isNotEmpty &&
            href.contains('toplist.php') &&
            categorySort != null &&
            categorySort.isNotEmpty) {
          categoryUrls[currentSection] = _normalizeUrl(source.baseUrl, href);
          categorySorts[currentSection] = categorySort;
          continue;
        }
        final bookId = _extractWenku8BookId(href);
        final title = _cleanHtmlText(anchor.text);
        if (bookId == null || !_isNovelTitle(title)) continue;
        final novels = grouped[currentSection]!;
        if (novels.any(
          (item) => _extractWenku8BookId(item.chapterUrl) == bookId,
        )) {
          continue;
        }
        novels.add(_wenku8Novel(source, bookId: bookId, title: title));
      }
    }

    final sections = <NovelHomeSection>[];
    for (final entry in grouped.entries) {
      if (entry.value.isEmpty) continue;
      final categorySort = categorySorts[entry.key] ?? '';
      sections.add(
        NovelHomeSection(
          title: entry.key,
          items: entry.value,
          category: NovelCategory(
            title: entry.key,
            url: categoryUrls[entry.key] ?? '${source.baseUrl}/wap/',
            icon: 'menu_book',
            sourceId: source.id,
            sourceName: source.name,
            sourceBaseUrl: source.baseUrl,
            apiSort: categorySort.isEmpty
                ? 'wenku8-home:${entry.key}'
                : 'wenku8-toplist:$categorySort',
          ),
        ),
      );
    }
    if (sections.isEmpty) return const NovelHomeData.empty();

    return NovelHomeData(
      sourceName: source.name,
      featured: sections.first.items,
      sections: sections.skip(1).toList(),
      categories: const [],
    );
  }

  Future<List<Novel>> _fetchWenku8HomeCategory(NovelCategory category) async {
    if (category.apiSort.startsWith('wenku8-toplist:')) {
      final sort = category.apiSort.substring('wenku8-toplist:'.length);
      final backendItems = await _fetchWenku8BackendToplist(category, sort);
      if (backendItems.isNotEmpty) return backendItems;
    }

    final targetTitle = category.apiSort.startsWith('wenku8-home:')
        ? category.apiSort.substring('wenku8-home:'.length)
        : category.title;
    final source = BookSource(
      id: category.sourceId,
      name: category.sourceName,
      baseUrl: category.sourceBaseUrl,
    );
    for (final origin in _wenku8OriginCandidates(source.baseUrl)) {
      try {
        final response = await _get(
          Uri.parse('$origin/wap/'),
          headers: _headers('$origin/wap/'),
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) continue;
        final responseSource = source.copyWith(
          baseUrl: _originOfResponse(response, fallback: origin),
        );
        final items = _parseWenku8HomeCategoryItems(
          _decodeBody(response),
          responseSource,
          targetTitle,
        );
        if (items.isNotEmpty) return items;
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  Future<List<Novel>> _fetchWenku8BackendToplist(
    NovelCategory category,
    String sort,
  ) async {
    if (!RegExp(r'^[a-z]+$').hasMatch(sort)) return const [];
    try {
      final uri = Uri.parse(
        '${InteractionAuthService.baseUrl}/wenku8/toplist',
      ).replace(queryParameters: {'sort': sort, 'pages': '3'});
      final response = await _get(
        uri,
        headers: _headers(InteractionAuthService.baseUrl),
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(_decodeBody(response));
      if (decoded is! Map || decoded['items'] is! List) return const [];
      final source = BookSource(
        id: category.sourceId,
        name: category.sourceName,
        baseUrl: category.sourceBaseUrl,
      );
      final seen = <String>{};
      return (decoded['items'] as List)
          .whereType<Map>()
          .map((item) {
            final bookId = item['bookId']?.toString() ?? '';
            final title = _cleanHtmlText(item['title']?.toString() ?? '');
            if (!RegExp(r'^\d+$').hasMatch(bookId) ||
                !_isNovelTitle(title) ||
                !seen.add(bookId)) {
              return null;
            }
            return _wenku8Novel(source, bookId: bookId, title: title);
          })
          .whereType<Novel>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Novel> _parseWenku8HomeCategoryItems(
    String wml,
    BookSource source,
    String targetTitle,
  ) {
    final novels = <Novel>[];
    final seen = <String>{};
    var currentSection = '';
    for (final rawLine in wml.split(
      RegExp(r'<br\s*/?>', caseSensitive: false),
    )) {
      final sectionMatch = RegExp(
        r'【([^】]+)】',
      ).firstMatch(_cleanHtmlText(rawLine));
      if (sectionMatch != null) {
        currentSection = sectionMatch.group(1)!.trim();
      }
      if (currentSection != targetTitle) continue;
      final fragment = html_parser.parseFragment(rawLine);
      for (final anchor in fragment.querySelectorAll('a')) {
        final bookId = _extractWenku8BookId(anchor.attributes['href'] ?? '');
        final title = _cleanHtmlText(anchor.text);
        if (bookId == null || !_isNovelTitle(title) || !seen.add(bookId)) {
          continue;
        }
        novels.add(_wenku8Novel(source, bookId: bookId, title: title));
      }
    }
    return novels;
  }

  Future<Novel> _fetchWenku8BookDetail(Novel novel) async {
    final bookId =
        _extractWenku8BookId(novel.chapterUrl) ??
        _extractWenku8BookId(novel.id);
    if (bookId == null) return novel;

    for (final origin in _wenku8OriginCandidates(novel.chapterUrl)) {
      try {
        final response = await _get(
          Uri.parse('$origin/wap/article/articleinfo.php?id=$bookId'),
          headers: _headers('$origin/wap/'),
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) continue;

        final body = _decodeBody(response);
        final responseOrigin = _originOfResponse(response, fallback: origin);
        final title = _firstWenku8Match(body, [
          RegExp(r'''<card[^>]*title=["']([^"']+)["']''', caseSensitive: false),
          RegExp(r'<b>(.*?)</b>', dotAll: true, caseSensitive: false),
        ]);
        final author = _firstWenku8Match(body, [
          RegExp(r'作者:\s*(?:<anchor[^>]*>)?([^<]+)', dotAll: true),
        ]);
        final status = _firstWenku8Match(body, [
          RegExp(r'状态:\s*([^<]+)<br', dotAll: true, caseSensitive: false),
        ]);
        final description = _firstWenku8Match(body, [
          RegExp(
            r'\[作品简介\]\s*<br\s*/?>(.*?)(?:<br\s*/?>\s*<p\s+align=|</p>)',
            dotAll: true,
            caseSensitive: false,
          ),
        ]);

        return novel.copyWith(
          title: title.isEmpty ? novel.title : title,
          author: author.isEmpty ? novel.author : author,
          coverUrl: _wenku8CoverUrl(bookId),
          description: description.isEmpty ? novel.description : description,
          chapterUrl: '$responseOrigin/wap/article/readbook.php?aid=$bookId',
          sourceId: novel.sourceId.isEmpty ? wenku8Source.id : novel.sourceId,
          sourceName: novel.sourceName.isEmpty
              ? wenku8Source.name
              : novel.sourceName,
          status: status.isEmpty ? novel.status : status,
        );
      } catch (_) {
        continue;
      }
    }
    return novel;
  }

  String _firstWenku8Match(String input, List<RegExp> patterns) {
    for (final pattern in patterns) {
      final value = pattern.firstMatch(input)?.group(1) ?? '';
      final cleaned = _cleanHtmlText(value);
      if (cleaned.isNotEmpty) return cleaned;
    }
    return '';
  }

  Novel _wenku8Novel(
    BookSource source, {
    required String bookId,
    required String title,
    String author = '',
  }) {
    final origin = _originOf(source.baseUrl).isEmpty
        ? _wenku8PrimaryOrigin
        : _originOf(source.baseUrl);
    return Novel(
      id: '${source.id}_wenku8_$bookId',
      title: title,
      author: author,
      coverUrl: _wenku8CoverUrl(bookId),
      chapterUrl: '$origin/wap/article/articleinfo.php?id=$bookId',
      sourceId: source.id,
      sourceName: source.name,
    );
  }

  String _wenku8CoverUrl(String bookId) {
    return wenku8CoverProxyUrl(bookId);
  }

  String _secureWenku8Url(String baseUrl, String rawUrl) {
    return _normalizeUrl(baseUrl, rawUrl)
        .replaceFirst('http://img.wenku8.com', 'https://img.wenku8.com')
        .replaceFirst('http://www.wenku8.', 'https://www.wenku8.');
  }

  Future<_BqgBookApiMeta?> _getBookApiMeta(Novel novel, String bookId) async {
    try {
      return await _bookApiMetaCache.get(
        bookId,
        loader: () async {
          final meta = await _fetchBookApiMeta(novel, bookId);
          if (meta == null) throw StateError('book detail not found');
          return meta;
        },
      );
    } catch (_) {
      return null;
    }
  }

  Future<_BqgBookApiMeta?> _fetchBookApiMeta(Novel novel, String bookId) async {
    for (final baseUrl in await _bqgOriginCandidates(novel.chapterUrl)) {
      try {
        final response = await _get(
          Uri.parse('$baseUrl/api/book?id=$bookId'),
          headers: _headers(baseUrl),
        ).timeout(const Duration(seconds: 6));
        if (response.statusCode != 200) continue;
        await _rememberBqgResponseOrigin(response);
        final responseOrigin = _originOfResponse(response, fallback: baseUrl);

        final data = jsonDecode(_decodeBody(response));
        if (data is! Map) continue;
        final dirId = (data['dirid'] ?? data['id'] ?? bookId).toString();
        return _BqgBookApiMeta(
          novel: _mergeBqgBookDetail(novel, data, responseOrigin, bookId),
          bookId: bookId,
          dirId: dirId,
          baseUrl: responseOrigin,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<NovelHomeData?> _readCachedHome(
    BookSource source, {
    required bool allowExpired,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_homeCacheKey(source));
    if (raw == null || raw.isEmpty) return null;

    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = data['cachedAt'] as int? ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
      if (!allowExpired && age > _homeCacheTtl.inMilliseconds) return null;
      return NovelHomeData.fromJson(data['home'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCachedHome(BookSource source, NovelHomeData data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _homeCacheKey(source),
      jsonEncode({
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
        'home': data.toJson(),
      }),
    );
  }

  String _homeCacheKey(BookSource source) {
    final host = Uri.tryParse(source.baseUrl)?.host ?? source.baseUrl;
    return _homeCachePrefix + base64Url.encode(utf8.encode(host));
  }

  bool _isBqgApiSource(BookSource source) {
    final host = Uri.tryParse(source.baseUrl)?.host.toLowerCase() ?? '';
    return _isKnownBqgHost(host);
  }

  Future<NovelHomeData> _fetchBqgApiHome(BookSource source) async {
    final candidates = await _bqgOriginCandidates(source.baseUrl);
    if (candidates.isEmpty) return const NovelHomeData.empty();
    var winner = await _fetchBqgHomeCandidate(
      candidates.first,
      timeout: const Duration(seconds: 3),
    );
    if (winner == null && candidates.length > 1) {
      winner = await _firstSuccessful(
        candidates
            .skip(1)
            .map(
              (candidate) => _fetchBqgHomeCandidate(
                candidate,
                timeout: const Duration(seconds: 4),
              ),
            ),
      );
    }
    if (winner == null) return const NovelHomeData.empty();
    final decoded = winner.data;
    final base = winner.baseUrl;
    final normalizedSource = source.copyWith(baseUrl: base);

    final sections = <NovelHomeSection>[];
    final featured = _parseBqgApiNovels(
      decoded['hotlist'],
      normalizedSource,
      defaultStatus: '推荐',
    );

    void addSection(String key, String title) {
      final items = _parseBqgApiNovels(decoded[key], normalizedSource);
      if (items.isEmpty) return;
      sections.add(
        NovelHomeSection(
          title: title,
          items: items,
          category: _bqgCategoryForSection(normalizedSource, title),
        ),
      );
    }

    addSection('toplist', '强力推荐');
    addSection('sort1', '玄幻奇幻');
    addSection('sort2', '武侠仙侠');
    addSection('sort3', '都市言情');
    addSection('sort4', '历史军事');
    addSection('sort5', '网游竞技');
    addSection('sort6', '科幻灵异');
    addSection('addlist', '最新入库');
    addSection('uplist', '最近更新');

    return NovelHomeData(
      sourceName: normalizedSource.name,
      featured: featured,
      sections: sections,
      categories: _bqgCategories(normalizedSource),
    );
  }

  Future<({Map<dynamic, dynamic> data, String baseUrl})?>
  _fetchBqgHomeCandidate(String candidate, {required Duration timeout}) async {
    try {
      final response = await _get(
        Uri.parse('$candidate/api/index?sort=index'),
        headers: _headers(candidate),
      ).timeout(timeout);
      if (response.statusCode != 200) return null;
      final data = jsonDecode(_decodeBody(response));
      if (data is! Map) return null;
      await _rememberBqgResponseOrigin(response);
      return (
        data: data,
        baseUrl: _originOfResponse(response, fallback: candidate),
      );
    } catch (_) {
      return null;
    }
  }

  Future<T?> _firstSuccessful<T>(Iterable<Future<T?>> attempts) {
    final futures = attempts.toList();
    if (futures.isEmpty) return Future<T?>.value();
    final completer = Completer<T?>();
    var remaining = futures.length;

    void finishAttempt(T? value) {
      if (completer.isCompleted) return;
      if (value != null) {
        completer.complete(value);
        return;
      }
      remaining--;
      if (remaining == 0) completer.complete(null);
    }

    for (final future in futures) {
      future.then(finishAttempt, onError: (_) => finishAttempt(null));
    }
    return completer.future;
  }

  NovelCategory _bqgCategoryForSection(BookSource source, String title) {
    final categories = _bqgCategories(source);
    for (final category in categories) {
      if (title.contains(category.title.replaceAll('小说', '')) ||
          category.title.contains(
            title.substring(0, title.length.clamp(0, 2).toInt()),
          )) {
        return category;
      }
    }
    return const NovelCategory.empty();
  }

  List<NovelCategory> _bqgCategories(BookSource source) {
    const values = [
      ('玄幻', 'xuanhuan', 'magic'),
      ('武侠', 'wuxia', 'sword'),
      ('都市', 'dushi', 'city'),
      ('历史', 'lishi', 'history'),
      ('网游', 'wangyou', 'game'),
      ('科幻', 'kehuan', 'science'),
      ('女生', 'mm', 'female'),
      ('完本', 'finish', 'done'),
      ('排行', 'top', 'hot'),
    ];
    return values
        .map(
          (item) => NovelCategory(
            title: item.$1,
            url: _normalizeUrl(source.baseUrl, '/#/${item.$2}'),
            icon: item.$3,
            sourceId: source.id,
            sourceName: source.name,
            sourceBaseUrl: source.baseUrl,
            apiSort: item.$2,
          ),
        )
        .toList();
  }

  Future<List<Novel>> _fetchBqgApiCategory(NovelCategory category) async {
    for (final base in await _bqgOriginCandidates(category.sourceBaseUrl)) {
      try {
        final response = await _get(
          Uri.parse(
            '$base/api/sort?sort=${Uri.encodeComponent(category.apiSort)}',
          ),
          headers: _headers(base),
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) continue;
        await _rememberBqgResponseOrigin(response);
        final source = BookSource(
          id: category.sourceId,
          name: category.sourceName,
          baseUrl: _originOfResponse(response, fallback: base),
        );

        final decoded = jsonDecode(_decodeBody(response));
        final raw = decoded is Map ? decoded['data'] : decoded;
        final novels = _parseBqgApiNovels(raw, source).take(60).toList();
        if (novels.isNotEmpty) return novels;
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  List<Novel> _parseBqgApiNovels(
    dynamic raw,
    BookSource source, {
    String defaultStatus = '连载中',
  }) {
    if (raw is! List) return const [];
    final novels = <Novel>[];
    final seen = <String>{};

    for (final item in raw) {
      if (item is! Map) continue;
      final id = (item['id'] ?? '').toString().trim();
      final title = (item['title'] ?? '').toString().trim();
      if (id.isEmpty || !_isNovelTitle(title)) continue;

      final author = (item['author'] ?? '').toString().trim();
      final intro = (item['intro'] ?? item['description'] ?? '')
          .toString()
          .trim();
      final sortName = (item['sortname'] ?? '').toString().trim();
      final lastChapter = (item['lastchapter'] ?? '').toString().trim();
      final key = '$id|$title';
      if (!seen.add(key)) continue;

      novels.add(
        Novel(
          id: _bqgNovelId(source, id),
          title: title,
          author: author,
          coverUrl: _bqgCoverUrl(source.baseUrl, id),
          description: intro,
          chapterUrl: _normalizeUrl(source.baseUrl, '/#/book/$id/'),
          sourceId: source.id,
          sourceName: source.name,
          status: lastChapter.isNotEmpty
              ? lastChapter
              : sortName.isNotEmpty
              ? sortName
              : defaultStatus,
        ),
      );
    }

    return novels;
  }

  String _bqgCoverUrl(String baseUrl, String rawId) {
    final id = int.tryParse(rawId);
    if (id == null) return '';
    final origin = _bqgBestOrigin(baseUrl);
    return '$origin/bookimg/${id ~/ 1000}/$id.jpg';
  }

  bool _isKnownBqgHost(String host) {
    final lowerHost = host.toLowerCase();
    return lowerHost.contains('bqg') ||
        lowerHost == Uri.parse(_bqgPrimaryOrigin).host ||
        lowerHost == Uri.parse(_bqgApexOrigin).host ||
        lowerHost == Uri.parse(_bqgBackupOrigin).host ||
        lowerHost == Uri.parse(_bqgApiOrigin).host ||
        lowerHost == Uri.parse(_bqgWwwApiOrigin).host ||
        lowerHost == Uri.parse(_bqgWebOrigin).host ||
        lowerHost == Uri.parse(_bqgLegacyOrigin).host;
  }

  bool _isKnownWenku8Host(String host) {
    final lowerHost = host.toLowerCase();
    return lowerHost == Uri.parse(_wenku8PrimaryOrigin).host ||
        lowerHost == Uri.parse(_wenku8BackupOrigin).host ||
        lowerHost.endsWith('.wenku8.cc') ||
        lowerHost.endsWith('.wenku8.net') ||
        lowerHost.endsWith('.wenku8.com') ||
        lowerHost.endsWith('.wenku8.cn');
  }

  bool _isBqgNovel(Novel novel) {
    if (novel.sourceId == bqg995Source.id || novel.id.contains('_bqg_')) {
      return true;
    }
    final host = Uri.tryParse(novel.chapterUrl)?.host ?? '';
    return _isKnownBqgHost(host);
  }

  bool _isWenku8Novel(Novel novel) {
    if (novel.sourceId == wenku8Source.id || novel.id.contains('_wenku8_')) {
      return true;
    }
    final host = Uri.tryParse(novel.chapterUrl)?.host ?? '';
    return _isKnownWenku8Host(host);
  }

  List<String> _wenku8OriginCandidates(String preferredUrl) {
    final candidates = <String>[];

    void add(String origin) {
      final normalized = _originOf(origin);
      if (normalized.isEmpty) return;
      final host = Uri.tryParse(normalized)?.host ?? '';
      if (_isKnownWenku8Host(host) && !candidates.contains(normalized)) {
        candidates.add(normalized);
      }
    }

    add(preferredUrl);
    add(_wenku8PrimaryOrigin);
    add(_wenku8BackupOrigin);
    return candidates;
  }

  String? _extractWenku8BookId(String value) {
    final patterns = [
      RegExp(r'[?&](?:id|aid)=(\d+)'),
      RegExp(r'/book/(\d+)\.htm'),
      RegExp(r'/novel/\d+/(\d+)/'),
      RegExp(r'_wenku8_(\d+)$'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(value);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String _bqgBestOrigin(String urlOrOrigin) {
    final origin = _originOf(urlOrOrigin);
    if (origin.isEmpty) return _bqgPrimaryOrigin;
    final host = Uri.tryParse(origin)?.host.toLowerCase() ?? '';
    if (host == Uri.parse(_bqgApiOrigin).host ||
        host == Uri.parse(_bqgWwwApiOrigin).host ||
        host == Uri.parse(_bqgWebOrigin).host ||
        host == Uri.parse(_bqgLegacyOrigin).host) {
      return _bqgPrimaryOrigin;
    }
    return _isKnownBqgHost(host) ? origin : _bqgPrimaryOrigin;
  }

  Future<List<String>> _bqgOriginCandidates(String preferredUrl) async {
    final preferredOrigin = _originOf(preferredUrl);
    return _domainService.originCandidates(
      _bqgDomain,
      preferredOrigin: preferredOrigin,
    );
  }

  Future<List<String>> _bqgChapterApiOriginCandidates(
    String preferredUrl,
  ) async {
    final candidates = <String>[];

    void add(String origin) {
      if (origin.isNotEmpty && !candidates.contains(origin)) {
        candidates.add(origin);
      }
    }

    for (final origin in await _bqgOriginCandidates(preferredUrl)) {
      add(origin);
    }
    for (final origin in _bqgChapterApiOrigins) {
      add(origin);
    }
    return candidates;
  }

  Future<void> _rememberBqgResponseOrigin(http.Response response) async {
    final uri = response.request?.url;
    if (uri == null || !_isKnownBqgHost(uri.host)) return;
    await _domainService.rememberOrigin(_bqgDomain, uri);
  }

  String _originOfResponse(http.Response response, {required String fallback}) {
    final uri = response.request?.url;
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      return SiteDomainService.originOf(uri);
    }
    return _originOf(fallback).isEmpty ? fallback : _originOf(fallback);
  }

  String _replaceUrlOrigin(String url, String origin) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return _normalizeUrl(origin, url);
    }
    return SiteDomainService.replaceOrigin(uri, origin).toString();
  }

  String _bqgNovelId(BookSource source, String rawId) {
    return '${source.id}_bqg_$rawId';
  }

  Novel _mergeBqgBookDetail(
    Novel novel,
    Map<dynamic, dynamic> data,
    String baseUrl,
    String fallbackBookId,
  ) {
    final bookId = (data['id'] ?? fallbackBookId).toString().trim();
    final title = (data['title'] ?? '').toString().trim();
    final author = (data['author'] ?? '').toString().trim();
    final intro = (data['intro'] ?? data['description'] ?? '')
        .toString()
        .trim();
    final sortName = (data['sortname'] ?? '').toString().trim();
    final full = (data['full'] ?? '').toString().trim();
    final lastChapter = (data['lastchapter'] ?? '').toString().trim();
    final sourceId = novel.sourceId.isNotEmpty
        ? novel.sourceId
        : bqg995Source.id;
    final sourceName = novel.sourceName.isNotEmpty
        ? novel.sourceName
        : bqg995Source.name;
    return novel.copyWith(
      title: title.isNotEmpty ? title : novel.title,
      author: author.isNotEmpty ? author : novel.author,
      coverUrl: novel.coverUrl.isNotEmpty
          ? novel.coverUrl
          : _bqgCoverUrl(baseUrl, bookId),
      description: intro.isNotEmpty ? intro : novel.description,
      chapterUrl: _normalizeUrl(baseUrl, '/#/book/$bookId/'),
      sourceId: sourceId,
      sourceName: sourceName,
      status: full.isNotEmpty
          ? full
          : lastChapter.isNotEmpty
          ? lastChapter
          : sortName.isNotEmpty
          ? sortName
          : novel.status,
      totalChapters:
          int.tryParse((data['lastchapterid'] ?? '').toString()) ??
          novel.totalChapters,
    );
  }

  Future<NovelHomeData> _fetchHtmlHome(BookSource source) async {
    final response = await _get(
      Uri.parse(source.baseUrl),
      headers: _headers(source.baseUrl),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return const NovelHomeData.empty();

    final document = html_parser.parse(_decodeBody(response));
    final sections = _parseHtmlSections(document, source);
    final allItems = _parseHtmlNovelItems(document, source);
    return NovelHomeData(
      sourceName: source.name,
      featured: allItems.take(8).toList(),
      sections: sections.isNotEmpty
          ? sections.take(8).toList()
          : [
              if (allItems.isNotEmpty)
                NovelHomeSection(
                  title: '小说推荐',
                  items: allItems.take(12).toList(),
                ),
              if (allItems.length > 12)
                NovelHomeSection(
                  title: '最近更新',
                  items: allItems.skip(12).take(12).toList(),
                ),
            ],
      categories: _parseHtmlCategories(document, source),
    );
  }

  List<NovelCategory> _parseHtmlCategories(
    dom.Document document,
    BookSource source,
  ) {
    final categories = <NovelCategory>[];
    final seen = <String>{};
    for (final link in document.querySelectorAll(
      '.nav a[href], nav a[href], a[href*="/fenlei/"]',
    )) {
      final title = _cleanHtmlText(link.text).replaceAll(' ', '');
      final href = link.attributes['href'] ?? '';
      if (title.length < 2 ||
          title.length > 6 ||
          title.contains('首页') ||
          title.contains('书架') ||
          title.contains('记录') ||
          _isLikelyNavigationUrl(href)) {
        continue;
      }
      final url = _normalizeUrl(source.baseUrl, href);
      if (url.isEmpty || !seen.add(url)) continue;
      categories.add(
        NovelCategory(
          title: title,
          url: url,
          icon: _categoryIconValue(title),
          sourceId: source.id,
          sourceName: source.name,
          sourceBaseUrl: source.baseUrl,
        ),
      );
      if (categories.length >= 8) break;
    }
    return categories;
  }

  List<NovelHomeSection> _parseHtmlSections(
    dom.Document document,
    BookSource source,
  ) {
    final sections = <NovelHomeSection>[];
    final seenTitles = <String>{};
    final seenSignatures = <String>{};

    for (final heading in document.querySelectorAll(
      'h2,h3,.layout-tit,.title',
    )) {
      final title = _cleanHtmlText(
        heading.text,
      ).replaceAll('更多', '').replaceAll('小说', '').trim();
      if (!_isUsefulHomeSectionTitle(title) || !seenTitles.add(title)) {
        continue;
      }

      final module = _sectionContainer(heading);
      if (module == null) continue;
      final items = _parseHtmlNovelItems(module, source);
      if (items.length < 3) continue;

      final signature = items.take(4).map((item) => item.id).join(',');
      if (!seenSignatures.add(signature)) continue;
      sections.add(
        NovelHomeSection(
          title: title,
          items: items.take(12).toList(),
          category: _sectionCategory(heading, module, source),
        ),
      );
    }

    return sections;
  }

  dom.Element? _sectionContainer(dom.Element heading) {
    dom.Element? current = heading.parent;
    for (var depth = 0; depth < 4 && current != null; depth++) {
      if (current.querySelectorAll('a[href]').length >= 4) return current;
      current = current.parent;
    }
    return heading.parent;
  }

  NovelCategory _sectionCategory(
    dom.Element heading,
    dom.Element module,
    BookSource source,
  ) {
    for (final link in [
      ...heading.querySelectorAll('a[href]'),
      ...module.querySelectorAll('a[href]'),
    ]) {
      final href = link.attributes['href'] ?? '';
      final text = _cleanHtmlText(link.text);
      if (href.isEmpty ||
          _isLikelyNavigationUrl(href) ||
          _looksLikeBookUrl(href) ||
          text.contains('作者')) {
        continue;
      }
      return NovelCategory(
        title: text.isEmpty ? '更多' : text,
        url: _normalizeUrl(source.baseUrl, href),
        icon: _categoryIconValue(text),
        sourceId: source.id,
        sourceName: source.name,
        sourceBaseUrl: source.baseUrl,
      );
    }
    return const NovelCategory.empty();
  }

  bool _isUsefulHomeSectionTitle(String title) {
    if (title.length < 2 || title.length > 12) return false;
    const blocked = {'首页', '搜索', '登录', '注册', '会员书架', '阅读记录'};
    return !blocked.contains(title);
  }

  String _categoryIconValue(String title) {
    if (title.contains('玄幻')) return 'magic';
    if (title.contains('武侠') || title.contains('仙侠')) return 'sword';
    if (title.contains('都市')) return 'city';
    if (title.contains('历史') || title.contains('军史')) return 'history';
    if (title.contains('网游')) return 'game';
    if (title.contains('科幻') || title.contains('灵异')) return 'science';
    if (title.contains('女生') || title.contains('言情')) return 'female';
    if (title.contains('完本')) return 'done';
    if (title.contains('排行') || title.contains('推荐')) return 'hot';
    return 'book';
  }

  List<Novel> _parseHtmlNovelItems(dom.Node root, BookSource source) {
    final items = <Novel>[];
    final seen = <String>{};

    void add(Novel novel) {
      if (novel.title.isEmpty || novel.chapterUrl.isEmpty) return;
      final key = '${novel.title}|${novel.author}|${novel.chapterUrl}';
      if (!seen.add(key)) return;
      items.add(novel);
    }

    for (final element in _queryElements(
      root,
      '.item,.bookbox,.txt-list li,.txt-list-row3 li,tr,li',
    )) {
      final novel = _parseHtmlNovelElement(element, source);
      if (novel != null) add(novel);
      if (items.length >= 80) return items;
    }

    if (items.isNotEmpty) return items;

    for (final link in _queryElements(root, 'a[href]')) {
      final href = link.attributes['href'] ?? '';
      if (!_looksLikeBookUrl(href) || _isLikelyNavigationUrl(href)) continue;
      final title = _cleanHtmlText(link.text);
      if (!_isNovelTitle(title)) continue;
      add(
        Novel(
          id: '${source.id}_${href.hashCode}_${title.hashCode}',
          title: title,
          chapterUrl: _normalizeUrl(source.baseUrl, href),
          sourceId: source.id,
          sourceName: source.name,
        ),
      );
      if (items.length >= 80) break;
    }

    return items;
  }

  List<dom.Element> _queryElements(dom.Node root, String selector) {
    if (root is dom.Document) return root.querySelectorAll(selector);
    if (root is dom.Element) return root.querySelectorAll(selector);
    return const [];
  }

  Novel? _parseHtmlNovelElement(dom.Element element, BookSource source) {
    dom.Element? titleLink;
    for (final link in element.querySelectorAll('a[href]')) {
      final href = link.attributes['href'] ?? '';
      final text = _cleanHtmlText(link.text);
      if (_looksLikeBookUrl(href) &&
          !_isLikelyNavigationUrl(href) &&
          _isNovelTitle(text)) {
        titleLink = link;
        break;
      }
    }
    titleLink ??= element.querySelector('a[href]');
    if (titleLink == null) return null;

    final href = titleLink.attributes['href'] ?? '';
    final title = _cleanHtmlText(
      titleLink.text.isNotEmpty
          ? titleLink.text
          : titleLink.attributes['title'] ?? titleLink.attributes['alt'] ?? '',
    );
    if (!_isNovelTitle(title) || _isLikelyNavigationUrl(href)) return null;

    final image = element.querySelector('img');
    final cover = image == null
        ? ''
        : image.attributes['data-src'] ??
              image.attributes['data-original'] ??
              image.attributes['src'] ??
              '';
    final author = _extractHtmlAuthor(element, title);
    final description = _cleanHtmlText(
      element.querySelector('dd,p,.intro,.desc')?.text ?? '',
    );
    final status = _extractHtmlStatus(element);

    return Novel(
      id: '${source.id}_${href.hashCode}_${title.hashCode}',
      title: title,
      author: author,
      coverUrl: _normalizeUrl(source.baseUrl, cover),
      description: description,
      chapterUrl: _normalizeUrl(source.baseUrl, href),
      sourceId: source.id,
      sourceName: source.name,
      status: status.isEmpty ? '连载中' : status,
    );
  }

  String _extractHtmlAuthor(dom.Element element, String title) {
    final selectors = ['dt span', '.s5', '.author', '[class*="author"]'];
    for (final selector in selectors) {
      final value = _cleanHtmlText(element.querySelector(selector)?.text ?? '');
      if (value.isNotEmpty && !value.contains(title) && value.length <= 30) {
        return value.replaceFirst(RegExp(r'^作者[:：]?\s*'), '').trim();
      }
    }

    final text = _cleanHtmlText(element.text);
    final authorMatch = RegExp(
      r'(?:作者|writer|author)[:：]?\s*([^\s/，,]{2,30})',
      caseSensitive: false,
    ).firstMatch(text);
    if (authorMatch != null) return authorMatch.group(1)!.trim();

    final slashMatch = RegExp(r'/([^\s/，,]{2,30})$').firstMatch(text);
    return slashMatch?.group(1)?.trim() ?? '';
  }

  String _extractHtmlStatus(dom.Element element) {
    final text = _cleanHtmlText(element.text);
    final chapterMatch = RegExp(
      r'(第.{1,12}章|更新至.{1,20}|最新.{1,20})',
    ).firstMatch(text);
    if (chapterMatch != null) return chapterMatch.group(1)!.trim();
    if (text.contains('完结') || text.contains('完本')) return '已完结';
    return '';
  }

  Future<List<BookSource>> getEnabledSources() async {
    final sourcesData = await _storage.getBookSources();
    final sources = sourcesData
        .map((s) => BookSource.fromJson(s))
        .where((s) => s.enabled)
        .toList();
    sources.sort((left, right) => right.weight.compareTo(left.weight));
    return sources;
  }

  Future<List<BookSource>> getAllSources() async {
    final sourcesData = await _storage.getBookSources();
    return sourcesData.map((s) => BookSource.fromJson(s)).toList();
  }

  Future<void> addSource(BookSource source) async {
    await _storage.saveBookSource(source.toJson());
  }

  Future<void> updateSource(BookSource source) async {
    await _storage.saveBookSource(source.toJson());
  }

  Future<void> deleteSource(String sourceId) async {
    await _storage.deleteBookSource(sourceId);
  }

  Future<void> toggleSource(String sourceId, bool enabled) async {
    final sources = await getAllSources();
    final source = sources.firstWhere((s) => s.id == sourceId);
    await _storage.saveBookSource(source.copyWith(enabled: enabled).toJson());
  }

  Future<List<Novel>> searchBooks(String keyword, {String? sourceId}) async {
    var sources = await _searchableSources(await getAllSources());
    if (sourceId != null && sourceId.isNotEmpty) {
      sources = sources.where((source) => source.id == sourceId).toList();
    }
    final results = <Novel>[];
    final seen = <String>{};

    for (final source in sources) {
      try {
        for (final novel in await _searchFromSource(source, keyword)) {
          final key =
              '${novel.sourceId}|${novel.title}|${novel.author}|${novel.chapterUrl}';
          if (seen.add(key)) results.add(novel);
        }
      } catch (_) {
        continue;
      }
    }

    return results;
  }

  Future<List<BookSource>> _searchableSources(
    List<BookSource> savedSources,
  ) async {
    final currentOrigin = await _domainService.currentOrigin(_bqgDomain);
    final sources = <BookSource>[...savedSources];
    if (!sources.any((source) => source.id == bqg995Source.id)) {
      sources.add(bqg995Source);
    }
    if (!sources.any((source) => source.id == wenku8Source.id)) {
      sources.add(wenku8Source);
    }

    final normalized = <BookSource>[];
    for (final source in sources) {
      if (!source.enabled) continue;
      if (source.id == bqg995Source.id) {
        normalized.add(
          source.copyWith(
            name: bqg995Source.name,
            baseUrl: currentOrigin,
            searchUrl: '$currentOrigin/api/search?q={keyword}',
            weight: bqg995Source.weight,
          ),
        );
      } else if (source.id == wenku8Source.id) {
        normalized.add(
          source.copyWith(
            name: wenku8Source.name,
            baseUrl: _wenku8PrimaryOrigin,
            searchUrl: wenku8Source.searchUrl,
            weight: wenku8Source.weight,
          ),
        );
      } else {
        normalized.add(source);
      }
    }
    normalized.sort((left, right) => right.weight.compareTo(left.weight));
    return normalized;
  }

  Future<List<Novel>> _searchFromSource(
    BookSource source,
    String keyword,
  ) async {
    if (isWenku8Source(source)) {
      return _searchWenku8(source, keyword);
    }

    final novels = <Novel>[];
    final seen = <String>{};

    for (final url in await _buildSearchUrls(source, keyword)) {
      try {
        final response = await _get(
          Uri.parse(url),
          headers: _headers(source.baseUrl),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode != 200) continue;
        await _rememberBqgResponseOrigin(response);
        final responseSource = source.copyWith(
          baseUrl: _originOfResponse(response, fallback: source.baseUrl),
        );

        final body = _decodeBody(response);
        var parsedNovels = _parseJsonSearchResults(body, responseSource);
        if (parsedNovels.isEmpty) {
          parsedNovels = await _searchJsonEndpointIfNeeded(
            body,
            responseSource,
            keyword,
          );
        }
        if (parsedNovels.isEmpty) {
          parsedNovels = _parseSearchResults(body, responseSource, keyword);
        }

        for (final novel in parsedNovels) {
          final key = '${novel.title}|${novel.author}|${novel.chapterUrl}';
          if (seen.add(key)) novels.add(novel);
        }
        if (novels.isNotEmpty) break;
      } catch (_) {
        continue;
      }
    }

    return novels;
  }

  Future<List<Novel>> _searchWenku8(BookSource source, String keyword) async {
    for (final origin in _wenku8OriginCandidates(source.baseUrl)) {
      try {
        final response = await _post(
          Uri.parse('$origin/wap/article/search.php'),
          headers: _headers('$origin/wap/'),
          body: <String, String>{
            'action': 'search',
            'searchtype': 'articlename',
            'searchkey': keyword,
          },
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) continue;

        final responseOrigin = _originOfResponse(response, fallback: origin);
        final responseSource = source.copyWith(baseUrl: responseOrigin);
        final document = html_parser.parse(_decodeBody(response));
        final novels = <Novel>[];
        final seen = <String>{};
        for (final anchor in document.querySelectorAll('a')) {
          final href = anchor.attributes['href'] ?? '';
          final bookId = _extractWenku8BookId(href);
          if (bookId == null || !seen.add(bookId)) continue;

          final label = _cleanHtmlText(anchor.text);
          final match = RegExp(r'^《(.+?)》(.*)$').firstMatch(label);
          final title = (match?.group(1) ?? label).trim();
          final author = (match?.group(2) ?? '').trim();
          if (!_isNovelTitle(title)) continue;
          novels.add(
            _wenku8Novel(
              responseSource,
              bookId: bookId,
              title: title,
              author: author,
            ),
          );
        }
        if (novels.isNotEmpty) return novels;
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  Map<String, String> _headers(String referer) => {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/125.0 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.7',
    if (referer.isNotEmpty) 'Referer': referer,
  };

  String _decodeBody(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    }
  }

  Future<List<Novel>> _searchJsonEndpointIfNeeded(
    String html,
    BookSource source,
    String keyword,
  ) async {
    final patterns = [
      RegExp(
        r"""\$\.getJSON\(["']([^"']*search[^"']*[?&][^"']*=)["']\s*\+\s*q""",
        caseSensitive: false,
      ),
      RegExp(
        r"""url\s*:\s*["']([^"']*search[^"']*[?&][^"']*=)["']""",
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match == null) continue;

      final endpoint = match.group(1) ?? '';
      final url =
          _normalizeUrl(source.baseUrl, endpoint) +
          Uri.encodeComponent(keyword);

      try {
        final response = await _get(
          Uri.parse(url),
          headers: _headers(source.baseUrl),
        ).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) continue;
        final results = _parseJsonSearchResults(_decodeBody(response), source);
        if (results.isNotEmpty) return results;
      } catch (_) {
        continue;
      }
    }

    return const [];
  }

  List<Novel> _parseJsonSearchResults(String body, BookSource source) {
    try {
      final items = _jsonSearchItems(jsonDecode(body));
      if (items.isEmpty) return const [];

      final novels = <Novel>[];
      for (final item in items) {
        if (item is! Map) continue;
        final title =
            (item['articlename'] ??
                    item['bookname'] ??
                    item['bookName'] ??
                    item['title'] ??
                    item['name'] ??
                    '')
                .toString()
                .trim();
        var url =
            (item['url_list'] ??
                    item['url'] ??
                    item['bookUrl'] ??
                    item['book_url'] ??
                    item['info_url'] ??
                    '')
                .toString()
                .trim();
        final rawId = (item['id'] ?? item['bookid'] ?? item['dirid'] ?? '')
            .toString()
            .trim();
        if (url.isEmpty && rawId.isNotEmpty) {
          url = '/#/book/$rawId/';
        }
        if (!_isNovelTitle(title) || _isLikelyNavigationUrl(url)) continue;

        final author = (item['author'] ?? item['writer'] ?? '')
            .toString()
            .replaceAll(RegExp(r'^\s*[:\uff1a]\s*'), '')
            .trim();
        var cover =
            (item['url_img'] ??
                    item['cover'] ??
                    item['img'] ??
                    item['image'] ??
                    '')
                .toString()
                .trim();
        if (cover.isEmpty && rawId.isNotEmpty) {
          cover =
              '/bookimg/${int.tryParse(rawId) == null ? 0 : int.parse(rawId) ~/ 1000}/$rawId.jpg';
        }
        final intro = (item['intro'] ?? item['description'] ?? '')
            .toString()
            .trim();

        novels.add(
          Novel(
            id: rawId.isNotEmpty
                ? _bqgNovelId(source, rawId)
                : '${source.id}_${url.hashCode}_${title.hashCode}',
            title: title,
            author: author,
            coverUrl: _normalizeUrl(source.baseUrl, cover),
            description: intro,
            chapterUrl: _normalizeUrl(source.baseUrl, url),
            sourceId: source.id,
            sourceName: source.name,
          ),
        );
      }
      return novels;
    } catch (_) {
      return const [];
    }
  }

  List<dynamic> _jsonSearchItems(dynamic data) {
    if (data is List) return data;
    if (data is Map) {
      for (final key in [
        'data',
        'result',
        'results',
        'list',
        'books',
        'items',
      ]) {
        final value = data[key];
        if (value is List) return value;
        if (value is Map) {
          final nested = _jsonSearchItems(value);
          if (nested.isNotEmpty) return nested;
        }
      }
    }
    return const [];
  }

  Future<List<String>> _buildSearchUrls(
    BookSource source,
    String keyword,
  ) async {
    final encoded = Uri.encodeComponent(keyword);
    final urls = <String>[];

    void add(String url) {
      if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
    }

    final bases = _isBqgApiSource(source)
        ? await _bqgOriginCandidates(source.baseUrl)
        : <String>[
            if (_originOf(source.baseUrl).isNotEmpty)
              _originOf(source.baseUrl)
            else
              source.baseUrl,
          ];
    for (final base in bases) {
      add('$base/api/search?q=$encoded');
      add(source.searchUrl.replaceAll('{keyword}', encoded));
      if (_isBqgApiSource(source)) continue;
      add('$base/search?q=$encoded');
      add('$base/search?keyword=$encoded');
      add('$base/search.html?q=$encoded');
      add('$base/search.html?keyword=$encoded');
      add('$base/search.htm?keyword=$encoded');
      add('$base/modules/article/search.php?searchkey=$encoded');
      add('$base/s.php?ie=utf-8&s=$encoded');
    }
    return urls.take(12).toList();
  }

  List<Novel> _parseSearchResults(
    String html,
    BookSource source,
    String keyword,
  ) {
    final novels = <Novel>[];
    try {
      for (final block in _extractBookBlocks(html)) {
        final title = _extractTitle(block);
        final author = _extractAuthor(block);
        final cover = _extractCover(block);
        final url = _extractUrl(block);

        if (title.isEmpty ||
            _isLikelyNavigationUrl(url) ||
            !_matchesKeyword(block, title, keyword) ||
            !_hasBookSignals(block, author, cover, url)) {
          continue;
        }

        novels.add(
          Novel(
            id: '${source.id}_${url.hashCode}_${title.hashCode}',
            title: title,
            author: author,
            coverUrl: _normalizeUrl(source.baseUrl, cover),
            chapterUrl: _normalizeUrl(source.baseUrl, url),
            sourceId: source.id,
            sourceName: source.name,
          ),
        );
      }
    } catch (_) {
      return const [];
    }
    return novels;
  }

  List<String> _extractBookBlocks(String html) {
    final blocks = <String>[];
    final cleanedHtml = html
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), '')
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), '')
        .replaceAll(RegExp(r'<nav[^>]*>.*?</nav>', dotAll: true), '')
        .replaceAll(RegExp(r'<header[^>]*>.*?</header>', dotAll: true), '')
        .replaceAll(RegExp(r'<footer[^>]*>.*?</footer>', dotAll: true), '');

    final patterns = [
      RegExp(
        r"""<li[^>]*(?:class|id)=["'][^"']*(?:book|novel|result|search|item)[^"']*["'][^>]*>.*?</li>""",
        dotAll: true,
        caseSensitive: false,
      ),
      RegExp(
        r"""<div[^>]*(?:class|id)=["'][^"']*(?:bookbox|book[^"']*item|novel[^"']*item|result[^"']*item|search[^"']*item|txt-list-row)[^"']*["'][^>]*>.*?(?=<div[^>]*(?:class|id)=["'][^"']*(?:bookbox|book[^"']*item|novel[^"']*item|result[^"']*item|search[^"']*item|txt-list-row)[^"']*["']|</body>|$)""",
        dotAll: true,
        caseSensitive: false,
      ),
      RegExp(
        r'<tr[^>]*>.*?(?:author|writer|\u4f5c\u8005|book|novel).*?</tr>',
        dotAll: true,
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final matches = pattern.allMatches(cleanedHtml);
      blocks.addAll(matches.map((m) => m.group(0)!));
      if (blocks.length >= 30) return blocks.take(30).toList();
    }

    if (blocks.isNotEmpty) return blocks;

    final linkPattern = RegExp(
      r"""<a[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>""",
      dotAll: true,
      caseSensitive: false,
    );
    for (final match in linkPattern.allMatches(cleanedHtml)) {
      final url = match.group(1) ?? '';
      final title = _cleanHtmlText(match.group(2) ?? '');
      if (!_isNovelTitle(title) || _isLikelyNavigationUrl(url)) continue;
      if (!_looksLikeBookUrl(url) &&
          !RegExp(r'[\u4e00-\u9fa5]').hasMatch(title)) {
        continue;
      }

      final start = (match.start - 500).clamp(0, cleanedHtml.length).toInt();
      final end = (match.end + 1000).clamp(0, cleanedHtml.length).toInt();
      blocks.add('${match.group(0)!}${cleanedHtml.substring(start, end)}');
      if (blocks.length >= 30) break;
    }

    return blocks;
  }

  String _extractTitle(String block) {
    final patterns = [
      RegExp(
        r'<h[1-6][^>]*>\s*<a[^>]*>(.*?)</a>\s*</h[1-6]>',
        dotAll: true,
        caseSensitive: false,
      ),
      RegExp(
        r"""<a[^>]*class=["'][^"']*(?:bookname|name|title)[^"']*["'][^>]*>(.*?)</a>""",
        dotAll: true,
        caseSensitive: false,
      ),
      RegExp(r'<a[^>]*>(.*?)</a>', dotAll: true, caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(block);
      if (match == null) continue;
      final title = _cleanHtmlText(match.group(1)!);
      if (_isNovelTitle(title)) return title;
    }
    return '';
  }

  String _extractAuthor(String block) {
    final text = _cleanHtmlText(block);
    final match = RegExp(
      r'(?:author|writer|\u4f5c\u8005)\s*[:\uff1a]?\s*([^\s<,\u3001/]{2,30})',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) return match.group(1)!.trim();
    return '';
  }

  String _extractCover(String block) {
    final match = RegExp(
      r"""<img[^>]*(?:src|data-src|data-original)\s*=\s*["']([^"']+)["'][^>]*>""",
      caseSensitive: false,
    ).firstMatch(block);
    return match?.group(1) ?? '';
  }

  String _extractUrl(String block) {
    final match = RegExp(
      r"""<a[^>]*href\s*=\s*["']([^"']+)["'][^>]*>""",
      caseSensitive: false,
    ).firstMatch(block);
    return match?.group(1) ?? '';
  }

  bool _isNovelTitle(String title) {
    if (title.length < 2 || title.length > 60) return false;
    final normalized = title.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    const navTitles = {
      'home',
      'login',
      'register',
      'rss',
      'xml',
      'sitemap',
      '\u9996\u9875',
      '\u767b\u5f55',
      '\u6ce8\u518c',
      '\u6392\u884c\u699c',
      '\u9605\u8bfb\u8bb0\u5f55',
      '\u7f51\u7ad9\u5730\u56fe',
      '\u5730\u56fe',
    };
    if (navTitles.contains(normalized) || navTitles.contains(title)) {
      return false;
    }
    return !RegExp(
      r'^(?:more|new|hot|category|rank|library|all|rss|atom|txt|\u66f4\u591a|\u6700\u65b0|\u70ed\u95e8|\u5206\u7c7b|\u6392\u884c|\u4e66\u5e93|\u5168\u90e8)$',
      caseSensitive: false,
    ).hasMatch(title);
  }

  bool _isLikelyNavigationUrl(String url) {
    if (url.isEmpty) return true;
    final lowerUrl = url.toLowerCase();
    return lowerUrl == '/' ||
        lowerUrl.contains('/sort/') ||
        lowerUrl.contains('/class/') ||
        lowerUrl.contains('/top') ||
        lowerUrl.contains('/rank') ||
        lowerUrl.contains('/map') ||
        lowerUrl.contains('sitemap') ||
        lowerUrl.endsWith('.xml') ||
        lowerUrl.endsWith('/xml') ||
        lowerUrl.contains('/user') ||
        lowerUrl.contains('/login') ||
        lowerUrl.contains('/register') ||
        lowerUrl.contains('javascript:');
  }

  bool _looksLikeBookUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.contains('/book/') ||
        lowerUrl.contains('/novel/') ||
        lowerUrl.contains('/info/') ||
        lowerUrl.contains('/xiaoshuo/') ||
        lowerUrl.contains('bookid=') ||
        RegExp(r'/\d+/?$').hasMatch(lowerUrl) ||
        RegExp(r'/\d+\.html?$').hasMatch(lowerUrl);
  }

  bool _hasBookSignals(String block, String author, String cover, String url) {
    if (author.isNotEmpty || cover.isNotEmpty || _looksLikeBookUrl(url)) {
      return true;
    }
    final text = _cleanHtmlText(block);
    return RegExp(
      r'(author|writer|intro|latest|status|\u4f5c\u8005|\u7b80\u4ecb|\u4f5c\u54c1|\u6700\u65b0|\u72b6\u6001)',
      caseSensitive: false,
    ).hasMatch(text);
  }

  bool _matchesKeyword(String block, String title, String keyword) {
    final normalizedKeyword = keyword.trim();
    if (normalizedKeyword.isEmpty) return true;
    if (title.contains(normalizedKeyword)) return true;
    return _cleanHtmlText(block).contains(normalizedKeyword);
  }

  String _cleanHtmlText(String text) {
    return text
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeUrl(String baseUrl, String url) {
    if (url.isEmpty) return '';
    final hashRouteUrl = _normalizeHashRouteUrl(baseUrl, url);
    if (hashRouteUrl.isNotEmpty) return hashRouteUrl;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return 'https:$url';
    try {
      final normalizedBaseRouteUrl = _normalizeHashRouteUrl(baseUrl, baseUrl);
      final normalizedBaseUrl = normalizedBaseRouteUrl.isNotEmpty
          ? normalizedBaseRouteUrl
          : baseUrl;
      final baseUri = Uri.parse(normalizedBaseUrl);
      if (baseUri.hasScheme && baseUri.host.isNotEmpty) {
        return baseUri.resolve(url).toString();
      }
    } catch (_) {
      // Fall through to a conservative string join.
    }
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final cleanUrl = url.startsWith('/') ? url.substring(1) : url;
    return '$cleanBase/$cleanUrl';
  }

  String _normalizeHashRouteUrl(String baseUrl, String url) {
    final hashIndex = url.indexOf('#/');
    if (hashIndex < 0) return '';

    final route = url.substring(hashIndex + 1);
    if (!route.startsWith('/')) return '';

    try {
      if (url.startsWith('http://') || url.startsWith('https://')) {
        final uri = Uri.parse(url);
        return uri.replace(path: route, fragment: '').toString();
      }

      final baseUri = Uri.parse(baseUrl);
      if (baseUri.hasScheme && baseUri.host.isNotEmpty) {
        return baseUri.replace(path: route, fragment: '').toString();
      }
    } catch (_) {
      // Fall through to normal URL handling.
    }
    return '';
  }

  Future<List<Chapter>> getChapterList(
    Novel novel, {
    bool forceRefresh = false,
  }) {
    final cacheKey = ContentIdentity.novel(novel).contentKey;
    _chapterCacheKeysByNovelId
        .putIfAbsent(novel.id, () => <String>{})
        .add(cacheKey);
    return forceRefresh
        ? _chapterListCache.refresh(
            cacheKey,
            loader: () => _getChapterListUncached(novel),
          )
        : _chapterListCache.get(
            cacheKey,
            loader: () => _getChapterListUncached(novel),
          );
  }

  static final Map<String, Set<String>> _chapterCacheKeysByNovelId =
      <String, Set<String>>{};

  void invalidateChapterList(Novel novel) {
    final cacheKey = ContentIdentity.novel(novel).contentKey;
    _chapterListCache.invalidate(cacheKey);
    final keys = _chapterCacheKeysByNovelId[novel.id];
    keys?.remove(cacheKey);
    if (keys?.isEmpty ?? false) _chapterCacheKeysByNovelId.remove(novel.id);
  }

  void invalidateChapterListsForNovelId(String novelId) {
    final keys = _chapterCacheKeysByNovelId.remove(novelId) ?? const <String>{};
    for (final cacheKey in keys) {
      _chapterListCache.invalidate(cacheKey);
    }
  }

  Future<List<Chapter>> _getChapterListUncached(Novel novel) async {
    if (_isWenku8Novel(novel)) {
      return _getWenku8ChapterList(novel);
    }

    if (_isBqgNovel(novel)) {
      final apiChapters = await _getApiChapterList(novel);
      if (apiChapters.isNotEmpty) return apiChapters;
    }

    final chapters = <Chapter>[];
    final chapterOrigins = _isBqgNovel(novel)
        ? await _bqgOriginCandidates(novel.chapterUrl)
        : <String>[
            if (_originOf(novel.chapterUrl).isNotEmpty)
              _originOf(novel.chapterUrl),
          ];
    for (final baseUrl in chapterOrigins) {
      try {
        final url = _replaceUrlOrigin(novel.chapterUrl, baseUrl);
        final response = await _get(
          Uri.parse(url),
          headers: _headers(baseUrl),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          await _rememberBqgResponseOrigin(response);
          chapters.addAll(
            _extractChapterLinks(
              _decodeBody(response),
              novel.id,
              _replaceUrlOrigin(
                novel.chapterUrl,
                _originOfResponse(response, fallback: baseUrl),
              ),
            ),
          );
          if (chapters.isNotEmpty) break;
        }
      } catch (_) {
        continue;
      }
    }
    return chapters;
  }

  Future<List<Chapter>> _getWenku8ChapterList(Novel novel) async {
    final bookId =
        _extractWenku8BookId(novel.chapterUrl) ??
        _extractWenku8BookId(novel.id);
    if (bookId == null) return const [];

    for (final origin in _wenku8OriginCandidates(novel.chapterUrl)) {
      try {
        final pages = <String>[];
        final firstResponse = await _get(
          Uri.parse('$origin/wap/article/readbook.php?aid=$bookId'),
          headers: _headers('$origin/wap/article/articleinfo.php?id=$bookId'),
        ).timeout(const Duration(seconds: 15));
        if (firstResponse.statusCode != 200) continue;

        final firstPage = _decodeBody(firstResponse);
        pages.add(firstPage);
        final responseOrigin = _originOfResponse(
          firstResponse,
          fallback: origin,
        );
        final pageCount = _wenku8PageCount(firstPage).clamp(1, 200).toInt();
        var complete = true;
        for (var page = 2; page <= pageCount; page++) {
          final response = await _get(
            Uri.parse(
              '$responseOrigin/wap/article/readbook.php?aid=$bookId&page=$page',
            ),
            headers: _headers(
              '$responseOrigin/wap/article/articleinfo.php?id=$bookId',
            ),
          ).timeout(const Duration(seconds: 15));
          if (response.statusCode != 200) {
            complete = false;
            break;
          }
          pages.add(_decodeBody(response));
        }
        if (!complete) continue;

        final chapters = _parseWenku8Catalog(
          pages.join('\n'),
          novel,
          responseOrigin,
          bookId,
        );
        if (chapters.isNotEmpty) return chapters;
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  List<Chapter> _parseWenku8Catalog(
    String wml,
    Novel novel,
    String origin,
    String fallbackBookId,
  ) {
    final chapters = <Chapter>[];
    final seen = <String>{};
    var currentVolume = '';
    final tokenPattern = RegExp(
      r'''〖([^〗]+)〗|<a[^>]*href=["'][^"']*readchapter\.php\?([^"']+)["'][^>]*>(.*?)</a>''',
      dotAll: true,
      caseSensitive: false,
    );

    for (final match in tokenPattern.allMatches(wml)) {
      final volume = _cleanHtmlText(match.group(1) ?? '');
      if (volume.isNotEmpty) {
        currentVolume = volume;
        continue;
      }

      final query = match.group(2) ?? '';
      final bookId =
          RegExp(r'(?:^|&amp;|&)aid=(\d+)').firstMatch(query)?.group(1) ??
          fallbackBookId;
      final chapterId = RegExp(
        r'(?:^|&amp;|&)cid=(\d+)',
      ).firstMatch(query)?.group(1);
      final chapterTitle = _cleanHtmlText(match.group(3) ?? '');
      if (chapterId == null || chapterTitle.isEmpty) continue;
      if (!seen.add('$bookId|$chapterId')) continue;

      final title = currentVolume.isEmpty
          ? chapterTitle
          : '$currentVolume · $chapterTitle';
      chapters.add(
        Chapter(
          id: '${novel.id}_ch$chapterId',
          novelId: novel.id,
          title: title,
          index: chapters.length,
          url: '$origin/wap/article/readchapter.php?aid=$bookId&cid=$chapterId',
        ),
      );
    }
    return chapters;
  }

  int _wenku8PageCount(String wml) {
    var pageCount = 1;
    for (final match in RegExp(r'\[(\d+)\s*/\s*(\d+)\]').allMatches(wml)) {
      final total = int.tryParse(match.group(2) ?? '') ?? 1;
      if (total > pageCount) pageCount = total;
    }
    return pageCount;
  }

  List<Chapter> buildProvisionalChapterList(
    Novel novel, {
    int throughIndex = 0,
  }) {
    final bookId = _extractBookId(novel.chapterUrl) ?? _extractBqgId(novel.id);
    if (bookId == null) return const [];
    final origin = _originOf(novel.chapterUrl).isNotEmpty
        ? _originOf(novel.chapterUrl)
        : _bqgPrimaryOrigin;
    final count = (throughIndex + 1).clamp(1, 20000).toInt();
    return List<Chapter>.generate(
      count,
      (index) => Chapter(
        id: '${novel.id}_ch$index',
        novelId: novel.id,
        title: '第${index + 1}章（目录加载中）',
        index: index,
        url: '$origin/#/book/$bookId/${index + 1}.html',
      ),
      growable: false,
    );
  }

  Future<List<Chapter>> _getApiChapterList(Novel novel) async {
    final bookId = _extractBookId(novel.chapterUrl) ?? _extractBqgId(novel.id);
    if (bookId == null) return const [];

    final meta = await _getBookApiMeta(novel, bookId);
    if (meta == null) return const [];
    final origins = <String>{
      meta.baseUrl,
      ...await _bqgOriginCandidates(novel.chapterUrl),
    };
    for (final baseUrl in origins) {
      try {
        final listResponse = await _get(
          Uri.parse('$baseUrl/api/booklist?id=${meta.dirId}'),
          headers: _headers(baseUrl),
        ).timeout(const Duration(seconds: 10));
        if (listResponse.statusCode != 200) continue;
        await _rememberBqgResponseOrigin(listResponse);
        final listBaseUrl = _originOfResponse(listResponse, fallback: baseUrl);

        final listData = jsonDecode(_decodeBody(listResponse));
        final rawList = listData is Map ? listData['list'] : null;
        if (rawList is! List) continue;

        final chapters = <Chapter>[];
        for (final item in rawList) {
          final title = item.toString().trim();
          if (title.isEmpty) continue;
          final chapterId = chapters.length + 1;
          chapters.add(
            Chapter(
              id: '${novel.id}_ch${chapters.length}',
              novelId: novel.id,
              title: title,
              index: chapters.length,
              url: '$listBaseUrl/#/book/$bookId/$chapterId.html',
            ),
          );
        }
        if (chapters.isNotEmpty) return chapters;
      } catch (_) {
        continue;
      }
    }
    return const [];
  }

  String? _extractBookId(String url) {
    final patterns = [
      RegExp(r'/#/book/(\d+)/?'),
      RegExp(r'/book/(\d+)/?'),
      RegExp(r'[?&]id=(\d+)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String? _extractBqgId(String novelId) {
    final match = RegExp(r'_bqg_(\d+)$').firstMatch(novelId);
    return match?.group(1);
  }

  String _originOf(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        return '${uri.scheme}://${uri.host}';
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  List<Chapter> _extractChapterLinks(
    String html,
    String novelId,
    String chapterListUrl,
  ) {
    final chapters = <Chapter>[];
    try {
      final bookId = RegExp(
        r'/book/(\d+)/',
      ).firstMatch(chapterListUrl)?.group(1);
      final listMatch = RegExp(
        r"""<(?:div|dl|ul)[^>]*(?:id|class)=["'][^"']*(?:list|chapter|catalog|dir|volume|listmain)[^"']*["'][^>]*>(.*?)</(?:div|dl|ul)>""",
        dotAll: true,
        caseSensitive: false,
      ).firstMatch(html);
      final listHtml = listMatch?.group(1) ?? html;
      final pattern = RegExp(
        r"""<a[^>]*href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>""",
        dotAll: true,
        caseSensitive: false,
      );

      final seen = <String>{};
      for (final match in pattern.allMatches(listHtml)) {
        final url = match.group(1) ?? '';
        final title = _cleanHtmlText(match.group(2) ?? '');
        if (!_isChapterLink(url, title, bookId) || !seen.add(url)) continue;

        chapters.add(
          Chapter(
            id: '${novelId}_ch${chapters.length}',
            novelId: novelId,
            title: title,
            index: chapters.length,
            url: _normalizeUrl(chapterListUrl, url),
          ),
        );
      }
    } catch (_) {
      return const [];
    }
    return chapters;
  }

  bool _isChapterLink(String url, String title, String? bookId) {
    if (url.isEmpty || title.isEmpty) return false;
    final normalizedTitle = title.replaceAll(RegExp(r'\s+'), '');
    if (RegExp(
      r'(expand|all chapters|start reading|add to shelf|\u5c55\u5f00|\u5168\u90e8\u7ae0\u8282|\u5f00\u59cb\u9605\u8bfb|\u52a0\u5165\u4e66\u67b6)',
      caseSensitive: false,
    ).hasMatch(normalizedTitle)) {
      return false;
    }
    if (bookId != null && !RegExp('/book/$bookId/\\d+\\.html').hasMatch(url)) {
      return false;
    }
    return RegExp(
          r'(\u7b2c.{1,12}\u7ae0|\u7ae0\u8282|\u6954\u5b50|\u5e8f\u7ae0|\u756a\u5916|\u540e\u8bb0)',
        ).hasMatch(normalizedTitle) ||
        RegExp(r'/\d+\.html?$').hasMatch(url);
  }

  Future<String> getChapterContent(Chapter chapter, BookSource source) async {
    if (isWenku8Source(source) ||
        _isKnownWenku8Host(Uri.tryParse(chapter.url)?.host ?? '')) {
      return _getWenku8ChapterContent(chapter, source);
    }

    final apiContent = await _getApiChapterContent(chapter);
    if (apiContent.isNotEmpty) return apiContent;

    for (final url in await _chapterContentUrlCandidates(source, chapter.url)) {
      try {
        final baseUrl = _originOf(url).isEmpty
            ? source.baseUrl
            : _originOf(url);
        final response = await _get(
          Uri.parse(url),
          headers: _headers(baseUrl),
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          await _rememberBqgResponseOrigin(response);
          final content = _extractContent(_decodeBody(response));
          if (content.isNotEmpty) return content;
        }
      } catch (_) {
        continue;
      }
    }
    return '';
  }

  Future<String> _getWenku8ChapterContent(
    Chapter chapter,
    BookSource source,
  ) async {
    final bookId = _extractWenku8BookId(chapter.url);
    final chapterId = RegExp(
      r'[?&]cid=(\d+)',
    ).firstMatch(chapter.url)?.group(1);
    if (bookId == null || chapterId == null) return '';

    final origins = <String>{
      ..._wenku8OriginCandidates(chapter.url),
      ..._wenku8OriginCandidates(source.baseUrl),
    };
    for (final origin in origins) {
      try {
        final firstResponse = await _get(
          Uri.parse(
            '$origin/wap/article/readchapter.php?aid=$bookId&cid=$chapterId',
          ),
          headers: _headers('$origin/wap/article/readbook.php?aid=$bookId'),
        ).timeout(const Duration(seconds: 15));
        if (firstResponse.statusCode != 200) continue;

        final firstPage = _decodeBody(firstResponse);
        final responseOrigin = _originOfResponse(
          firstResponse,
          fallback: origin,
        );
        final contentPages = <String>[_parseWenku8ContentPage(firstPage)];
        final pageCount = _wenku8PageCount(firstPage).clamp(1, 200).toInt();
        var complete = true;
        for (var page = 2; page <= pageCount; page++) {
          final response = await _get(
            Uri.parse(
              '$responseOrigin/wap/article/readchapter.php?aid=$bookId&cid=$chapterId&page=$page',
            ),
            headers: _headers(
              '$responseOrigin/wap/article/readbook.php?aid=$bookId',
            ),
          ).timeout(const Duration(seconds: 15));
          if (response.statusCode != 200) {
            complete = false;
            break;
          }
          contentPages.add(_parseWenku8ContentPage(_decodeBody(response)));
        }
        if (!complete) continue;

        final content = contentPages
            .where((page) => page.isNotEmpty)
            .join('\n\n')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trim();
        if (content.isNotEmpty) return content;
      } catch (_) {
        continue;
      }
    }
    return '';
  }

  String _parseWenku8ContentPage(String wml) {
    final paragraph = RegExp(
      r'<p[^>]*>(.*?)</p>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(wml)?.group(1);
    if (paragraph == null || paragraph.isEmpty) return '';
    final paragraphHtml = paragraph;

    final output = <String>[];
    var passedFirstPager = false;
    for (var rawLine in paragraphHtml.split(
      RegExp(r'<br\s*/?>', caseSensitive: false),
    )) {
      final plainLine = _cleanHtmlText(rawLine);
      final isPager = RegExp(r'\[\d+\s*/\s*\d+\]').hasMatch(plainLine);
      if (isPager) {
        if (!passedFirstPager) {
          passedFirstPager = true;
          continue;
        }
        break;
      }
      if (!passedFirstPager) continue;

      rawLine = rawLine.replaceAllMapped(
        RegExp(
          r'''<img[^>]*src=["']([^"']+)["'][^>]*>''',
          caseSensitive: false,
        ),
        (match) =>
            '\n[插图] ${_secureWenku8Url(_wenku8PrimaryOrigin, match.group(1)!)}',
      );
      final text = html_parser.parseFragment(rawLine).text ?? '';
      final normalizedText = text.replaceAll('\u00a0', ' ').trim();
      output.add(normalizedText);
    }
    return output.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  Future<String> _getApiChapterContent(Chapter chapter) async {
    final bookId = _extractBookId(chapter.url);
    final chapterId = _extractChapterId(chapter.url);
    if (bookId == null || chapterId == null) return '';

    final token = _bqgToken({'id': int.parse(bookId), 'chapterid': chapterId});
    for (final baseUrl in await _bqgChapterApiOriginCandidates(chapter.url)) {
      try {
        final response = await _get(
          Uri.parse('$baseUrl/api/chapter?token=${Uri.encodeComponent(token)}'),
          headers: _headers(baseUrl),
        ).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) continue;
        if (_isKnownBqgHost(Uri.parse(baseUrl).host)) {
          await _rememberBqgResponseOrigin(response);
        }

        final data = jsonDecode(_decodeBody(response));
        if (data is! Map) continue;
        final txt = (data['txt'] ?? '').toString().trim();
        if (txt.isEmpty) continue;
        return _cleanChapterText(txt.replaceAll('\n', '\n\n'));
      } catch (_) {
        continue;
      }
    }
    return '';
  }

  int? _extractChapterId(String url) {
    final patterns = [
      RegExp(r'/#/book/\d+/(\d+)(?:_\d+)?\.html'),
      RegExp(r'/book/\d+/(\d+)(?:_\d+)?\.html'),
      RegExp(r'[?&]chapterid=(\d+)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match == null) continue;
      return int.tryParse(match.group(1) ?? '');
    }
    return null;
  }

  String _bqgToken(Map<String, int> params) {
    final code = crypto.md5.convert(utf8.encode('book@token.html')).toString();
    final iv = encrypt.IV.fromUtf8(code.substring(0, 16));
    final key = encrypt.Key.fromUtf8(code.substring(16));
    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
    );
    return encrypter.encrypt(jsonEncode(params), iv: iv).base64;
  }

  Future<List<String>> _chapterContentUrlCandidates(
    BookSource source,
    String rawUrl,
  ) async {
    final candidates = <String>[];
    void add(String url) {
      if (url.isNotEmpty && !candidates.contains(url)) candidates.add(url);
    }

    final baseUrls = _isBqgApiSource(source)
        ? await _bqgOriginCandidates(source.baseUrl)
        : <String>[
            if (_originOf(source.baseUrl).isNotEmpty) _originOf(source.baseUrl),
          ];
    for (final baseUrl in baseUrls) {
      add(_normalizeUrl(baseUrl, rawUrl));
      add(_normalizeHashRouteUrl(baseUrl, rawUrl));

      final hashIndex = rawUrl.indexOf('#/');
      if (hashIndex >= 0) {
        add(_normalizeUrl(baseUrl, rawUrl.substring(hashIndex + 1)));
      }
    }

    return candidates;
  }

  String _extractContent(String html) {
    final patterns = [
      RegExp(r"""<div[^>]*id=["']content["'][^>]*>(.*?)</div>""", dotAll: true),
      RegExp(
        r"""<div[^>]*class=["'][^"']*(?:content|read-content|chapter-content)[^"']*["'][^>]*>(.*?)</div>""",
        dotAll: true,
        caseSensitive: false,
      ),
      RegExp(
        r"""<div[^>]*id=["']chaptercontent["'][^>]*>(.*?)</div>""",
        dotAll: true,
      ),
      RegExp(r"""<div[^>]*id=["']text["'][^>]*>(.*?)</div>""", dotAll: true),
      RegExp(
        r'<article[^>]*>(.*?)</article>',
        dotAll: true,
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match == null) continue;
      final content = _cleanChapterText(match.group(1)!);
      if (!_isInvalidChapterContent(content)) return content;
    }

    var text = html
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), '')
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    if (text.length > 500) {
      final lines = text.split('\n');
      final contentLines = lines.where((l) => l.trim().length > 10).toList();
      if (contentLines.length > 5) text = contentLines.sublist(5).join('\n');
    }

    text = _cleanChapterText(text);
    return _isInvalidChapterContent(text) ? '' : text;
  }

  String _cleanChapterText(String text) {
    return text
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'^\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  bool _isInvalidChapterContent(String content) {
    final normalized = content.replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty) return true;
    return normalized.contains('api.ranmeng.icu') ||
        RegExp(
          r'(site maintenance|network connection|failed to get chapter|\u7b14\u8da3\u9601\u6211\u7684\u4e66\u67b6\u8054\u7cfb\u6211\u4eec|\u7ad9\u70b9\u7ef4\u62a4|\u68c0\u67e5\u7f51\u7edc|\u83b7\u53d6\u7ae0\u8282\u5185\u5bb9\u5931\u8d25)',
          caseSensitive: false,
        ).hasMatch(normalized);
  }
}

class _BqgBookApiMeta {
  _BqgBookApiMeta({
    required this.novel,
    required this.bookId,
    required this.dirId,
    required this.baseUrl,
  });

  final Novel novel;
  final String bookId;
  final String dirId;
  final String baseUrl;
}

class NovelHomeData {
  const NovelHomeData({
    required this.sourceName,
    required this.featured,
    required this.sections,
    required this.categories,
  });

  const NovelHomeData.empty()
    : sourceName = '',
      featured = const [],
      sections = const [],
      categories = const [];

  final String sourceName;
  final List<Novel> featured;
  final List<NovelHomeSection> sections;
  final List<NovelCategory> categories;

  bool get isEmpty => featured.isEmpty && sections.isEmpty;

  Map<String, dynamic> toJson() => {
    'sourceName': sourceName,
    'featured': featured.map((item) => item.toJson()).toList(),
    'sections': sections.map((section) => section.toJson()).toList(),
    'categories': categories.map((category) => category.toJson()).toList(),
  };

  factory NovelHomeData.fromJson(Map<String, dynamic> json) => NovelHomeData(
    sourceName: json['sourceName'] as String? ?? '',
    featured: (json['featured'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Novel.fromJson(item.cast<String, dynamic>()))
        .toList(),
    sections: (json['sections'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => NovelHomeSection.fromJson(item.cast<String, dynamic>()))
        .toList(),
    categories: (json['categories'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => NovelCategory.fromJson(item.cast<String, dynamic>()))
        .toList(),
  );
}

class NovelHomeSection {
  const NovelHomeSection({
    required this.title,
    required this.items,
    this.category = const NovelCategory.empty(),
  });

  final String title;
  final List<Novel> items;
  final NovelCategory category;

  bool get hasMore => !category.isEmpty;

  Map<String, dynamic> toJson() => {
    'title': title,
    'items': items.map((item) => item.toJson()).toList(),
    'category': category.toJson(),
  };

  factory NovelHomeSection.fromJson(Map<String, dynamic> json) {
    return NovelHomeSection(
      title: json['title'] as String? ?? '',
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => Novel.fromJson(item.cast<String, dynamic>()))
          .toList(),
      category: json['category'] is Map
          ? NovelCategory.fromJson(
              (json['category'] as Map).cast<String, dynamic>(),
            )
          : const NovelCategory.empty(),
    );
  }
}

class NovelCategory {
  const NovelCategory({
    required this.title,
    required this.url,
    required this.icon,
    required this.sourceId,
    required this.sourceName,
    required this.sourceBaseUrl,
    this.apiSort = '',
  });

  const NovelCategory.empty()
    : title = '',
      url = '',
      icon = '',
      sourceId = '',
      sourceName = '',
      sourceBaseUrl = '',
      apiSort = '';

  final String title;
  final String url;
  final String icon;
  final String sourceId;
  final String sourceName;
  final String sourceBaseUrl;
  final String apiSort;

  bool get isEmpty => title.isEmpty && url.isEmpty && apiSort.isEmpty;

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'icon': icon,
    'sourceId': sourceId,
    'sourceName': sourceName,
    'sourceBaseUrl': sourceBaseUrl,
    'apiSort': apiSort,
  };

  factory NovelCategory.fromJson(Map<String, dynamic> json) => NovelCategory(
    title: json['title'] as String? ?? '',
    url: json['url'] as String? ?? '',
    icon: json['icon'] as String? ?? '',
    sourceId: json['sourceId'] as String? ?? '',
    sourceName: json['sourceName'] as String? ?? '',
    sourceBaseUrl: json['sourceBaseUrl'] as String? ?? '',
    apiSort: json['apiSort'] as String? ?? '',
  );
}
