import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/chapter.dart';
import '../models/content_progress.dart';
import '../models/novel.dart';

enum NovelCacheBatchRange { next20, next50, full }

extension NovelCacheBatchRangeSelection on NovelCacheBatchRange {
  List<int> chapterIndices({
    required int chapterCount,
    required int startIndex,
  }) {
    if (chapterCount <= 0) return const <int>[];
    final current = startIndex.clamp(0, chapterCount - 1).toInt();
    final first = switch (this) {
      NovelCacheBatchRange.full => 0,
      NovelCacheBatchRange.next20 ||
      NovelCacheBatchRange.next50 => (current + 1).clamp(0, chapterCount),
    };
    final endExclusive = switch (this) {
      NovelCacheBatchRange.next20 => (first + 20).clamp(0, chapterCount),
      NovelCacheBatchRange.next50 => (first + 50).clamp(0, chapterCount),
      NovelCacheBatchRange.full => chapterCount,
    };
    return List<int>.generate(
      endExclusive - first,
      (offset) => first + offset,
      growable: false,
    );
  }
}

class NovelOfflineChapterStatus {
  const NovelOfflineChapterStatus({
    required this.chapterId,
    required this.chapterIndex,
    required this.title,
    required this.downloaded,
    required this.pinned,
    required this.byteSize,
  });

  final String chapterId;
  final int chapterIndex;
  final String title;
  final bool downloaded;
  final bool pinned;
  final int byteSize;
}

class NovelOfflineStatus {
  const NovelOfflineStatus({
    required this.contentKey,
    required this.chapters,
    required this.pinnedChapterId,
    required this.totalBytes,
  });

  final String contentKey;
  final List<NovelOfflineChapterStatus> chapters;
  final String? pinnedChapterId;
  final int totalBytes;

  int get downloadedChapterCount =>
      chapters.where((chapter) => chapter.downloaded).length;

  int get retainedChapterCount => chapters.length;

  bool isDownloaded(String chapterId) => chapters.any(
    (chapter) => chapter.chapterId == chapterId && chapter.downloaded,
  );
}

class NovelCacheBatchProgress {
  const NovelCacheBatchProgress({
    required this.completed,
    required this.total,
    required this.chapter,
    required this.succeeded,
    this.skipped = false,
  });

  final int completed;
  final int total;
  final Chapter chapter;
  final bool succeeded;
  final bool skipped;
}

class NovelCacheBatchResult {
  const NovelCacheBatchResult({
    required this.requested,
    required this.saved,
    required this.failedChapterIds,
    this.skipped = 0,
    this.cancelled = false,
  });

  final int requested;
  final int saved;
  final List<String> failedChapterIds;
  final int skipped;
  final bool cancelled;

  bool get complete =>
      !cancelled && failedChapterIds.isEmpty && saved == requested;
}

typedef NovelChapterContentLoader = Future<String> Function(Chapter chapter);
typedef NovelCacheProgressCallback =
    void Function(NovelCacheBatchProgress progress);
typedef NovelChapterContentValidator = bool Function(String content);
typedef NovelCacheCancellationCheck = bool Function();

/// Owns source-aware novel caches.
///
/// Temporary files remain in the application's existing cache directory so
/// [StorageService] can continue enforcing its 300 MB / 3000 file / 90 day
/// LRU policy. User-requested downloads and the current chapter pin live in a
/// separate manifest-backed directory and are never considered temporary LRU
/// candidates.
class NovelOfflineCacheService {
  NovelOfflineCacheService(this._rootDirectory);

  static const int manifestSchemaVersion = 1;

  final Directory _rootDirectory;
  final Map<String, Future<void>> _mutationQueues = <String, Future<void>>{};

  Directory get persistentRoot => Directory(
    '${_rootDirectory.path}${Platform.pathSeparator}novel_offline_v1',
  );

  String tempChapterListPath(Novel novel) {
    final identity = ContentIdentity.novel(novel);
    return '${_rootDirectory.path}${Platform.pathSeparator}'
        'chapters_v2_${identity.contentKey}.json';
  }

  String tempChapterContentPath(Novel novel, Chapter chapter) {
    final identity = ContentIdentity.novel(novel);
    return '${_rootDirectory.path}${Platform.pathSeparator}'
        'content_v2_${_hash('${identity.contentKey}\u0000${chapter.id}')}.txt';
  }

  Future<void> saveTemporaryChapterList(
    Novel novel,
    List<Map<String, dynamic>> chapters,
  ) async {
    await _ensureRoot();
    final file = File(tempChapterListPath(novel));
    await _writeTextAtomically(file, jsonEncode(chapters));
  }

  Future<List<Map<String, dynamic>>?> getTemporaryChapterList(
    Novel novel,
  ) async {
    await _ensureRoot();
    final current = File(tempChapterListPath(novel));
    final decoded = await _readChapterList(current);
    if (decoded != null) {
      unawaited(_touch(current));
      return decoded;
    }

    final legacy = File(_legacyChapterListPath(novel.id));
    final legacyDecoded = await _readChapterList(legacy);
    if (legacyDecoded == null ||
        !_validLegacyChapterList(novel, legacyDecoded)) {
      return null;
    }
    await saveTemporaryChapterList(novel, legacyDecoded);
    return legacyDecoded;
  }

  Future<void> saveTemporaryChapterContent(
    Novel novel,
    Chapter chapter,
    String content,
  ) async {
    if (content.isEmpty) return;
    await _ensureRoot();
    await _writeTextAtomically(
      File(tempChapterContentPath(novel, chapter)),
      content,
    );
  }

  Future<String?> getTemporaryChapterContent(
    Novel novel,
    Chapter chapter,
  ) async {
    await _ensureRoot();
    final current = File(tempChapterContentPath(novel, chapter));
    final currentContent = await _readNonEmptyText(current);
    if (currentContent != null) {
      unawaited(_touch(current));
      return currentContent;
    }

    final legacy = File(_legacyChapterContentPath(novel.id, chapter.id));
    final legacyContent = await _readNonEmptyText(legacy);
    if (legacyContent == null ||
        !await _legacyContentMatchesChapter(novel, chapter)) {
      return null;
    }
    await saveTemporaryChapterContent(novel, chapter, legacyContent);
    return legacyContent;
  }

  Future<void> deleteTemporaryChapterContent(
    Novel novel,
    Chapter chapter,
  ) async {
    final file = File(tempChapterContentPath(novel, chapter));
    if (await file.exists()) await file.delete();
  }

  Future<String> resolveChapterContent({
    required Novel novel,
    required Chapter chapter,
    required Future<String> Function() loadFromNetwork,
    NovelChapterContentValidator? isValidContent,
  }) async {
    final validator = isValidContent ?? (content) => content.trim().isNotEmpty;
    final persistent = await getPersistentChapterContent(novel, chapter);
    if (persistent != null && validator(persistent)) return persistent;

    final temporary = await getTemporaryChapterContent(novel, chapter);
    if (temporary != null) {
      if (validator(temporary)) return temporary;
      await deleteTemporaryChapterContent(novel, chapter);
    }

    final network = await loadFromNetwork();
    if (validator(network)) {
      await saveTemporaryChapterContent(novel, chapter, network);
    }
    return network;
  }

  Future<String?> getPersistentChapterContent(
    Novel novel,
    Chapter chapter,
  ) async {
    final snapshot = await _getPersistentChapterSnapshot(novel, chapter);
    return snapshot?.content;
  }

  Future<({String content, bool downloaded})?> _getPersistentChapterSnapshot(
    Novel novel,
    Chapter chapter,
  ) async {
    if (chapter.novelId != novel.id) return null;
    final identity = ContentIdentity.novel(novel);
    final manifest = await _readManifest(identity);
    final entry = manifest?.chapters[chapter.id];
    if (entry == null || !_entryMatchesChapter(entry, chapter)) return null;

    final file = File(
      '${_persistentBookDirectory(identity).path}${Platform.pathSeparator}'
      '${entry.fileName}',
    );
    final content = await _readNonEmptyText(file);
    if (content == null) return null;
    if (_hash(content) != entry.digest) return null;
    return (content: content, downloaded: entry.downloaded);
  }

  Future<void> savePersistentChapterList(Novel novel, List<Chapter> chapters) {
    return _mutateManifest(novel, (manifest, bookDirectory) async {
      await _synchronizePersistentCatalog(
        manifest,
        bookDirectory,
        novel,
        chapters,
      );
    });
  }

  /// Refreshes metadata only when the user already owns persistent data for
  /// this book. Ordinary online browsing must not create durable manifests.
  Future<bool> refreshPersistentChapterList(
    Novel novel,
    List<Chapter> chapters,
  ) {
    final identity = ContentIdentity.novel(novel);
    return _synchronized(identity.contentKey, () async {
      final manifest = await _readManifest(identity);
      if (manifest == null) return false;
      final directory = _persistentBookDirectory(identity);
      await _synchronizePersistentCatalog(manifest, directory, novel, chapters);
      manifest.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      await directory.create(recursive: true);
      await _writeTextAtomically(
        _manifestFile(identity),
        jsonEncode(manifest.toJson()),
        keepRecoveryBackup: true,
      );
      return true;
    });
  }

  Future<List<Chapter>> getPersistentChapterList(Novel novel) async {
    final identity = ContentIdentity.novel(novel);
    final manifest = await _readManifest(identity);
    if (manifest == null) return const <Chapter>[];
    final entries = manifest.catalog.isNotEmpty
        ? List<_NovelOfflineCatalogEntry>.of(manifest.catalog)
        : manifest.chapters.values
              .map(_NovelOfflineCatalogEntry.fromManifestEntry)
              .toList(growable: false);
    entries.sort((left, right) => left.index.compareTo(right.index));
    return List<Chapter>.unmodifiable(
      entries.map((entry) => entry.toChapter(novel.id)),
    );
  }

  Future<void> saveDownloadedChapter(
    Novel novel,
    Chapter chapter,
    String content,
  ) {
    return _mutateManifest(novel, (manifest, bookDirectory) async {
      await _writePersistentChapter(
        manifest,
        bookDirectory,
        chapter,
        content,
        downloaded: true,
      );
    });
  }

  Future<void> pinChapter(Novel novel, Chapter chapter, String content) {
    return _mutateManifest(novel, (manifest, bookDirectory) async {
      final previousPin = manifest.pinnedChapterId;
      final existing = manifest.chapters[chapter.id];
      await _writePersistentChapter(
        manifest,
        bookDirectory,
        chapter,
        content,
        downloaded: existing?.downloaded ?? false,
      );
      if (previousPin != null && previousPin != chapter.id) {
        final previousEntry = manifest.chapters[previousPin];
        if (previousEntry != null && !previousEntry.downloaded) {
          await _deleteEntryFile(bookDirectory, previousEntry);
          manifest.chapters.remove(previousPin);
        }
      }
      manifest.pinnedChapterId = chapter.id;
    });
  }

  Future<void> clearPinnedChapter(Novel novel) {
    return _mutateManifest(novel, (manifest, bookDirectory) async {
      final previousPin = manifest.pinnedChapterId;
      if (previousPin == null) return;
      final previousEntry = manifest.chapters[previousPin];
      if (previousEntry != null && !previousEntry.downloaded) {
        await _deleteEntryFile(bookDirectory, previousEntry);
        manifest.chapters.remove(previousPin);
      }
      manifest.pinnedChapterId = null;
    });
  }

  Future<void> removeDownloadedChapter(Novel novel, String chapterId) {
    return _mutateManifest(novel, (manifest, bookDirectory) async {
      final entry = manifest.chapters[chapterId];
      if (entry == null) return;
      if (manifest.pinnedChapterId == chapterId) {
        manifest.chapters[chapterId] = entry.copyWith(downloaded: false);
        return;
      }
      await _deleteEntryFile(bookDirectory, entry);
      manifest.chapters.remove(chapterId);
    });
  }

  Future<void> clearDownloadedChapters(Novel novel) {
    return _mutateManifest(novel, (manifest, bookDirectory) async {
      final pinned = manifest.pinnedChapterId;
      final entries = manifest.chapters.values.toList(growable: false);
      for (final entry in entries) {
        if (entry.chapterId == pinned) {
          manifest.chapters[entry.chapterId] = entry.copyWith(
            downloaded: false,
          );
        } else {
          await _deleteEntryFile(bookDirectory, entry);
          manifest.chapters.remove(entry.chapterId);
        }
      }
      manifest.catalog.clear();
    });
  }

  Future<NovelOfflineStatus> getStatus(Novel novel) async {
    final identity = ContentIdentity.novel(novel);
    final manifest = await _readManifest(identity);
    if (manifest == null) {
      return NovelOfflineStatus(
        contentKey: identity.contentKey,
        chapters: const <NovelOfflineChapterStatus>[],
        pinnedChapterId: null,
        totalBytes: 0,
      );
    }
    final bookDirectory = _persistentBookDirectory(identity);
    final chapters = <NovelOfflineChapterStatus>[];
    var pinnedChapterIsValid = false;
    for (final entry in manifest.chapters.values) {
      if (!await _isPersistentEntryValid(bookDirectory, entry)) continue;
      final pinned = manifest.pinnedChapterId == entry.chapterId;
      if (pinned) pinnedChapterIsValid = true;
      chapters.add(
        NovelOfflineChapterStatus(
          chapterId: entry.chapterId,
          chapterIndex: entry.chapterIndex,
          title: entry.title,
          downloaded: entry.downloaded,
          pinned: pinned,
          byteSize: entry.byteSize,
        ),
      );
    }
    chapters.sort(
      (left, right) => left.chapterIndex.compareTo(right.chapterIndex),
    );
    return NovelOfflineStatus(
      contentKey: identity.contentKey,
      chapters: List<NovelOfflineChapterStatus>.unmodifiable(chapters),
      pinnedChapterId: pinnedChapterIsValid ? manifest.pinnedChapterId : null,
      totalBytes: chapters.fold<int>(0, (sum, entry) => sum + entry.byteSize),
    );
  }

  Future<NovelCacheBatchResult> cacheBatch({
    required Novel novel,
    required List<Chapter> chapters,
    required Iterable<int> chapterIndices,
    required NovelChapterContentLoader loadContent,
    NovelCacheProgressCallback? onProgress,
    NovelChapterContentValidator? isValidContent,
    NovelCacheCancellationCheck? shouldCancel,
  }) async {
    await savePersistentChapterList(novel, chapters);
    final indices =
        chapterIndices
            .where((index) => index >= 0 && index < chapters.length)
            .toSet()
            .toList(growable: false)
          ..sort();
    final failed = <String>[];
    var saved = 0;
    var skipped = 0;
    var cancelled = false;
    final validator = isValidContent ?? (content) => content.trim().isNotEmpty;
    for (var offset = 0; offset < indices.length; offset++) {
      if (shouldCancel?.call() ?? false) {
        cancelled = true;
        break;
      }
      final chapter = chapters[indices[offset]];
      var succeeded = false;
      var chapterSkipped = false;
      try {
        final persistent = await _getPersistentChapterSnapshot(novel, chapter);
        if (persistent != null && validator(persistent.content)) {
          if (!persistent.downloaded) {
            await saveDownloadedChapter(novel, chapter, persistent.content);
          }
          saved += 1;
          skipped += 1;
          succeeded = true;
          chapterSkipped = true;
        } else {
          final content = await loadContent(chapter);
          if (validator(content)) {
            await saveDownloadedChapter(novel, chapter, content);
            saved += 1;
            succeeded = true;
          }
        }
      } catch (_) {
        // The caller receives a per-chapter failure list and may retry later.
      }
      if (!succeeded) failed.add(chapter.id);
      onProgress?.call(
        NovelCacheBatchProgress(
          completed: offset + 1,
          total: indices.length,
          chapter: chapter,
          succeeded: succeeded,
          skipped: chapterSkipped,
        ),
      );
    }
    return NovelCacheBatchResult(
      requested: indices.length,
      saved: saved,
      failedChapterIds: List<String>.unmodifiable(failed),
      skipped: skipped,
      cancelled: cancelled,
    );
  }

  Future<void> _writePersistentChapter(
    _NovelOfflineManifest manifest,
    Directory bookDirectory,
    Chapter chapter,
    String content, {
    required bool downloaded,
  }) async {
    if (content.trim().isEmpty) return;
    await bookDirectory.create(recursive: true);
    final existing = manifest.chapters[chapter.id];
    var fileName = existing?.fileName ?? 'chapter_${_hash(chapter.id)}.txt';
    final fileNameOwnedByAnotherChapter = manifest.chapters.values.any(
      (entry) => entry.chapterId != chapter.id && entry.fileName == fileName,
    );
    if (fileNameOwnedByAnotherChapter) {
      fileName = 'chapter_${_hash('${chapter.id}\u0000${_hash(content)}')}.txt';
    }
    final file = File(
      '${bookDirectory.path}${Platform.pathSeparator}$fileName',
    );
    await _writeTextAtomically(file, content);
    manifest.chapters[chapter.id] = _NovelOfflineManifestEntry(
      chapterId: chapter.id,
      chapterIndex: chapter.index,
      title: chapter.title,
      url: chapter.url,
      fileName: fileName,
      digest: _hash(content),
      byteSize: utf8.encode(content).length,
      downloaded: downloaded,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _mutateManifest(
    Novel novel,
    Future<void> Function(
      _NovelOfflineManifest manifest,
      Directory bookDirectory,
    )
    mutation,
  ) {
    final identity = ContentIdentity.novel(novel);
    return _synchronized(identity.contentKey, () async {
      final directory = _persistentBookDirectory(identity);
      final manifest =
          await _readManifest(identity) ??
          _NovelOfflineManifest.empty(identity: identity, novel: novel);
      await mutation(manifest, directory);
      manifest.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      if (manifest.chapters.isEmpty &&
          manifest.pinnedChapterId == null &&
          manifest.catalog.isEmpty) {
        await _deleteManifestArtifacts(identity);
        if (await directory.exists() && await directory.list().isEmpty) {
          await directory.delete();
        }
        return;
      }
      await directory.create(recursive: true);
      await _writeTextAtomically(
        _manifestFile(identity),
        jsonEncode(manifest.toJson()),
        keepRecoveryBackup: true,
      );
    });
  }

  Future<_NovelOfflineManifest?> _readManifest(ContentIdentity identity) async {
    final file = _manifestFile(identity);
    final primary = await _decodeManifestFile(file, identity);
    if (primary != null) return primary;

    final candidates = <File>[_manifestBackupFile(identity)];
    if (await file.parent.exists()) {
      final temporary = <File>[];
      await for (final entity in file.parent.list(followLinks: false)) {
        if (entity is File && _isManifestTemporary(entity, file)) {
          temporary.add(entity);
        }
      }
      temporary.sort((left, right) => right.path.compareTo(left.path));
      candidates.addAll(temporary);
    }
    for (final candidate in candidates) {
      final recovered = await _decodeManifestFile(candidate, identity);
      if (recovered == null) continue;
      await _restoreManifestCandidate(candidate, file);
      return recovered;
    }
    return null;
  }

  Future<_NovelOfflineManifest?> _decodeManifestFile(
    File file,
    ContentIdentity identity,
  ) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final manifest = _NovelOfflineManifest.fromJson(
        decoded.cast<String, dynamic>(),
      );
      if (manifest.schemaVersion != manifestSchemaVersion ||
          manifest.contentKey != identity.contentKey ||
          manifest.sourceKey != identity.sourceKey ||
          manifest.itemId != identity.itemId) {
        return null;
      }
      return manifest;
    } catch (_) {
      return null;
    }
  }

  Future<void> _restoreManifestCandidate(File candidate, File target) async {
    try {
      if (await target.exists()) await target.delete();
      await candidate.rename(target.path);
    } catch (_) {
      try {
        await candidate.copy(target.path);
      } catch (_) {
        // The validated fallback remains available for the next read attempt.
      }
    }
  }

  Future<void> _deleteManifestArtifacts(ContentIdentity identity) async {
    final manifest = _manifestFile(identity);
    for (final file in <File>[manifest, _manifestBackupFile(identity)]) {
      if (await file.exists()) await file.delete();
    }
    if (!await manifest.parent.exists()) return;
    await for (final entity in manifest.parent.list(followLinks: false)) {
      if (entity is File && _isManifestTemporary(entity, manifest)) {
        await entity.delete();
      }
    }
  }

  bool _validLegacyChapterList(
    Novel novel,
    List<Map<String, dynamic>> chapters,
  ) {
    if (chapters.isEmpty) return false;
    final ids = <String>{};
    var previousIndex = -1;
    for (final chapter in chapters) {
      final id = chapter['id']?.toString().trim() ?? '';
      final novelId = chapter['novelId']?.toString().trim() ?? '';
      final index = _asInt(chapter['index'], fallback: previousIndex + 1);
      if (id.isEmpty || !ids.add(id) || novelId != novel.id) return false;
      if (index < previousIndex) return false;
      previousIndex = index;
    }
    if (novel.isLocal || novel.sourceId.trim().isEmpty) return true;

    final expectedHost = _hostOf(novel.chapterUrl);
    if (expectedHost.isEmpty) return false;
    final cachedHosts = chapters
        .map((chapter) => _hostOf(chapter['url']?.toString() ?? ''))
        .where((host) => host.isNotEmpty)
        .toSet();
    return cachedHosts.isNotEmpty &&
        cachedHosts.every((host) => host == expectedHost);
  }

  Future<bool> _legacyContentMatchesChapter(
    Novel novel,
    Chapter chapter,
  ) async {
    if (chapter.novelId != novel.id) return false;
    final legacyList = await _readChapterList(
      File(_legacyChapterListPath(novel.id)),
    );
    if (legacyList == null || !_validLegacyChapterList(novel, legacyList)) {
      return false;
    }
    for (final cached in legacyList) {
      if (cached['id']?.toString() != chapter.id) continue;
      final cachedIndex = _asInt(cached['index'], fallback: -1);
      if (cachedIndex != chapter.index) return false;
      final cachedUrl = cached['url']?.toString() ?? '';
      if (chapter.url.isNotEmpty && cachedUrl != chapter.url) return false;
      return true;
    }
    return false;
  }

  bool _entryMatchesChapter(_NovelOfflineManifestEntry entry, Chapter chapter) {
    if (entry.chapterId != chapter.id || entry.chapterIndex != chapter.index) {
      return false;
    }
    if (_normalizedChapterTitle(entry.title) !=
        _normalizedChapterTitle(chapter.title)) {
      return false;
    }
    if (entry.url.isNotEmpty &&
        chapter.url.isNotEmpty &&
        entry.url != chapter.url) {
      return false;
    }
    return true;
  }

  Future<void> _synchronizePersistentCatalog(
    _NovelOfflineManifest manifest,
    Directory bookDirectory,
    Novel novel,
    List<Chapter> chapters,
  ) async {
    final seenIds = <String>{};
    final nextCatalog =
        chapters
            .where(
              (chapter) =>
                  chapter.novelId == novel.id &&
                  chapter.id.trim().isNotEmpty &&
                  seenIds.add(chapter.id),
            )
            .map(_NovelOfflineCatalogEntry.fromChapter)
            .toList(growable: false)
          ..sort((left, right) => left.index.compareTo(right.index));
    if (_sameCatalog(manifest.catalog, nextCatalog)) return;

    final previousCatalog = manifest.catalog.isNotEmpty
        ? List<_NovelOfflineCatalogEntry>.of(manifest.catalog)
        : manifest.chapters.values
              .map(_NovelOfflineCatalogEntry.fromManifestEntry)
              .toList(growable: false);
    final previousTitleCounts = _chapterTitleCounts(previousCatalog);
    final nextTitleCounts = _chapterTitleCounts(nextCatalog);
    final entriesByTitle = <String, List<_NovelOfflineManifestEntry>>{};
    for (final entry in manifest.chapters.values) {
      final title = _normalizedChapterTitle(entry.title);
      if (title.isEmpty) continue;
      entriesByTitle.putIfAbsent(title, () => []).add(entry);
    }

    final remapped = <String, _NovelOfflineManifestEntry>{};
    final remappedOriginalIds = <String>{};
    final newIdByOriginalId = <String, String>{};
    for (final chapter in nextCatalog) {
      final title = _normalizedChapterTitle(chapter.title);
      final candidates = entriesByTitle[title] ?? const [];
      if (title.isEmpty ||
          previousTitleCounts[title] != 1 ||
          nextTitleCounts[title] != 1 ||
          candidates.length != 1) {
        continue;
      }
      final existing = candidates.single;
      remapped[chapter.id] = existing.withCatalogMetadata(chapter);
      remappedOriginalIds.add(existing.chapterId);
      newIdByOriginalId[existing.chapterId] = chapter.id;
    }

    final nextIds = nextCatalog.map((chapter) => chapter.id).toSet();
    for (final entry in manifest.chapters.values) {
      if (remappedOriginalIds.contains(entry.chapterId)) continue;
      if (!nextIds.contains(entry.chapterId) &&
          !remapped.containsKey(entry.chapterId)) {
        // Keep removed chapters as inaccessible orphans so a transiently
        // incomplete source catalog cannot destroy a user's download.
        remapped[entry.chapterId] = entry;
        continue;
      }
      // The refreshed catalog reused this positional id for a chapter that
      // cannot be identified unambiguously. Remove the stale association so
      // it can never serve another chapter's text.
      await _deleteEntryFile(bookDirectory, entry);
    }

    final previousPin = manifest.pinnedChapterId;
    manifest.pinnedChapterId = previousPin == null
        ? null
        : newIdByOriginalId[previousPin] ??
              (remapped.containsKey(previousPin) ? previousPin : null);
    manifest.chapters
      ..clear()
      ..addAll(remapped);
    manifest.catalog
      ..clear()
      ..addAll(nextCatalog);
  }

  bool _sameCatalog(
    List<_NovelOfflineCatalogEntry> first,
    List<_NovelOfflineCatalogEntry> second,
  ) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      final left = first[index];
      final right = second[index];
      if (left.id != right.id ||
          left.title != right.title ||
          left.index != right.index ||
          left.url != right.url) {
        return false;
      }
    }
    return true;
  }

  Map<String, int> _chapterTitleCounts(
    List<_NovelOfflineCatalogEntry> chapters,
  ) {
    final counts = <String, int>{};
    for (final chapter in chapters) {
      final title = _normalizedChapterTitle(chapter.title);
      if (title.isEmpty) continue;
      counts[title] = (counts[title] ?? 0) + 1;
    }
    return counts;
  }

  Future<List<Map<String, dynamic>>?> _readChapterList(File file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readNonEmptyText(File file) async {
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
      return content.isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeTextAtomically(
    File target,
    String content, {
    bool keepRecoveryBackup = false,
  }) async {
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(content, flush: true);
    try {
      if (!Platform.isWindows) {
        await temporary.rename(target.path);
        return;
      }
      if (!keepRecoveryBackup || !await target.exists()) {
        if (await target.exists()) await target.delete();
        await temporary.rename(target.path);
        return;
      }

      final backup = File('${target.path}.bak');
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
      try {
        await temporary.rename(target.path);
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  bool _isManifestTemporary(File candidate, File manifest) =>
      candidate.path.startsWith('${manifest.path}.') &&
      candidate.path.endsWith('.tmp');

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // Cache access timestamp updates must never block reading.
    }
  }

  Future<void> _deleteEntryFile(
    Directory bookDirectory,
    _NovelOfflineManifestEntry entry,
  ) async {
    final file = File(
      '${bookDirectory.path}${Platform.pathSeparator}${entry.fileName}',
    );
    if (await file.exists()) await file.delete();
  }

  Future<bool> _isPersistentEntryValid(
    Directory bookDirectory,
    _NovelOfflineManifestEntry entry,
  ) async {
    final file = File(
      '${bookDirectory.path}${Platform.pathSeparator}${entry.fileName}',
    );
    final content = await _readNonEmptyText(file);
    if (content == null) return false;
    return utf8.encode(content).length == entry.byteSize &&
        _hash(content) == entry.digest;
  }

  Future<void> _ensureRoot() async {
    if (!await _rootDirectory.exists()) {
      await _rootDirectory.create(recursive: true);
    }
  }

  Future<T> _synchronized<T>(String key, Future<T> Function() action) {
    final previous = _mutationQueues[key] ?? Future<void>.value();
    final result = previous.catchError((_) {}).then((_) => action());
    final tail = result.then<void>((_) {}, onError: (_, _) {});
    _mutationQueues[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_mutationQueues[key], tail)) {
          _mutationQueues.remove(key);
        }
      }),
    );
    return result;
  }

  Directory _persistentBookDirectory(ContentIdentity identity) => Directory(
    '${persistentRoot.path}${Platform.pathSeparator}${identity.contentKey}',
  );

  File _manifestFile(ContentIdentity identity) => File(
    '${_persistentBookDirectory(identity).path}${Platform.pathSeparator}'
    'manifest.json',
  );

  File _manifestBackupFile(ContentIdentity identity) =>
      File('${_manifestFile(identity).path}.bak');

  String _legacyChapterListPath(String novelId) =>
      '${_rootDirectory.path}${Platform.pathSeparator}'
      'chapters_${_hash(novelId)}.json';

  String _legacyChapterContentPath(String novelId, String chapterId) =>
      '${_rootDirectory.path}${Platform.pathSeparator}'
      'content_${_hash('$novelId::$chapterId')}.txt';

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _normalizedChapterTitle(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static int _asInt(Object? value, {required int fallback}) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static String _hostOf(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.hasScheme ? uri.host.toLowerCase() : '';
    } catch (_) {
      return '';
    }
  }

  static bool _isSafePersistentFileName(String value) =>
      RegExp(r'^chapter_[a-f0-9]{64}\.txt$').hasMatch(value);
}

class _NovelOfflineManifest {
  _NovelOfflineManifest({
    required this.schemaVersion,
    required this.contentKey,
    required this.sourceKey,
    required this.itemId,
    required this.title,
    required this.updatedAtMs,
    required this.pinnedChapterId,
    required this.catalog,
    required this.chapters,
  });

  factory _NovelOfflineManifest.empty({
    required ContentIdentity identity,
    required Novel novel,
  }) => _NovelOfflineManifest(
    schemaVersion: NovelOfflineCacheService.manifestSchemaVersion,
    contentKey: identity.contentKey,
    sourceKey: identity.sourceKey,
    itemId: identity.itemId,
    title: novel.title,
    updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    pinnedChapterId: null,
    catalog: <_NovelOfflineCatalogEntry>[],
    chapters: <String, _NovelOfflineManifestEntry>{},
  );

  factory _NovelOfflineManifest.fromJson(Map<String, dynamic> json) {
    final rawChapters = json['chapters'];
    final chapters = <String, _NovelOfflineManifestEntry>{};
    if (rawChapters is Map) {
      for (final item in rawChapters.entries) {
        if (item.value is! Map) continue;
        final entry = _NovelOfflineManifestEntry.fromJson(
          (item.value as Map).cast<String, dynamic>(),
        );
        if (entry.chapterId.isNotEmpty &&
            NovelOfflineCacheService._isSafePersistentFileName(
              entry.fileName,
            )) {
          chapters[entry.chapterId] = entry;
        }
      }
    }
    final catalog = <_NovelOfflineCatalogEntry>[];
    final seenCatalogIds = <String>{};
    final rawCatalog = json['catalog'];
    if (rawCatalog is List) {
      for (final rawEntry in rawCatalog.whereType<Map>()) {
        final entry = _NovelOfflineCatalogEntry.fromJson(
          rawEntry.cast<String, dynamic>(),
        );
        if (entry.id.isEmpty || !seenCatalogIds.add(entry.id)) continue;
        catalog.add(entry);
      }
      catalog.sort((left, right) => left.index.compareTo(right.index));
    }
    return _NovelOfflineManifest(
      schemaVersion: NovelOfflineCacheService._asInt(
        json['schemaVersion'],
        fallback: 0,
      ),
      contentKey: json['contentKey']?.toString() ?? '',
      sourceKey: json['sourceKey']?.toString() ?? '',
      itemId: json['itemId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      updatedAtMs: NovelOfflineCacheService._asInt(
        json['updatedAtMs'],
        fallback: 0,
      ),
      pinnedChapterId: json['pinnedChapterId']?.toString(),
      catalog: catalog,
      chapters: chapters,
    );
  }

  final int schemaVersion;
  final String contentKey;
  final String sourceKey;
  final String itemId;
  final String title;
  int updatedAtMs;
  String? pinnedChapterId;
  final List<_NovelOfflineCatalogEntry> catalog;
  final Map<String, _NovelOfflineManifestEntry> chapters;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schemaVersion': schemaVersion,
    'contentKey': contentKey,
    'sourceKey': sourceKey,
    'itemId': itemId,
    'title': title,
    'updatedAtMs': updatedAtMs,
    'pinnedChapterId': pinnedChapterId,
    'catalog': catalog.map((entry) => entry.toJson()).toList(growable: false),
    'chapters': <String, dynamic>{
      for (final entry in chapters.entries) entry.key: entry.value.toJson(),
    },
  };
}

class _NovelOfflineCatalogEntry {
  const _NovelOfflineCatalogEntry({
    required this.id,
    required this.title,
    required this.index,
    required this.url,
  });

  factory _NovelOfflineCatalogEntry.fromChapter(Chapter chapter) =>
      _NovelOfflineCatalogEntry(
        id: chapter.id,
        title: chapter.title,
        index: chapter.index,
        url: chapter.url,
      );

  factory _NovelOfflineCatalogEntry.fromManifestEntry(
    _NovelOfflineManifestEntry entry,
  ) => _NovelOfflineCatalogEntry(
    id: entry.chapterId,
    title: entry.title,
    index: entry.chapterIndex,
    url: entry.url,
  );

  factory _NovelOfflineCatalogEntry.fromJson(Map<String, dynamic> json) =>
      _NovelOfflineCatalogEntry(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        index: NovelOfflineCacheService._asInt(json['index'], fallback: 0),
        url: json['url']?.toString() ?? '',
      );

  final String id;
  final String title;
  final int index;
  final String url;

  Chapter toChapter(String novelId) =>
      Chapter(id: id, novelId: novelId, title: title, index: index, url: url);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'index': index,
    'url': url,
  };
}

class _NovelOfflineManifestEntry {
  const _NovelOfflineManifestEntry({
    required this.chapterId,
    required this.chapterIndex,
    required this.title,
    required this.url,
    required this.fileName,
    required this.digest,
    required this.byteSize,
    required this.downloaded,
    required this.updatedAtMs,
  });

  factory _NovelOfflineManifestEntry.fromJson(Map<String, dynamic> json) =>
      _NovelOfflineManifestEntry(
        chapterId: json['chapterId']?.toString() ?? '',
        chapterIndex: NovelOfflineCacheService._asInt(
          json['chapterIndex'],
          fallback: 0,
        ),
        title: json['title']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        fileName: json['fileName']?.toString() ?? '',
        digest: json['digest']?.toString() ?? '',
        byteSize: NovelOfflineCacheService._asInt(
          json['byteSize'],
          fallback: 0,
        ),
        downloaded: json['downloaded'] == true,
        updatedAtMs: NovelOfflineCacheService._asInt(
          json['updatedAtMs'],
          fallback: 0,
        ),
      );

  final String chapterId;
  final int chapterIndex;
  final String title;
  final String url;
  final String fileName;
  final String digest;
  final int byteSize;
  final bool downloaded;
  final int updatedAtMs;

  _NovelOfflineManifestEntry copyWith({bool? downloaded}) =>
      _NovelOfflineManifestEntry(
        chapterId: chapterId,
        chapterIndex: chapterIndex,
        title: title,
        url: url,
        fileName: fileName,
        digest: digest,
        byteSize: byteSize,
        downloaded: downloaded ?? this.downloaded,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  _NovelOfflineManifestEntry withCatalogMetadata(
    _NovelOfflineCatalogEntry chapter,
  ) => _NovelOfflineManifestEntry(
    chapterId: chapter.id,
    chapterIndex: chapter.index,
    title: chapter.title,
    url: chapter.url,
    fileName: fileName,
    digest: digest,
    byteSize: byteSize,
    downloaded: downloaded,
    updatedAtMs: DateTime.now().millisecondsSinceEpoch,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'chapterId': chapterId,
    'chapterIndex': chapterIndex,
    'title': title,
    'url': url,
    'fileName': fileName,
    'digest': digest,
    'byteSize': byteSize,
    'downloaded': downloaded,
    'updatedAtMs': updatedAtMs,
  };
}
