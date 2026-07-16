import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/book_source.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/providers/book_source_provider.dart';
import 'package:novel_app/services/book_source_service.dart';

void main() {
  test(
    'aggregate search emits the fastest source before all complete',
    () async {
      final provider = BookSourceProvider.forTesting(
        sources: [
          BookSourceService.bqg995Source,
          BookSourceService.wenku8Source,
        ],
        selectedSourceId: BookSourceService.wenku8Source.id,
        sourceService: _FakeSourceService(),
      );

      final stopwatch = Stopwatch()..start();
      final emissions = <List<Novel>>[];
      Duration? firstEmissionAt;
      await provider.searchBooks(
        '败北女角',
        allSources: true,
        onResults: (items) {
          firstEmissionAt ??= stopwatch.elapsed;
          emissions.add(items);
        },
      );

      expect(emissions, isNotEmpty);
      expect(
        emissions.first.single.sourceId,
        BookSourceService.wenku8Source.id,
      );
      expect(emissions.last.map((item) => item.sourceId).toSet(), {
        BookSourceService.wenku8Source.id,
        BookSourceService.bqg995Source.id,
      });
      expect(provider.searchResults, hasLength(2));
      expect(firstEmissionAt, lessThan(const Duration(milliseconds: 150)));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );
}

class _FakeSourceService extends BookSourceService {
  @override
  Future<List<BookSource>> ensureBuiltinSources() async => [
    BookSourceService.bqg995Source,
    BookSourceService.wenku8Source,
  ];

  @override
  Future<List<Novel>> searchBooks(String keyword, {String? sourceId}) async {
    if (sourceId == BookSourceService.wenku8Source.id) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return [
        Novel(
          id: 'wenku8-fast',
          title: keyword,
          sourceId: sourceId!,
          sourceName: BookSourceService.wenku8Source.name,
        ),
      ];
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    return [
      Novel(
        id: 'bqg-slower',
        title: keyword,
        sourceId: BookSourceService.bqg995Source.id,
        sourceName: BookSourceService.bqg995Source.name,
      ),
    ];
  }
}
