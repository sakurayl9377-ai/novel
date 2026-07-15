import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/manga_offline_manifest.dart';

void main() {
  late Directory directory;

  List<int> ftypBox({
    required String majorBrand,
    required List<String> compatibleBrands,
  }) {
    const size = 32;
    final bytes = List<int>.filled(size, 0);
    bytes.setAll(0, [0, 0, 0, size]);
    bytes.setAll(4, ascii.encode('ftyp'));
    bytes.setAll(8, ascii.encode(majorBrand));
    var offset = 16;
    for (final brand in compatibleBrands) {
      if (offset + 4 > bytes.length) break;
      bytes.setAll(offset, ascii.encode(brand));
      offset += 4;
    }
    return bytes;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('manga_offline_test_');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('validates every page in a persisted offline chapter', () async {
    final pageOne = File('${directory.path}/pages/page_000000.jpg');
    final pageTwo = File('${directory.path}/pages/page_000001.webp');
    await pageOne.parent.create(recursive: true);
    await pageOne.writeAsBytes([0xff, 0xd8, 0xff, 0xd9], flush: true);
    await pageTwo.writeAsBytes([
      0x52,
      0x49,
      0x46,
      0x46,
      4,
      0,
      0,
      0,
      0x57,
      0x45,
      0x42,
      0x50,
    ], flush: true);
    final manifestFile = File('${directory.path}/chapter.json');
    await writeMangaOfflineManifest(
      manifestFile,
      MangaOfflineManifest(
        chapterUrl: 'https://example.com/chapter/1',
        sources: [
          'https://images.example.com/1.jpg',
          'https://images.example.com/2.webp',
        ],
        sourceDigests: const [
          'https://images.example.com/1.jpg',
          'https://images.example.com/2.webp',
        ].map(mangaOfflineSourceDigest).toList(),
        files: const ['pages/page_000000.jpg', 'pages/page_000001.webp'],
      ),
    );

    final pages = await validateMangaOfflineArchive(
      manifestFile: manifestFile,
      allowedRoot: directory,
      expectedChapterUrl: 'https://example.com/chapter/1',
      expectedPageCount: 2,
    );

    expect(pages.map((path) => File(path).absolute.uri), [
      pageOne.absolute.uri,
      pageTwo.absolute.uri,
    ]);

    await pageTwo.delete();
    expect(
      await validateMangaOfflineArchive(
        manifestFile: manifestFile,
        allowedRoot: directory,
        expectedChapterUrl: 'https://example.com/chapter/1',
        expectedPageCount: 2,
      ),
      isEmpty,
    );
  });

  test('rejects manifest paths that escape the download directory', () async {
    final outside = File('${directory.parent.path}/outside-manga-page.jpg');
    await outside.writeAsBytes([0xff, 0xd8, 0xff, 0xd9], flush: true);
    addTearDown(() async {
      if (await outside.exists()) await outside.delete();
    });
    final manifestFile = File('${directory.path}/chapter.json');
    await writeMangaOfflineManifest(
      manifestFile,
      MangaOfflineManifest(
        chapterUrl: 'https://example.com/chapter/1',
        sources: ['https://images.example.com/1.jpg'],
        sourceDigests: [
          mangaOfflineSourceDigest('https://images.example.com/1.jpg'),
        ],
        files: const ['../outside-manga-page.jpg'],
      ),
    );

    expect(
      await validateMangaOfflineArchive(
        manifestFile: manifestFile,
        allowedRoot: directory,
        expectedChapterUrl: 'https://example.com/chapter/1',
        expectedPageCount: 1,
      ),
      isEmpty,
    );
  });

  test('rejects truncated images and MP4 files disguised as AVIF', () async {
    final truncatedJpeg = File('${directory.path}/truncated.jpg');
    await truncatedJpeg.writeAsBytes([0xff, 0xd8, 0xff, 1, 2, 3]);
    expect(await isLikelyMangaImageFile(truncatedJpeg), isFalse);

    final disguisedMp4 = File('${directory.path}/disguised.avif');
    await disguisedMp4.writeAsBytes(
      ftypBox(majorBrand: 'isom', compatibleBrands: ['mp42']),
    );
    expect(await isLikelyMangaImageFile(disguisedMp4), isFalse);

    final compatibleAvif = File('${directory.path}/compatible.avif');
    await compatibleAvif.writeAsBytes(
      ftypBox(majorBrand: 'isom', compatibleBrands: ['avif']),
    );
    expect(await isLikelyMangaImageFile(compatibleAvif), isTrue);
  });

  test(
    'reuses pages only when the persisted source digest still matches',
    () async {
      const unchangedSource = 'https://images.example.com/unchanged.jpg';
      const staleSource = 'https://images.example.com/stale.jpg';
      const refreshedSource = 'https://images.example.com/refreshed.jpg';
      const unchangedFile = 'pages/page_000000.jpg';
      const changedFile = 'pages/page_000001.jpg';
      final unchangedPage = File('${directory.path}/$unchangedFile');
      final stalePage = File('${directory.path}/$changedFile');
      final stalePartial = File('${stalePage.path}.part');
      await unchangedPage.parent.create(recursive: true);
      await unchangedPage.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
      await stalePage.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);
      await stalePartial.writeAsBytes([0xff, 0xd8]);

      final previous = MangaOfflineManifest(
        chapterUrl: 'https://example.com/chapter/1',
        sources: const [unchangedSource, staleSource],
        sourceDigests: [
          mangaOfflineSourceDigest(unchangedSource),
          mangaOfflineSourceDigest(staleSource),
        ],
        files: const [unchangedFile, changedFile],
      );

      await discardMismatchedMangaOfflinePages(
        downloadDirectory: directory,
        previousManifest: previous,
        chapterUrl: 'https://example.com/chapter/1',
        refreshedSources: const [unchangedSource, refreshedSource],
        refreshedFiles: const [unchangedFile, changedFile],
      );

      expect(await unchangedPage.exists(), isTrue);
      expect(await stalePage.exists(), isFalse);
      expect(await stalePartial.exists(), isFalse);
    },
  );

  test('rejects a manifest whose source digest was tampered with', () async {
    final manifestFile = File('${directory.path}/chapter.json');
    await manifestFile.writeAsString(
      jsonEncode({
        'version': currentMangaOfflineManifestVersion,
        'chapterUrl': 'https://example.com/chapter/1',
        'sources': ['https://images.example.com/1.jpg'],
        'sourceDigests': [List.filled(64, '0').join()],
        'files': ['pages/page_000000.jpg'],
      }),
    );

    expect(await readMangaOfflineManifest(manifestFile), isNull);
  });
}
