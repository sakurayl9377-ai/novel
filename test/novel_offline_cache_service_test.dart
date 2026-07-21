import 'dart:async';
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

  test('batch persists the complete catalog before downloading', () async {
    final novel = _novel(sourceId: 'source-a', host: 'a.example');
    final chapters = List<Chapter>.generate(
      3,
      (index) => _chapter(novel, host: 'a.example', index: index),
    );

    await cache.cacheBatch(
      novel: novel,
      chapters: chapters,
      chapterIndices: const <int>[0],
      loadContent: (chapter) async => 'chapter ${chapter.index}',
    );

    final restored = await cache.getPersistentChapterList(novel);
    expect(
      restored.map((chapter) => chapter.id),
      chapters.map((item) => item.id),
    );
    expect(restored.map((chapter) => chapter.index), <int>[0, 1, 2]);
    expect(
      restored.map((chapter) => chapter.url),
      chapters.map((item) => item.url),
    );
  });

  test(
    'batch downloads four chapters concurrently and persists every result',
    () async {
      final novel = _novel(sourceId: 'source-a', host: 'a.example');
      final chapters = List<Chapter>.generate(
        8,
        (index) => _chapter(novel, host: 'a.example', index: index),
      );
      final gates = <int, Completer<String>>{};
      final started = <int>[];
      final progress = <NovelCacheBatchProgress>[];
      var active = 0;
      var maxActive = 0;

      final batch = cache.cacheBatch(
        novel: novel,
        chapters: chapters,
        chapterIndices: List<int>.generate(chapters.length, (index) => index),
        loadContent: (chapter) {
          final gate = Completer<String>();
          gates[chapter.index] = gate;
          started.add(chapter.index);
          active += 1;
          if (active > maxActive) maxActive = active;
          return gate.future.whenComplete(() => active -= 1);
        },
        onProgress: progress.add,
      );

      await _waitFor(() => started.length == 4);
      expect(started.toSet(), <int>{0, 1, 2, 3});
      expect(active, 4);
      expect(maxActive, NovelOfflineCacheService.defaultMaxConcurrentDownloads);

      for (var index = 0; index < 4; index++) {
        gates[index]!.complete('chapter $index');
      }
      await _waitFor(() => started.length == chapters.length);
      expect(maxActive, 4);
      for (var index = 4; index < chapters.length; index++) {
        gates[index]!.complete('chapter $index');
      }

      final result = await batch;
      expect(result.complete, isTrue);
      expect(result.saved, chapters.length);
      expect(progress.map((item) => item.completed), <int>[
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);
      expect((await cache.getStatus(novel)).downloadedChapterCount, 8);
    },
  );

  test('parallel cancellation finishes in-flight chapters only', () async {
    final novel = _novel(sourceId: 'source-a', host: 'a.example');
    final chapters = List<Chapter>.generate(
      8,
      (index) => _chapter(novel, host: 'a.example', index: index),
    );
    final gates = <int, Completer<String>>{};
    final started = <int>[];
    var cancelRequested = false;

    final batch = cache.cacheBatch(
      novel: novel,
      chapters: chapters,
      chapterIndices: List<int>.generate(chapters.length, (index) => index),
      shouldCancel: () => cancelRequested,
      loadContent: (chapter) {
        started.add(chapter.index);
        final gate = Completer<String>();
        gates[chapter.index] = gate;
        return gate.future;
      },
    );

    await _waitFor(
      () =>
          started.length ==
          NovelOfflineCacheService.defaultMaxConcurrentDownloads,
    );
    cancelRequested = true;
    for (final chapterIndex in List<int>.of(started)) {
      gates[chapterIndex]!.complete('chapter $chapterIndex');
    }

    final result = await batch;
    expect(result.cancelled, isTrue);
    expect(result.saved, 4);
    expect(started, hasLength(4));
    expect((await cache.getStatus(novel)).downloadedChapterCount, 4);
  });

  test(
    'catalog refresh safely remaps unique chapters after insertion and URL changes',
    () async {
      final novel = _novel(sourceId: 'source-a', host: 'a.example');
      final original = <Chapter>[
        Chapter(
          id: '${novel.id}_ch0',
          novelId: novel.id,
          title: 'Alpha',
          index: 0,
          url: 'https://a.example/book/1/1.html',
        ),
        Chapter(
          id: '${novel.id}_ch1',
          novelId: novel.id,
          title: 'Beta',
          index: 1,
          url: 'https://a.example/book/1/2.html',
        ),
      ];
      await cache.savePersistentChapterList(novel, original);
      await cache.saveDownloadedChapter(novel, original[0], 'alpha body');
      await cache.saveDownloadedChapter(novel, original[1], 'beta body');

      final refreshed = <Chapter>[
        Chapter(
          id: '${novel.id}_ch0',
          novelId: novel.id,
          title: 'Inserted',
          index: 0,
          url: 'https://mirror.example/book/1/1.html',
        ),
        Chapter(
          id: '${novel.id}_ch1',
          novelId: novel.id,
          title: 'Alpha',
          index: 1,
          url: 'https://mirror.example/book/1/2.html',
        ),
        Chapter(
          id: '${novel.id}_ch2',
          novelId: novel.id,
          title: 'Beta',
          index: 2,
          url: 'https://mirror.example/book/1/3.html',
        ),
      ];

      expect(
        await cache.refreshPersistentChapterList(novel, refreshed),
        isTrue,
      );
      expect(
        (await cache.getPersistentChapterList(
          novel,
        )).map((chapter) => (chapter.id, chapter.title, chapter.url)),
        refreshed.map((chapter) => (chapter.id, chapter.title, chapter.url)),
      );
      expect(
        await cache.getPersistentChapterContent(novel, refreshed[0]),
        isNull,
      );
      expect(
        await cache.getPersistentChapterContent(novel, refreshed[1]),
        'alpha body',
      );
      expect(
        await cache.getPersistentChapterContent(novel, refreshed[2]),
        'beta body',
      );

      await cache.saveDownloadedChapter(novel, refreshed[0], 'inserted body');
      expect(
        await cache.getPersistentChapterContent(novel, refreshed[0]),
        'inserted body',
      );
      expect(
        await cache.getPersistentChapterContent(novel, refreshed[1]),
        'alpha body',
      );
      expect((await cache.getStatus(novel)).downloadedChapterCount, 3);
    },
  );

  test('catalog refresh rejects ambiguous duplicate-title remapping', () async {
    final novel = _novel(sourceId: 'source-a', host: 'a.example');
    final original = <Chapter>[
      Chapter(
        id: '${novel.id}_ch0',
        novelId: novel.id,
        title: 'Interlude',
        index: 0,
        url: 'https://a.example/book/1/1.html',
      ),
      Chapter(
        id: '${novel.id}_ch1',
        novelId: novel.id,
        title: 'Interlude',
        index: 1,
        url: 'https://a.example/book/1/2.html',
      ),
    ];
    await cache.savePersistentChapterList(novel, original);
    await cache.saveDownloadedChapter(novel, original[0], 'first interlude');
    await cache.saveDownloadedChapter(novel, original[1], 'second interlude');

    final refreshed = <Chapter>[
      Chapter(
        id: '${novel.id}_ch0',
        novelId: novel.id,
        title: 'Interlude',
        index: 0,
        url: 'https://mirror.example/book/1/1.html',
      ),
      Chapter(
        id: '${novel.id}_ch1',
        novelId: novel.id,
        title: 'Interlude',
        index: 1,
        url: 'https://mirror.example/book/1/2.html',
      ),
      Chapter(
        id: '${novel.id}_ch2',
        novelId: novel.id,
        title: 'Interlude',
        index: 2,
        url: 'https://mirror.example/book/1/3.html',
      ),
    ];

    await cache.refreshPersistentChapterList(novel, refreshed);

    expect(
      await cache.getPersistentChapterContent(novel, refreshed[0]),
      isNull,
    );
    expect(
      await cache.getPersistentChapterContent(novel, refreshed[1]),
      isNull,
    );
    expect((await cache.getStatus(novel)).downloadedChapterCount, 0);
  });

  test('batch cancellation stops at the next chapter boundary', () async {
    final novel = _novel(sourceId: 'source-a', host: 'a.example');
    final chapters = List<Chapter>.generate(
      3,
      (index) => _chapter(novel, host: 'a.example', index: index),
    );
    final loaded = <int>[];
    var cancelRequested = false;

    final result = await cache.cacheBatch(
      novel: novel,
      chapters: chapters,
      chapterIndices: const <int>[0, 1, 2],
      maxConcurrentDownloads: 1,
      shouldCancel: () => cancelRequested,
      loadContent: (chapter) async {
        loaded.add(chapter.index);
        cancelRequested = true;
        return 'chapter ${chapter.index}';
      },
    );

    expect(result.cancelled, isTrue);
    expect(result.saved, 1);
    expect(result.skipped, 0);
    expect(loaded, <int>[0]);
    expect((await cache.getStatus(novel)).downloadedChapterCount, 1);
  });

  test('retry skips intact chapters and downloads only missing ones', () async {
    final novel = _novel(sourceId: 'source-a', host: 'a.example');
    final chapters = List<Chapter>.generate(
      2,
      (index) => _chapter(novel, host: 'a.example', index: index),
    );
    final firstLoads = <int>[];
    final first = await cache.cacheBatch(
      novel: novel,
      chapters: chapters,
      chapterIndices: const <int>[0, 1],
      loadContent: (chapter) async {
        firstLoads.add(chapter.index);
        return chapter.index == 0 ? 'chapter 0' : '';
      },
    );
    expect(first.failedChapterIds, <String>[chapters[1].id]);

    final retryLoads = <int>[];
    final retry = await cache.cacheBatch(
      novel: novel,
      chapters: chapters,
      chapterIndices: const <int>[0, 1],
      loadContent: (chapter) async {
        retryLoads.add(chapter.index);
        return 'chapter ${chapter.index}';
      },
    );

    expect(firstLoads, <int>[0, 1]);
    expect(retryLoads, <int>[1]);
    expect(retry.saved, 2);
    expect(retry.skipped, 1);
    expect(retry.complete, isTrue);
  });

  test('batch promotes a pinned chapter to a durable download', () async {
    final novel = _novel(sourceId: 'source-a', host: 'a.example');
    final chapters = List<Chapter>.generate(
      2,
      (index) => _chapter(novel, host: 'a.example', index: index),
    );
    await cache.pinChapter(novel, chapters[0], 'pinned chapter 0');
    final loaded = <int>[];

    final result = await cache.cacheBatch(
      novel: novel,
      chapters: chapters,
      chapterIndices: const <int>[0, 1],
      loadContent: (chapter) async {
        loaded.add(chapter.index);
        return 'chapter ${chapter.index}';
      },
    );

    expect(result.complete, isTrue);
    expect(result.skipped, 1);
    expect(loaded, <int>[1]);
    expect((await cache.getStatus(novel)).downloadedChapterCount, 2);

    await cache.pinChapter(novel, chapters[1], 'chapter 1');
    expect(
      await cache.getPersistentChapterContent(novel, chapters[0]),
      'pinned chapter 0',
    );
    expect((await cache.getStatus(novel)).downloadedChapterCount, 2);
  });

  test(
    'manifest restores a valid backup when the primary is corrupt',
    () async {
      final novel = _novel(sourceId: 'source-a', host: 'a.example');
      final chapter = _chapter(novel, host: 'a.example');
      await cache.saveDownloadedChapter(novel, chapter, 'recoverable content');

      final manifest = _manifestFile(root, novel);
      final backup = File('${manifest.path}.bak');
      await manifest.copy(backup.path);
      await manifest.writeAsString('{broken json', flush: true);

      expect(
        await cache.getPersistentChapterContent(novel, chapter),
        'recoverable content',
      );
      expect(await manifest.exists(), isTrue);
      expect(jsonDecode(await manifest.readAsString()), isA<Map>());
    },
  );

  test('manifest restores a completed temporary file after a crash', () async {
    final novel = _novel(sourceId: 'source-a', host: 'a.example');
    final chapter = _chapter(novel, host: 'a.example');
    await cache.saveDownloadedChapter(novel, chapter, 'temporary recovery');

    final manifest = _manifestFile(root, novel);
    final temporary = File('${manifest.path}.9999999999999999.tmp');
    await manifest.copy(temporary.path);
    await manifest.delete();

    expect((await cache.getStatus(novel)).downloadedChapterCount, 1);
    expect(await manifest.exists(), isTrue);
    expect(await temporary.exists(), isFalse);
  });

  test('status excludes missing or corrupted persistent files', () async {
    final novel = _novel(sourceId: 'source-a', host: 'a.example');
    final chapters = List<Chapter>.generate(
      2,
      (index) => _chapter(novel, host: 'a.example', index: index),
    );
    await cache.saveDownloadedChapter(novel, chapters[0], 'first');
    await cache.saveDownloadedChapter(novel, chapters[1], 'second');

    final manifestFile = _manifestFile(root, novel);
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final entries = manifest['chapters'] as Map<String, dynamic>;
    final firstEntry = entries[chapters[0].id] as Map<String, dynamic>;
    final secondEntry = entries[chapters[1].id] as Map<String, dynamic>;
    await File(
      '${manifestFile.parent.path}${Platform.pathSeparator}${firstEntry['fileName']}',
    ).delete();
    await File(
      '${manifestFile.parent.path}${Platform.pathSeparator}${secondEntry['fileName']}',
    ).writeAsString('tampered');

    final status = await cache.getStatus(novel);
    expect(status.downloadedChapterCount, 0);
    expect(status.retainedChapterCount, 0);
    expect(status.totalBytes, 0);
  });

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

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for asynchronous cache work.');
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

File _manifestFile(Directory root, Novel novel) {
  final contentKey = ContentIdentity.novel(novel).contentKey;
  return File(
    '${root.path}${Platform.pathSeparator}novel_offline_v1'
    '${Platform.pathSeparator}$contentKey${Platform.pathSeparator}manifest.json',
  );
}
