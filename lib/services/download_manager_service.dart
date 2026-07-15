import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/anime.dart';
import '../models/local_library.dart';
import '../models/manga.dart';
import 'app_telemetry_service.dart';
import 'download_stream_utils.dart';
import 'manga_offline_manifest.dart';
import 'manga_service.dart';
import 'offline_hls_parser.dart';
import 'storage_service.dart';

class DownloadManagerService extends ChangeNotifier {
  DownloadManagerService._();

  static final DownloadManagerService instance = DownloadManagerService._();

  static const int _maxConcurrentTasks = 2;
  static const int _hlsParallelSegments = 4;
  static const int _progressPersistIntervalMs = 1500;
  static const String _mangaManifestFileName = 'chapter.json';
  static const int _maxTextDownloadBytes = 4 * 1024 * 1024;

  final StorageService _storage = StorageService();
  final MangaService _mangaService = MangaService();
  final Map<String, http.Client> _activeClients = {};
  final Set<String> _runningIds = {};
  final Map<String, int> _taskGenerations = {};
  final Map<String, Future<void>> _taskFutures = {};
  final Map<String, int> _lastProgressPersistAt = {};

  List<DownloadItem> _items = const [];
  Directory? _rootDirectory;
  bool _initialized = false;
  bool _scheduling = false;

  List<DownloadItem> get items => List.unmodifiable(_items);
  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    final documents = await getApplicationDocumentsDirectory();
    _rootDirectory = Directory('${documents.path}/novel_app/downloads');
    await _rootDirectory!.create(recursive: true);
    final stored = await _storage.recoverDownloadItems();
    var changed = false;
    _items = [
      for (final item in stored)
        if (item.status == 'done' && !await validatePlayable(item))
          item.copyWith(
            status: 'failed',
            errorMessage: '本地文件已丢失，请重新下载',
            localPath: '',
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          )
        else
          item,
    ];
    for (var index = 0; index < stored.length; index++) {
      if (_items[index].status != stored[index].status ||
          _items[index].localPath != stored[index].localPath) {
        changed = true;
        break;
      }
    }
    _initialized = true;
    if (changed) {
      for (var index = 0; index < stored.length; index++) {
        if (_items[index].status != stored[index].status ||
            _items[index].localPath != stored[index].localPath) {
          await _storage.saveDownloadItem(_items[index]);
        }
      }
    }
    notifyListeners();
    _schedule();
  }

  Future<DownloadItem> enqueueAnime({
    required Anime anime,
    required AnimePlaySource source,
    required AnimeEpisode episode,
  }) async {
    await init();
    final existing = _items.where(
      (item) =>
          item.type == LibraryItemType.anime &&
          item.itemId == anime.id.toString() &&
          item.episodeUrl == episode.url,
    );
    if (existing.isNotEmpty) {
      final item = existing.first;
      if (item.status == 'failed' || item.status == 'paused') {
        await resume(item.id);
      }
      return _find(item.id) ?? item;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final digest = sha1.convert(utf8.encode(episode.url)).toString();
    final item = DownloadItem(
      id: 'anime_${anime.id}_${digest.substring(0, 16)}',
      type: LibraryItemType.anime,
      itemId: anime.id.toString(),
      title: anime.title,
      coverUrl: anime.coverUrl,
      subtitle: anime.category,
      sourceName: source.name,
      episodeTitle: episode.title,
      episodeUrl: episode.url,
      totalCount: 0,
      cachedCount: 0,
      status: 'queued',
      createdAtMs: now,
      updatedAtMs: now,
    );
    _items = [item, ..._items];
    await _storage.saveDownloadItem(item);
    notifyListeners();
    AppTelemetryService.instance.trackEvent(
      'download_enqueue',
      screen: 'anime_detail',
      metadata: {
        'contentType': 'anime',
        'contentId': anime.id,
        'source': source.name,
      },
    );
    _schedule();
    return item;
  }

  Future<DownloadItem> enqueueMangaChapter({
    required Manga manga,
    required MangaChapter chapter,
    required int chapterIndex,
  }) async {
    await init();
    final existing = _items.where(
      (item) =>
          item.type == LibraryItemType.manga &&
          item.itemId == manga.id &&
          item.chapterUrl == chapter.url,
    );
    if (existing.isNotEmpty) {
      final item = existing.first;
      if (item.status == 'done' && await validatePlayable(item)) return item;
      if (item.status != 'queued' && item.status != 'downloading') {
        await resume(item.id);
      }
      return _find(item.id) ?? item;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final digest = sha1.convert(utf8.encode(chapter.url)).toString();
    final item = DownloadItem(
      id: 'manga_${manga.id}_${digest.substring(0, 16)}',
      type: LibraryItemType.manga,
      itemId: manga.id,
      title: manga.title,
      coverUrl: manga.coverUrl,
      subtitle: manga.author,
      sourceName: 'manga_baozi',
      chapterTitle: chapter.title,
      chapterUrl: chapter.url,
      chapterIndex: chapterIndex,
      status: 'queued',
      createdAtMs: now,
      updatedAtMs: now,
    );
    _items = [item, ..._items];
    await _storage.saveDownloadItem(item);
    notifyListeners();
    AppTelemetryService.instance.trackEvent(
      'download_enqueue',
      screen: 'manga_detail',
      metadata: {
        'contentType': 'manga',
        'contentId': manga.id,
        'chapterIndex': chapterIndex,
      },
    );
    _schedule();
    return item;
  }

  Future<void> pause(String id) async {
    final item = _find(id);
    if (item == null || item.status == 'done') return;
    await _replace(
      item.copyWith(
        status: 'paused',
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _taskGenerations[id] = (_taskGenerations[id] ?? 0) + 1;
    _activeClients.remove(id)?.close();
    await _waitForTask(id);
  }

  Future<void> resume(String id) async {
    final item = _find(id);
    if (item == null) return;
    var resetProgress = false;
    final refreshMangaSources =
        item.type == LibraryItemType.manga && item.status == 'failed';
    if (item.status == 'done') {
      if (await validatePlayable(item)) return;
      await _deleteItemDirectory(id);
      resetProgress = true;
    }
    await _replace(
      item.copyWith(
        status: 'queued',
        errorMessage: '',
        localPath: resetProgress || refreshMangaSources ? '' : item.localPath,
        downloadedBytes: resetProgress ? 0 : item.downloadedBytes,
        totalBytes: resetProgress ? 0 : item.totalBytes,
        cachedCount: resetProgress ? 0 : item.cachedCount,
        totalCount: resetProgress ? 0 : item.totalCount,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _schedule();
  }

  Future<void> delete(String id) async {
    final item = _find(id);
    if (item == null) return;
    _taskGenerations[id] = (_taskGenerations[id] ?? 0) + 1;
    _activeClients.remove(id)?.close();
    await _waitForTask(id);
    _items = _items.where((entry) => entry.id != id).toList();
    await _storage.deleteDownloadItem(id);
    await _deleteItemDirectory(id);
    notifyListeners();
  }

  Future<void> clearAll() async {
    for (final id in _runningIds) {
      _taskGenerations[id] = (_taskGenerations[id] ?? 0) + 1;
    }
    for (final client in _activeClients.values) {
      client.close();
    }
    _activeClients.clear();
    await Future.wait(_taskFutures.values.toList(), eagerError: false);
    final ids = _items.map((item) => item.id).toList();
    _items = const [];
    _runningIds.clear();
    _taskFutures.clear();
    _taskGenerations.clear();
    _lastProgressPersistAt.clear();
    await _storage.clearDownloadItems();
    for (final id in ids) {
      await _deleteItemDirectory(id);
    }
    notifyListeners();
  }

  DownloadItem? itemById(String id) => _find(id);

  Future<bool> validatePlayable(DownloadItem item) async {
    if (item.status != 'done' || item.localPath.isEmpty) return false;
    final root = _rootDirectory;
    if (root == null) return false;
    final itemRoot = Directory('${root.path}/${_safeDirectoryName(item.id)}');
    final localFile = File(item.localPath);
    if (!await itemRoot.exists() || !await localFile.exists()) return false;
    try {
      final resolvedRoot = await itemRoot.resolveSymbolicLinks();
      final resolvedFile = await localFile.resolveSymbolicLinks();
      if (!_isWithinDirectory(resolvedRoot, resolvedFile)) return false;
      if (await localFile.length() <= 0) return false;
      if (item.type == LibraryItemType.manga) {
        return (await loadMangaPagePaths(item)).isNotEmpty;
      }
      if (!localFile.path.toLowerCase().endsWith('.m3u8')) return true;
      return _validateLocalHlsPlaylist(localFile, resolvedRoot, <String>{});
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> loadMangaPagePaths(DownloadItem item) async {
    if (item.type != LibraryItemType.manga || item.localPath.isEmpty) {
      return const [];
    }
    final root = _rootDirectory;
    if (root == null) return const [];
    final itemRoot = Directory('${root.path}/${_safeDirectoryName(item.id)}');
    return validateMangaOfflineArchive(
      manifestFile: File(item.localPath),
      allowedRoot: itemRoot,
      expectedChapterUrl: item.chapterUrl,
      expectedPageCount: item.totalCount,
    );
  }

  void _schedule() {
    if (!_initialized || _scheduling) return;
    _scheduling = true;
    try {
      while (_runningIds.length < _maxConcurrentTasks) {
        final item = _items.cast<DownloadItem?>().firstWhere(
          (entry) =>
              entry != null &&
              entry.status == 'queued' &&
              !_runningIds.contains(entry.id),
          orElse: () => null,
        );
        if (item == null) break;
        _runningIds.add(item.id);
        final generation = (_taskGenerations[item.id] ?? 0) + 1;
        _taskGenerations[item.id] = generation;
        late final Future<void> task;
        task = _run(item, generation).whenComplete(() {
          if (_taskFutures[item.id] == task) {
            _taskFutures.remove(item.id);
            _runningIds.remove(item.id);
            _activeClients.remove(item.id)?.close();
            _schedule();
          }
        });
        _taskFutures[item.id] = task;
        unawaited(task);
      }
    } finally {
      _scheduling = false;
    }
  }

  Future<void> _run(DownloadItem initial, int generation) async {
    final current = _find(initial.id);
    if (current == null || current.status != 'queued') return;
    final stopwatch = Stopwatch()..start();
    await _replace(
      current.copyWith(
        status: 'downloading',
        errorMessage: '',
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final client = http.Client();
    _activeClients[current.id] = client;
    try {
      final directory = await _itemDirectory(current.id);
      final _DownloadResult result;
      if (current.type == LibraryItemType.manga) {
        result = await _downloadMangaChapter(
          current,
          directory,
          client,
          generation,
        );
      } else {
        final uri = Uri.parse(current.episodeUrl);
        result = _looksLikeHls(uri)
            ? await _downloadHls(current, uri, directory, client, generation)
            : await _downloadProbed(
                current,
                uri,
                directory,
                client,
                generation,
              );
      }
      final latest = _find(current.id);
      if (!_isTaskCurrent(current.id, generation) || latest == null) return;
      final completed = latest.copyWith(
        status: 'done',
        localPath: result.localPath,
        downloadedBytes: result.downloadedBytes,
        totalBytes: result.totalBytes,
        cachedCount: result.cachedCount,
        totalCount: result.totalCount,
        errorMessage: '',
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _replace(completed);
      AppTelemetryService.instance.trackEvent(
        'download_complete',
        screen: 'downloads',
        durationMs: stopwatch.elapsedMilliseconds,
        success: true,
        metadata: {
          'contentType': current.type.value,
          'contentId': current.itemId,
          'source': current.sourceName,
          'bytes': result.downloadedBytes,
          'parts': result.totalCount,
        },
      );
    } catch (error, stack) {
      final latest = _find(current.id);
      if (!_isTaskCurrent(current.id, generation) || latest == null) return;
      await _replace(
        latest.copyWith(
          status: 'failed',
          errorMessage: _friendlyError(error),
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      AppTelemetryService.instance.trackEvent(
        'download_complete',
        screen: 'downloads',
        durationMs: stopwatch.elapsedMilliseconds,
        success: false,
        metadata: {
          'contentType': current.type.value,
          'contentId': current.itemId,
          'source': current.sourceName,
          'errorType': error.runtimeType.toString(),
        },
      );
      AppTelemetryService.instance.captureError(
        error,
        stack,
        type: 'DownloadError',
        screen: 'downloads',
        fatal: false,
        metadata: {'itemId': current.itemId, 'source': current.sourceName},
      );
    }
  }

  Future<_DownloadResult> _downloadMangaChapter(
    DownloadItem item,
    Directory directory,
    http.Client client,
    int generation,
  ) async {
    if (item.chapterUrl.isEmpty) {
      throw const FormatException('漫画章节地址无效');
    }
    final manifestFile = File('${directory.path}/$_mangaManifestFileName');
    final storedManifest = await readMangaOfflineManifest(manifestFile);
    final chapter = MangaChapter(
      title: item.chapterTitle,
      url: item.chapterUrl,
    );
    final sources = await _mangaService.fetchChapterImages(chapter);
    if (sources.isEmpty) {
      throw const FormatException('漫画章节没有可下载的图片');
    }
    for (final source in sources) {
      _validateRemoteUri(Uri.parse(source));
    }
    final relativeFiles = [
      for (var index = 0; index < sources.length; index++)
        _mangaPageRelativePath(index, Uri.parse(sources[index])),
    ];
    final sourceDigests = sources
        .map(mangaOfflineSourceDigest)
        .toList(growable: false);
    await discardMismatchedMangaOfflinePages(
      downloadDirectory: directory,
      previousManifest: storedManifest,
      chapterUrl: item.chapterUrl,
      refreshedSources: sources,
      refreshedFiles: relativeFiles,
    );
    final manifest = MangaOfflineManifest(
      chapterUrl: item.chapterUrl,
      sources: sources,
      sourceDigests: sourceDigests,
      files: relativeFiles,
    );
    await writeMangaOfflineManifest(manifestFile, manifest);

    var downloadedBytes = 0;
    var completed = 0;
    final completedIndexes = <int>{};
    for (var index = 0; index < relativeFiles.length; index++) {
      final file = File.fromUri(directory.uri.resolve(relativeFiles[index]));
      if (await isLikelyMangaImageFile(file)) {
        downloadedBytes += await file.length();
        completed++;
        completedIndexes.add(index);
      } else if (await file.exists()) {
        await file.delete();
      }
    }
    await _updateProgress(
      item.id,
      downloadedBytes: downloadedBytes,
      totalBytes: 0,
      cachedCount: completed,
      totalCount: sources.length,
      forcePersist: true,
    );

    for (var index = 0; index < sources.length; index++) {
      _ensureRunning(item.id, generation);
      if (completedIndexes.contains(index)) continue;
      final output = File.fromUri(directory.uri.resolve(relativeFiles[index]));
      final size = await _downloadMangaPage(
        Uri.parse(sources[index]),
        item.chapterUrl,
        output,
        client,
        item.id,
        generation,
      );
      downloadedBytes += size;
      completed++;
      await _updateProgress(
        item.id,
        downloadedBytes: downloadedBytes,
        totalBytes: 0,
        cachedCount: completed,
        totalCount: sources.length,
      );
    }

    _ensureRunning(item.id, generation);
    final pages = await validateMangaOfflineArchive(
      manifestFile: manifestFile,
      allowedRoot: directory,
      expectedChapterUrl: item.chapterUrl,
      expectedPageCount: sources.length,
    );
    if (pages.length != sources.length) {
      throw const FileSystemException('漫画离线文件校验失败');
    }
    return _DownloadResult(
      localPath: manifestFile.path,
      downloadedBytes: downloadedBytes,
      totalBytes: downloadedBytes,
      cachedCount: sources.length,
      totalCount: sources.length,
    );
  }

  Future<int> _downloadMangaPage(
    Uri uri,
    String referer,
    File output,
    http.Client client,
    String itemId,
    int generation,
  ) async {
    _ensureRunning(itemId, generation);
    _validateRemoteUri(uri);
    await output.parent.create(recursive: true);
    final partial = File('${output.path}.part');
    final existingBytes = await partial.exists() ? await partial.length() : 0;
    final request = http.Request('GET', uri)
      ..headers.addAll(_headers(uri, referer: referer));
    if (existingBytes > 0) request.headers['Range'] = 'bytes=$existingBytes-';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      final totalMatch = RegExp(
        r'bytes \*/(\d+)',
      ).firstMatch(response.headers['content-range'] ?? '');
      final total = int.tryParse(totalMatch?.group(1) ?? '');
      await withDownloadIdleTimeout(response.stream).drain<void>();
      if (total == existingBytes && await isLikelyMangaImageFile(partial)) {
        _ensureRunning(itemId, generation);
        if (await output.exists()) await output.delete();
        await partial.rename(output.path);
        return output.length();
      }
      if (existingBytes > 0) {
        if (await partial.exists()) await partial.delete();
        return _downloadMangaPage(
          uri,
          referer,
          output,
          client,
          itemId,
          generation,
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final range = validateDownloadResponseRange(
      statusCode: response.statusCode,
      existingBytes: existingBytes,
      contentRange: response.headers['content-range'],
      contentLength: response.contentLength,
    );
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.startsWith('text/') ||
        contentType.contains('json') ||
        contentType.contains('xml')) {
      throw HttpException('漫画图片响应格式无效', uri: uri);
    }

    final resumed = range.append;
    if (!resumed && await partial.exists()) await partial.delete();
    final sink = partial.openWrite(
      mode: resumed ? FileMode.append : FileMode.write,
    );
    var receivedBodyBytes = 0;
    try {
      await for (final chunk in withDownloadIdleTimeout(response.stream)) {
        _ensureRunning(itemId, generation);
        sink.add(chunk);
        receivedBodyBytes += chunk.length;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    _ensureRunning(itemId, generation);
    final finalLength = await partial.length();
    if ((range.expectedBodyBytes != null &&
            receivedBodyBytes != range.expectedBodyBytes) ||
        (range.totalBytes != null && finalLength != range.totalBytes)) {
      if (resumed) {
        final handle = await partial.open(mode: FileMode.append);
        try {
          await handle.truncate(existingBytes);
        } finally {
          await handle.close();
        }
      } else if (await partial.exists()) {
        await partial.delete();
      }
      throw HttpException('漫画图片响应长度不完整', uri: uri);
    }
    if (!await isLikelyMangaImageFile(partial)) {
      if (await partial.exists()) await partial.delete();
      throw HttpException('漫画图片文件不完整', uri: uri);
    }
    if (await output.exists()) await output.delete();
    await partial.rename(output.path);
    return output.length();
  }

  String _mangaPageRelativePath(int index, Uri uri) {
    final rawExtension = _safeExtension(uri.path, fallback: '.jpg');
    final extension =
        const {
          '.jpg',
          '.jpeg',
          '.png',
          '.webp',
          '.gif',
          '.avif',
        }.contains(rawExtension)
        ? rawExtension
        : '.jpg';
    return 'pages/page_${index.toString().padLeft(6, '0')}$extension';
  }

  Future<_DownloadResult> _downloadProbed(
    DownloadItem item,
    Uri uri,
    Directory directory,
    http.Client client,
    int generation,
  ) async {
    _validateRemoteUri(uri);
    final extension = _safeExtension(uri.path, fallback: '.mp4');
    final partial = File('${directory.path}/video$extension.part');
    final existingBytes = await partial.exists() ? await partial.length() : 0;
    final request = http.Request('GET', uri)..headers.addAll(_headers(uri));
    if (existingBytes > 0) request.headers['Range'] = 'bytes=$existingBytes-';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        existingBytes > 0) {
      final totalMatch = RegExp(
        r'bytes \*/(\d+)',
      ).firstMatch(response.headers['content-range'] ?? '');
      final total = int.tryParse(totalMatch?.group(1) ?? '');
      await withDownloadIdleTimeout(response.stream).drain<void>();
      if (total == existingBytes) {
        _ensureRunning(item.id, generation);
        final output = File('${directory.path}/video$extension');
        if (await output.exists()) await output.delete();
        await partial.rename(output.path);
        return _DownloadResult(
          localPath: output.path,
          downloadedBytes: existingBytes,
          totalBytes: existingBytes,
          cachedCount: 1,
          totalCount: 1,
        );
      }
      if (await partial.exists()) await partial.delete();
      return _downloadProbed(item, uri, directory, client, generation);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('mpegurl') || contentType.contains('m3u8')) {
      final bytes = await _readBoundedDownloadBody(response, uri);
      final manifest = utf8.decode(bytes, allowMalformed: true);
      if (await partial.exists()) await partial.delete();
      return _downloadHlsManifest(
        item,
        uri,
        manifest,
        directory,
        client,
        generation,
      );
    }
    return _downloadDirectResponse(
      item,
      uri,
      directory,
      response,
      generation,
      existingBytes: existingBytes,
    );
  }

  Future<_DownloadResult> _downloadDirectResponse(
    DownloadItem item,
    Uri uri,
    Directory directory,
    http.StreamedResponse response,
    int generation, {
    required int existingBytes,
  }) async {
    final extension = _safeExtension(uri.path, fallback: '.mp4');
    final partial = File('${directory.path}/video$extension.part');
    final output = File('${directory.path}/video$extension');
    final range = validateDownloadResponseRange(
      statusCode: response.statusCode,
      existingBytes: existingBytes,
      contentRange: response.headers['content-range'],
      contentLength: response.contentLength,
    );
    final resumed = range.append;
    if (!resumed && await partial.exists()) await partial.delete();
    var downloaded = resumed ? existingBytes : 0;
    var receivedBodyBytes = 0;
    final sink = partial.openWrite(
      mode: resumed ? FileMode.append : FileMode.write,
    );
    try {
      await for (final chunk in withDownloadIdleTimeout(response.stream)) {
        _ensureRunning(item.id, generation);
        sink.add(chunk);
        downloaded += chunk.length;
        receivedBodyBytes += chunk.length;
        await _updateProgress(
          item.id,
          downloadedBytes: downloaded,
          totalBytes: _responseTotalBytes(response, downloaded, existingBytes),
        );
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    _ensureRunning(item.id, generation);
    final finalLength = await partial.length();
    if ((range.expectedBodyBytes != null &&
            receivedBodyBytes != range.expectedBodyBytes) ||
        (range.totalBytes != null && finalLength != range.totalBytes)) {
      if (resumed) {
        final handle = await partial.open(mode: FileMode.append);
        try {
          await handle.truncate(existingBytes);
        } finally {
          await handle.close();
        }
      } else if (await partial.exists()) {
        await partial.delete();
      }
      throw HttpException('下载响应长度不完整', uri: uri);
    }
    if (await output.exists()) await output.delete();
    await partial.rename(output.path);
    final totalBytes = _responseTotalBytes(response, downloaded, existingBytes);
    return _DownloadResult(
      localPath: output.path,
      downloadedBytes: downloaded,
      totalBytes: totalBytes > 0 ? totalBytes : downloaded,
      cachedCount: 1,
      totalCount: 1,
    );
  }

  Future<_DownloadResult> _downloadHls(
    DownloadItem item,
    Uri uri,
    Directory directory,
    http.Client client,
    int generation,
  ) async {
    _validateRemoteUri(uri);
    final manifest = await _loadText(uri, client);
    return _downloadHlsManifest(
      item,
      uri,
      manifest,
      directory,
      client,
      generation,
    );
  }

  Future<_DownloadResult> _downloadHlsManifest(
    DownloadItem item,
    Uri initialUri,
    String initialManifest,
    Directory directory,
    http.Client client,
    int generation,
  ) async {
    var manifestUri = initialUri;
    var manifest = initialManifest;
    OfflineHlsVariant? selectedVariant;
    OfflineHlsRendition? selectedAudio;
    for (var depth = 0; depth < 4; depth++) {
      final variant = selectHighestBandwidthHlsVariant(manifest, manifestUri);
      if (variant == null) break;
      selectedVariant = variant;
      selectedAudio = variant.audioGroup.isEmpty
          ? null
          : selectHlsMediaRendition(
              manifest,
              manifestUri,
              type: 'AUDIO',
              groupId: variant.audioGroup,
            );
      manifestUri = variant.uri;
      _validateRemoteUri(manifestUri);
      manifest = await _loadText(manifestUri, client);
    }
    if (!manifest.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('播放列表格式无效');
    }

    final videoManifest = parseOfflineHlsMediaPlaylist(manifest, manifestUri);
    OfflineHlsManifest? audioManifest;
    if (selectedAudio != null) {
      _validateRemoteUri(selectedAudio.uri);
      audioManifest = parseOfflineHlsMediaPlaylist(
        await _loadText(selectedAudio.uri, client),
        selectedAudio.uri,
        segmentPrefix: 'audio_segment',
        assetPrefix: 'audio_asset',
      );
    }
    if (videoManifest.resources.isEmpty ||
        (selectedAudio != null && audioManifest!.resources.isEmpty)) {
      throw const FormatException('播放列表没有可下载的媒体分片');
    }
    final hasExternalAudio = selectedAudio != null && audioManifest != null;
    final videoDirectory = hasExternalAudio
        ? Directory('${directory.path}/video')
        : directory;
    final audioDirectory = hasExternalAudio
        ? Directory('${directory.path}/audio')
        : null;
    await videoDirectory.create(recursive: true);
    await audioDirectory?.create(recursive: true);
    final resources = <({OfflineHlsResource resource, Directory directory})>[
      for (final resource in videoManifest.resources)
        (resource: resource, directory: videoDirectory),
      if (audioManifest != null && audioDirectory != null)
        for (final resource in audioManifest.resources)
          (resource: resource, directory: audioDirectory),
    ];
    await _updateProgress(
      item.id,
      cachedCount: 0,
      totalCount: resources.length,
      forcePersist: true,
    );

    var downloadedBytes = 0;
    var completed = 0;
    for (
      var start = 0;
      start < resources.length;
      start += _hlsParallelSegments
    ) {
      _ensureRunning(item.id, generation);
      final batch = resources.skip(start).take(_hlsParallelSegments);
      final sizes = await Future.wait([
        for (final entry in batch)
          _downloadHlsResource(
            entry.resource,
            entry.directory,
            client,
            item.id,
            generation,
          ),
      ]);
      downloadedBytes += sizes.fold<int>(0, (sum, size) => sum + size);
      completed += sizes.length;
      await _updateProgress(
        item.id,
        downloadedBytes: downloadedBytes,
        cachedCount: completed,
        totalCount: resources.length,
      );
    }
    _ensureRunning(item.id, generation);
    final playlist = File('${directory.path}/index.m3u8');
    if (hasExternalAudio) {
      await File(
        '${videoDirectory.path}/index.m3u8',
      ).writeAsString(videoManifest.lines.join('\n'), flush: true);
      await File(
        '${audioDirectory!.path}/index.m3u8',
      ).writeAsString(audioManifest.lines.join('\n'), flush: true);
      await playlist.writeAsString(
        [
          '#EXTM3U',
          selectedAudio.localLine('audio/index.m3u8'),
          selectedVariant!.streamInfLine,
          'video/index.m3u8',
        ].join('\n'),
        flush: true,
      );
    } else {
      await playlist.writeAsString(videoManifest.lines.join('\n'), flush: true);
    }
    return _DownloadResult(
      localPath: playlist.path,
      downloadedBytes: downloadedBytes,
      totalBytes: downloadedBytes,
      cachedCount: resources.length,
      totalCount: resources.length,
    );
  }

  Future<int> _downloadHlsResource(
    OfflineHlsResource resource,
    Directory directory,
    http.Client client,
    String itemId,
    int generation,
  ) async {
    _ensureRunning(itemId, generation);
    _validateRemoteUri(resource.uri);
    final file = File('${directory.path}/${resource.fileName}');
    final expectedRangeBytes = _rangeLength(resource.range);
    if (await file.exists()) {
      final existingLength = await file.length();
      if (existingLength > 0 &&
          (expectedRangeBytes == null ||
              existingLength == expectedRangeBytes)) {
        return existingLength;
      }
      await file.delete();
    }
    final request = http.Request('GET', resource.uri)
      ..headers.addAll(_headers(resource.uri));
    if (resource.range != null) {
      request.headers['Range'] = resource.range!;
    }
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    validateHlsResourceResponseStatus(
      requestedRange: resource.range != null,
      statusCode: response.statusCode,
    );
    if (resource.range != null) {
      validateExplicitByteRangeResponse(
        requestedRange: resource.range!,
        contentRange: response.headers['content-range'],
        contentLength: response.contentLength,
      );
    }
    final partial = File('${file.path}.part');
    if (await partial.exists()) await partial.delete();
    var downloaded = 0;
    final sink = partial.openWrite();
    try {
      await for (final chunk in withDownloadIdleTimeout(response.stream)) {
        _ensureRunning(itemId, generation);
        sink.add(chunk);
        downloaded += chunk.length;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    _ensureRunning(itemId, generation);
    if (expectedRangeBytes != null && downloaded != expectedRangeBytes) {
      if (await partial.exists()) await partial.delete();
      throw HttpException('分片 Range 长度不完整', uri: resource.uri);
    }
    if (await file.exists()) await file.delete();
    await partial.rename(file.path);
    return downloaded;
  }

  int? _rangeLength(String? range) {
    if (range == null) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
    final start = int.tryParse(match?.group(1) ?? '');
    final end = int.tryParse(match?.group(2) ?? '');
    if (start == null || end == null || end < start) return null;
    return end - start + 1;
  }

  Future<String> _loadText(Uri uri, http.Client client) async {
    final request = http.Request('GET', uri)..headers.addAll(_headers(uri));
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final bytes = await _readBoundedDownloadBody(response, uri);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<List<int>> _readBoundedDownloadBody(
    http.StreamedResponse response,
    Uri uri,
  ) async {
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > _maxTextDownloadBytes) {
      throw HttpException('下载文本响应过大', uri: uri);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in withDownloadIdleTimeout(response.stream)) {
      if (bytes.length + chunk.length > _maxTextDownloadBytes) {
        throw HttpException('下载文本响应过大', uri: uri);
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _updateProgress(
    String id, {
    int? downloadedBytes,
    int? totalBytes,
    int? cachedCount,
    int? totalCount,
    bool forcePersist = false,
  }) async {
    final item = _find(id);
    if (item == null || item.status == 'paused') return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = item.copyWith(
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      cachedCount: cachedCount,
      totalCount: totalCount,
      updatedAtMs: now,
    );
    _items = [
      for (final entry in _items)
        if (entry.id == id) updated else entry,
    ];
    notifyListeners();
    final lastPersisted = _lastProgressPersistAt[id] ?? 0;
    if (forcePersist || now - lastPersisted >= _progressPersistIntervalMs) {
      _lastProgressPersistAt[id] = now;
      await _storage.saveDownloadItem(updated);
    }
  }

  Future<void> _replace(DownloadItem item) async {
    if (_find(item.id) == null) return;
    _items = [
      for (final entry in _items)
        if (entry.id == item.id) item else entry,
    ];
    await _storage.saveDownloadItem(item);
    notifyListeners();
  }

  DownloadItem? _find(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  bool _isTaskCurrent(String id, int generation) {
    final item = _find(id);
    return item != null &&
        item.status == 'downloading' &&
        _taskGenerations[id] == generation;
  }

  void _ensureRunning(String id, int generation) {
    final item = _find(id);
    if (item == null ||
        item.status != 'downloading' ||
        _taskGenerations[id] != generation) {
      throw const _DownloadPaused();
    }
  }

  Future<void> _waitForTask(String id) async {
    final task = _taskFutures[id];
    if (task == null) return;
    try {
      await task;
    } catch (_) {
      // The task state is reconciled by _run; cancellation may close sockets.
    }
  }

  Future<bool> _validateLocalHlsPlaylist(
    File playlist,
    String resolvedRoot,
    Set<String> visited,
  ) async {
    final resolvedPlaylist = await playlist.resolveSymbolicLinks();
    if (!visited.add(resolvedPlaylist)) return true;
    if (!_isWithinDirectory(resolvedRoot, resolvedPlaylist)) return false;
    final manifest = await playlist.readAsString();
    if (!manifest.trimLeft().startsWith('#EXTM3U')) return false;
    final references = <String>[];
    for (final original in const LineSplitter().convert(manifest)) {
      final line = original.trim();
      if (line.isEmpty) continue;
      if (!line.startsWith('#')) {
        references.add(line);
      }
      for (final match in RegExp(r'URI="([^"]+)"').allMatches(line)) {
        references.add(match.group(1)!);
      }
    }
    for (final reference in references) {
      final uri = Uri.tryParse(reference);
      if (uri == null) return false;
      if (uri.scheme == 'data') continue;
      if (uri.hasScheme || uri.hasAuthority) return false;
      final relativePath = Uri.decodeComponent(uri.path);
      final target = File('${playlist.parent.path}/$relativePath');
      if (!await target.exists() || await target.length() <= 0) return false;
      final resolvedTarget = await target.resolveSymbolicLinks();
      if (!_isWithinDirectory(resolvedRoot, resolvedTarget)) return false;
      if (target.path.toLowerCase().endsWith('.m3u8') &&
          !await _validateLocalHlsPlaylist(target, resolvedRoot, visited)) {
        return false;
      }
    }
    return true;
  }

  bool _isWithinDirectory(String root, String path) {
    final normalizedRoot = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    return path == root || path.startsWith(normalizedRoot);
  }

  Future<Directory> _itemDirectory(String id) async {
    final root = _rootDirectory;
    if (root == null) throw StateError('download manager is not initialized');
    final directory = Directory('${root.path}/${_safeDirectoryName(id)}');
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _deleteItemDirectory(String id) async {
    final root = _rootDirectory;
    if (root == null) return;
    final directory = Directory('${root.path}/${_safeDirectoryName(id)}');
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Map<String, String> _headers(Uri uri, {String referer = ''}) {
    final origin = uri.host.isEmpty ? '' : '${uri.scheme}://${uri.host}/';
    return {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
      'Referer': referer.isNotEmpty
          ? referer
          : origin.isNotEmpty
          ? origin
          : 'https://www.yinhuadm.xyz/',
    };
  }

  void _validateRemoteUri(Uri uri) {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw FormatException('不支持的下载地址：${uri.scheme}');
    }
  }

  int _responseTotalBytes(
    http.StreamedResponse response,
    int downloaded,
    int existingBytes,
  ) {
    final contentRange = response.headers['content-range'];
    final totalMatch = contentRange == null
        ? null
        : RegExp(r'/([0-9]+)$').firstMatch(contentRange);
    final rangeTotal = int.tryParse(totalMatch?.group(1) ?? '');
    if (rangeTotal != null && rangeTotal > 0) return rangeTotal;
    final length = response.contentLength;
    if (length == null || length <= 0) return 0;
    return response.statusCode == HttpStatus.partialContent
        ? existingBytes + length
        : length;
  }

  bool _looksLikeHls(Uri uri) {
    return uri.path.toLowerCase().endsWith('.m3u8');
  }

  String _safeExtension(String path, {required String fallback}) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return fallback;
    final extension = name.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,6}$').hasMatch(extension)
        ? extension
        : fallback;
  }

  String _safeDirectoryName(String value) {
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  String _friendlyError(Object error) {
    if (error is _DownloadPaused) return '已暂停';
    if (error is TimeoutException) return '下载超时，请稍后继续';
    if (error is SocketException) return '网络连接失败，请稍后继续';
    if (error is HttpException) return error.message;
    if (error is FormatException) return error.message;
    final text = error.toString().trim();
    return text.isEmpty ? '下载失败，请重试' : text;
  }
}

class _DownloadResult {
  const _DownloadResult({
    required this.localPath,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.cachedCount,
    required this.totalCount,
  });

  final String localPath;
  final int downloadedBytes;
  final int totalBytes;
  final int cachedCount;
  final int totalCount;
}

class _DownloadPaused implements Exception {
  const _DownloadPaused();
}
