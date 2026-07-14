import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/widgets/wuhandky_cover_image.dart';

void main() {
  test('creates an http fallback for an https cover', () {
    expect(
      WuhandkyCoverImage.httpFallbackFor('https://pic.example.com/cover.jpg'),
      'http://pic.example.com/cover.jpg',
    );
  });
}
