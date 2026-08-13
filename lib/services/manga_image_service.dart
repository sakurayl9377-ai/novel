const String _stableBaoziAssetHost = 'static-tw.bzmgcn.com';

const Set<String> _baoziAssetHosts = {
  'static-tw.bzmgcn.com',
  'static-tw.cnbzmg.com',
  'static-tw.baozimh.com',
  'static-tw.twbzmg.com',
  'static.bzmgcn.com',
  'static.cnbzmg.com',
  'static.baozimh.com',
  'static.twbzmg.com',
  // The chapter endpoint now serves page images from the bzcdn CDN. Keep
  // those URLs on the same stable asset host used by the older Baozi CDNs.
  's1.bzcdn.net',
  's2.bzcdn.net',
  's3.bzcdn.net',
  's4.bzcdn.net',
};

String normalizeMangaImageUrl(
  String rawUrl, {
  bool preferStableBaoziHost = false,
}) {
  var value = rawUrl.replaceAll('&amp;', '&').trim();
  if (value.startsWith('//')) value = 'https:$value';

  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return '';
  }

  var normalized = uri.removeFragment();
  if (preferStableBaoziHost && _baoziAssetHosts.contains(uri.host)) {
    normalized = normalized.replace(
      scheme: 'https',
      host: _stableBaoziAssetHost,
      port: null,
    );
  }
  return normalized.toString();
}

List<String> mangaImageCandidates(String rawUrl) {
  final original = normalizeMangaImageUrl(rawUrl);
  if (original.isEmpty) return const [];

  final candidates = <String>[original];
  final uri = Uri.parse(original);
  if (_baoziAssetHosts.contains(uri.host) &&
      uri.host != _stableBaoziAssetHost) {
    candidates.add(
      uri
          .replace(scheme: 'https', host: _stableBaoziAssetHost, port: null)
          .toString(),
    );
  }
  return List.unmodifiable(candidates);
}

Map<String, String> mangaImageHeaders({
  String imageUrl = '',
  String referer = '',
}) {
  final uri = Uri.tryParse(imageUrl);
  final origin = uri == null || uri.host.isEmpty
      ? ''
      : '${uri.scheme}://${uri.host}/';
  return {
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    'Referer': referer.isNotEmpty
        ? referer
        : origin.isNotEmpty
        ? origin
        : 'https://cn.bzmgcn.com/',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
  };
}

List<String> normalizeMangaChapterImageSequence(Iterable<String> images) {
  final urls = <String>[];
  for (final rawUrl in images) {
    // Migrate chapter URLs cached before the source switched from bzcdn to
    // the stable Baozi asset CDN. The reader uses a single ImageProvider, so
    // this normalization must happen before the URL reaches the reader.
    final url = normalizeMangaImageUrl(
      rawUrl,
      preferStableBaoziHost: _isBzcdnUrl(rawUrl),
    );
    if (url.isEmpty) continue;
    urls.add(url);
  }

  if (urls.length < 6 || urls.length.isOdd) return urls;
  final half = urls.length ~/ 2;
  for (var index = 0; index < half; index++) {
    if (_mangaImageIdentity(urls[index]) !=
        _mangaImageIdentity(urls[index + half])) {
      return urls;
    }
  }
  return urls.sublist(0, half);
}

bool _isBzcdnUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  return uri != null && uri.host.toLowerCase().endsWith('.bzcdn.net');
}

String _mangaImageIdentity(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  return Uri.decodeComponent(uri.path).toLowerCase();
}
