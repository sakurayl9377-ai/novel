import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/widgets/continuous_chapter_view.dart';

void main() {
  test(
    'estimates visible text offset when paragraph render is unavailable',
    () {
      final offset = estimateTextOffsetFromSection(
        contentLength: 2000,
        sectionTop: -300,
        sectionHeight: 1200,
        viewportAnchor: 300,
      );

      expect(offset, 1000);
    },
  );

  test('estimated text offset is clamped to chapter bounds', () {
    expect(
      estimateTextOffsetFromSection(
        contentLength: 800,
        sectionTop: 500,
        sectionHeight: 1000,
        viewportAnchor: 300,
      ),
      0,
    );
    expect(
      estimateTextOffsetFromSection(
        contentLength: 800,
        sectionTop: -1500,
        sectionHeight: 1000,
        viewportAnchor: 300,
      ),
      800,
    );
  });
}
