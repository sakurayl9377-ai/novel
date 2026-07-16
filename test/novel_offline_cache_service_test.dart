import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/chapter.dart';
import 'package:novel_app/models/content_progress.dart';
import 'package:novel_app/models/novel.dart';
import 'package:novel_app/services/novel_offline_cache_service.dart';

void main() {
  late Directory root;
  late NovelOfflineCacheService cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('novel-offline-cache-');
    cache = NovelOfflineCacheService(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('same novel id stays isolated across source-aware identities', () async {
    final sourceA = _novel(sourceId: 'source-a', host: 'a.example');
    final sourceB = _novel(sourceId: 'source-b', host: 'b.example');
    final chapterA = _chapter(sourceA, host: 'a.example');
    final chapterB = _chapter(sourceB, host: 'b.example');

    await cache.saveTemporaryChapterList(sourceA, <Map<String, dynamic>>[
      chapterA.toJson(),
    ]);
    await cache.saveTemporaryChapterList(sourceB, <Map<String, dynamic>>[
      chapterB.toJson(),
    ]);
    await cache.saveTemporaryChapterContent(sourceA, chapterA, 'source A');
    await cache.saveTemporaryChapterContent(sourceB, chapterB, 'source B');

    expect(
      cache.tempChapterListPath(sourceA),
      isNot(cache.tempChapterListPath(sourceB)),
    );
    expect(
      await cache.getTemporaryChapterContent(sourceA, chapterA),
      'source A',
    );
    expect(
      await cache.getTemporaryChapterContent(sourceB, chapterB),
      'source B',
    );
    expect(
      (await cache.getTemporaryChapterList(sourceA))!.single['url'],
      contains('a.example'),
    );
    expect(
      (await cache.getTemporaryChapterList(sourceB))!.single['url'],
      contains('b.example'),
    );
  });

  test(
    'legacy cache migrates only after novel and chapter validation',
    () async {
      final sourceA = _novel(sourceId: 'source-a', host: 'a.example');
      final chapterA = _chapter(sourceA, host: 'a.example');
      final sourceB = _novel(sourceId: 'source-b', host: 'b.example');
      final chapterB = _chapter(sourceB, host: 'b.example');

      await File(
        _legacyListPath(root, sourceA.id),
      ).writeAsString(jsonEncode(<Map<String, dynamic>>[chapterA.toJson()]));
      await File(
        _legacyContentPath(root, sourceA.id, chapterA.id),
      ).writeAsString('validated legacy content');

      expect(
        await cache.getTemporaryChapterContent(sourceA, chapterA),
        'validated legacy content',
      );
      expect(
        await File(cache.tempChapterContentPath(sourceA, chapterA)).exists(),
        isTrue,
      );

      expect(await cache.getTemporaryChapterList(sourceB), isNull);
      expect(await cache.getTemporaryChapterContent(sourceB, chapterB), isNull);
      expect(
        await File(cache.tempChapterContentPath(sourceB, chapterB)).exists(),
        isFalse,
      );
    },
  );

  test(
    'content resolution prioritizes persistent, temporary, then network',
    () async {
      final novel = _novel(sourceId: 'source-a', host: 'a.example');
      final chapter = _chapter(novel, host: 'a.example');
      var networkLoads = 0;

      await cache.saveTemporaryChapterContent(novel, chapter, 'temporary');
      expect(
        await cache.resolveChapterContent(
          novel: novel,
          chapter: chapter,
          loadFromNetwork: () async {
            networkLoads += 1;
            return 'network';
          },
        ),
        'temporary',
      );
      expect(networkLoads, 0);

      await cache.saveDownloadedChapter(novel, chapter, 'persistent');
      expect(
        await cache.resolveChapterContent(
          novel: novel,
          chapter: chapter,
          loadFromNetwork: () async {
            networkLoads += 1;
            return 'network';
          },
        ),
        'persistent',
      );
      expect(networkLoads, 0);

      await cache.removeDownloadedChapter(novel, chapter.id);
      await cache.deleteTemporaryChapterContent(novel, chapter);
      expect(
        await cache.resolveChapterContent(
          novel: novel,
          chapter: chapter,
          loadFromNetwork: () async {
            networkLoads += 1;
            return 'network';
          },
        ),
        'network',
      );
      expect(networkLoads, 1);
      expect(await cache.getTemporaryChapterContent(novel, chapter), 'network');
    },
  );

  test(
    'moving current pin removes only the previous pin-only chapter',
    () async {
      final novel = _novel(sourceId: 'source-a', host: 'a.example');
      final downloaded = _chapter(novel, host: 'a.example', index: 0);
      final firstPin = _chapter(novel, host: 'a.example', index: 1);
      final nextPin = _chapter(novel, host: 'a.example', index: 2);

      await cache.saveDownloadedChapter(novel, downloaded, 'downloaded');
      await cache.pinChapter(novel, firstPin, 'first pin');
      await cache.pinChapter(novel, nextPin, 'next pin');

      var status = await cache.getStatus(novel);
      expect(status.downloadedChapterCount, 1);
      expect(status.pinnedChapterId, nextPin.id);
      expect(status.chapters.map((entry) => entry.chapterId), <String>[
        downloaded.id,
        nextPin.id,
      ]);
      expect(await cache.getPersistentChapterContent(novel, firstPin), isNull);
      expect(
        await cache.getPersistentChapterContent(novel, downloaded),
        'downloaded',
      );

      await cache.clearDownloadedChapters(novel);
      status = await cache.getStatus(novel);
      expect(status.downloadedChapterCount, 0);
      expect(status.chapters.single.chapterId, nextPin.id);

      await cache.clearPinnedChapter(novel);
      status = await cache.getStatus(novel);
      expect(status.retainedChapterCount, 0);
      expect(status.totalBytes, 0);
    },
  );

  test(
    'batch ranges are bounded and failed chapters remain retryable',
    () async {
      final novel = _novel(sourceId: 'source-a', host: 'a.example');
      final chapters = List<Chapter>.generate(
        60,
        (index) => _chapter(novel, host: 'a.example', index: index),
      );
      final progress = <NovelCacheBatchProgress>[];

      expect(
        NovelCacheBatchRange.next20.chapterIndices(
          chapterCount: chapters.length,
          startIndex: 50,
        ),
        List<int>.generate(9, (index) => index + 51),
      );
      expect(
        NovelCacheBatchRange.next50.chapterIndices(
          chapterCount: chapters.length,
          startIndex: 20,
        ),
        List<int>.generate(39, (index) => index + 21),
      );
      expect(
        NovelCacheBatchRange.full.chapterIndices(
          chapterCount: chapters.length,
          startIndex: 40,
        ),
        List<int>.generate(60, (index) => index),
      );

      final result = await cache.cacheBatch(
        novel: novel,
        chapters: chapters,
        chapterIndices: <int>[0, 1, 2],
        loadContent: (chapter) async =>
            chapter.index == 1 ? '' : 'chapter ${chapter.index}',
        onProgress: progress.add,
      );
      expect(result.requested, 3);
      expect(result.saved, 2);
      expect(result.failedChapterIds, <String>[chapters[1].id]);
      expect(progress, hasLength(3));
      expect((await cache.getStatus(novel)).downloadedChapterCount, 2);
    },
  );

  test(
    'digest mismatch prevents serving a corrupted persistent chapter',
    () async {
      final novel = _novel(sourceId: 'source-a', host: 'a.example');
      final chapter = _chapter(novel, host: 'a.example');
      await cache.saveDownloadedChapter(novel, chapter, 'original');

      final contentKey = ContentIdentity.novel(novel).contentKey;
      final manifestFile = File(
        '${cache.persistentRoot.path}${Platform.pathSeparator}$contentKey'
        '${Platform.pathSeparator}manifest.json',
      );
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final entries = manifest['chapters'] as Map<String, dynamic>;
      final entry = entries[chapter.id] as Map<String, dynamic>;
      final chapterFile = File(
        '${manifestFile.parent.path}${Platform.pathSeparator}${entry['fileName']}',
      );
      await chapterFile.writeAsString('tampered');

      expect(await cache.getPersistentChapterContent(novel, chapter), isNull);
    },
  );
}

Novel _novel({required String sourceId, required String host}) => Novel(
  id: 'shared-id',
  title: 'Test novel',
  sourceId: sourceId,
  chapterUrl: 'https://$host/book/1',
);

Chapter _chapter(Novel novel, {required String host, int index = 0}) => Chapter(
  id: '${novel.id}_ch$index',
  novelId: novel.id,
  title: 'Chapter $index',
  index: index,
  url: 'https://$host/book/1/${index + 1}.html',
);

String _legacyListPath(Directory root, String novelId) =>
    '${root.path}${Platform.pathSeparator}chapters_${_hash(novelId)}.json';

String _legacyContentPath(Directory root, String novelId, String chapterId) =>
    '${root.path}${Platform.pathSeparator}'
    'content_${_hash('$novelId::$chapterId')}.txt';

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
