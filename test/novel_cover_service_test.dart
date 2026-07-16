import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/novel_cover_service.dart';

void main() {
  test('legacy Wenku8 image URLs are routed through the backend cache', () {
    final normalized = normalizeNovelCoverUrl(
      'http://img.wenku8.com/image/4/4310/4310s.jpg',
    );

    expect(normalized, contains('/novel-covers/wenku8/4310'));
    expect(normalized, isNot(contains('img.wenku8.com')));
  });

  test('unrelated cover URLs are unchanged', () {
    const original = 'https://images.example/cover.jpg';
    expect(normalizeNovelCoverUrl(original), original);
  });

  test('builds a temporary external fallback for a backend Wenku8 URL', () {
    expect(
      wenku8ExternalCoverFallbackUrl(
        'https://api.example.com/api/novel-covers/wenku8/3508',
      ),
      'https://images.weserv.nl/?url=https%3A%2F%2Fimg.wenku8.com%2Fimage%2F3%2F3508%2F3508s.jpg&output=jpg',
    );
  });
}
