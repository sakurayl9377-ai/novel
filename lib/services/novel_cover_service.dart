import 'interaction_auth_service.dart';

String wenku8CoverProxyUrl(String bookId) {
  final normalized = bookId.trim();
  if (!RegExp(r'^\d{1,9}$').hasMatch(normalized)) return '';
  return '${InteractionAuthService.baseUrl}/novel-covers/wenku8/$normalized';
}

String? wenku8ExternalCoverFallbackUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null) return null;
  String bookId = '';
  if (uri.host.toLowerCase() == 'img.wenku8.com') {
    bookId = RegExp(r'/image/\d+/(\d+)/').firstMatch(uri.path)?.group(1) ?? '';
  } else {
    bookId =
        RegExp(r'/novel-covers/wenku8/(\d+)$').firstMatch(uri.path)?.group(1) ??
        '';
  }
  if (!RegExp(r'^\d{1,9}$').hasMatch(bookId)) return null;
  final shard = (int.tryParse(bookId) ?? 0) ~/ 1000;
  final original = 'https://img.wenku8.com/image/$shard/$bookId/${bookId}s.jpg';
  return 'https://images.weserv.nl/?url=${Uri.encodeComponent(original)}&output=jpg';
}

String normalizeNovelCoverUrl(String rawUrl) {
  final normalized = rawUrl.trim();
  final uri = Uri.tryParse(normalized);
  if (uri == null || uri.host.toLowerCase() != 'img.wenku8.com') {
    return normalized;
  }
  final match = RegExp(r'/image/\d+/(\d+)/').firstMatch(uri.path);
  final bookId = match?.group(1) ?? '';
  final proxyUrl = wenku8CoverProxyUrl(bookId);
  return proxyUrl.isEmpty ? normalized : proxyUrl;
}
