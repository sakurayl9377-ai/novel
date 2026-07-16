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
