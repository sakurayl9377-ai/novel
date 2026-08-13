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
  final sourceUrls = <String>[];
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
    sourceUrls.add(rawUrl.trim());
  }

  if (urls.length < 2) return urls;

  for (final repeatCount in const [3, 2]) {
    if (repeatCount > urls.length) continue;
    if (urls.length % repeatCount != 0) continue;
    final blockLength = urls.length ~/ repeatCount;
    var matches = true;
    for (var index = blockLength; index < urls.length; index++) {
      if (mangaImageIdentity(urls[index]) !=
          mangaImageIdentity(urls[index % blockLength])) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;

    var everyPassUsesAlternateRepresentations = true;
    for (var pass = 1; pass < repeatCount; pass++) {
      for (var index = 0; index < blockLength; index++) {
        if (sourceUrls[(pass * blockLength) + index] == sourceUrls[index]) {
          everyPassUsesAlternateRepresentations = false;
          break;
        }
      }
      if (!everyPassUsesAlternateRepresentations) break;
    }
    if (!everyPassUsesAlternateRepresentations) continue;
    return urls.sublist(0, blockLength);
  }
  return urls;
}

bool _isBzcdnUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  return uri != null && uri.host.toLowerCase().endsWith('.bzcdn.net');
}

int appendMangaChapterImagePage(
  List<String> chapterImages,
  Iterable<String> rawPageImages,
) {
  final pageImages = normalizeMangaChapterImageSequence(rawPageImages);
  if (pageImages.isEmpty) return 0;
  if (chapterImages.isEmpty) {
    chapterImages.addAll(pageImages);
    return pageImages.length;
  }

  var overlap = chapterImages.length < pageImages.length
      ? chapterImages.length
      : pageImages.length;
  while (overlap > 0) {
    var matches = true;
    final chapterStart = chapterImages.length - overlap;
    for (var index = 0; index < overlap; index++) {
      if (mangaImageIdentity(chapterImages[chapterStart + index]) !=
          mangaImageIdentity(pageImages[index])) {
        matches = false;
        break;
      }
    }
    if (matches) break;
    overlap -= 1;
  }

  final trimmedOverlap = overlap == pageImages.length || overlap >= 2
      ? overlap
      : 0;
  chapterImages.addAll(pageImages.skip(trimmedOverlap));
  return pageImages.length - trimmedOverlap;
}

String mangaImageIdentity(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  return Uri.decodeComponent(uri.path).toLowerCase();
}
