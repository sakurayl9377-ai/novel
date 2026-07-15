import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.notes,
    this.sha256 = '',
    this.force = false,
  });

  final String versionName;
  final int versionCode;
  final String apkUrl;
  final String sha256;
  final bool force;
  final List<String> notes;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      versionName: _asString(json['versionName'] ?? json['version']),
      versionCode: _asInt(json['versionCode'] ?? json['buildNumber']),
      apkUrl: _asString(json['apkUrl'] ?? json['url']),
      sha256: _asString(json['sha256']).toLowerCase(),
      force: json['force'] == true,
      notes: _asStringList(json['notes'] ?? json['changelog']),
    );
  }
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.currentVersionName,
    required this.currentVersionCode,
    required this.hasUpdate,
    this.update,
  });

  final String currentVersionName;
  final int currentVersionCode;
  final bool hasUpdate;
  final AppUpdateInfo? update;
}

class AppUpdateService {
  AppUpdateService({
    this.httpClient,
    Future<Directory> Function()? temporaryDirectoryProvider,
    int parallelDownloadParts = 4,
    int parallelDownloadThresholdBytes = 16 * 1024 * 1024,
    int minimumParallelPartBytes = 8 * 1024 * 1024,
    Duration requestHeaderTimeout = const Duration(seconds: 20),
    Duration requestAbortSettleTimeout = const Duration(seconds: 2),
  }) : _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _parallelDownloadParts = parallelDownloadParts,
       _parallelDownloadThresholdBytes = parallelDownloadThresholdBytes,
       _minimumParallelPartBytes = minimumParallelPartBytes,
       _requestHeaderTimeout = requestHeaderTimeout,
       _requestAbortSettleTimeout = requestAbortSettleTimeout,
       assert(parallelDownloadParts >= 2),
       assert(parallelDownloadThresholdBytes > 0),
       assert(minimumParallelPartBytes > 0),
       assert(requestHeaderTimeout > Duration.zero),
       assert(requestAbortSettleTimeout > Duration.zero);

  static const String updateJsonUrl =
      'https://novel.kxhub.xyz/app3/version.json';
  static const Duration _responseIdleTimeout = Duration(seconds: 30);
  static const Duration _progressNotificationInterval = Duration(
    milliseconds: 100,
  );
  static const int _maxUpdateMetadataBytes = 64 * 1024;
  static const int _maxApkBytes = 256 * 1024 * 1024;
  static const int _parallelRequestAttempts = 2;
  static const MethodChannel _channel = MethodChannel(
    'com.novel.novel_app/app_update',
  );
  static final Map<String, _ApkDownloadFlight> _activeDownloads = {};
  static final Map<String, Future<void>> _activeInstalls = {};

  final http.Client? httpClient;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final int _parallelDownloadParts;
  final int _parallelDownloadThresholdBytes;
  final int _minimumParallelPartBytes;
  final Duration _requestHeaderTimeout;
  final Duration _requestAbortSettleTimeout;

  Future<AppUpdateCheckResult> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentCode = int.tryParse(packageInfo.buildNumber) ?? 0;
    final response = await _get(
      Uri.parse(updateJsonUrl),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Update check failed: ${response.statusCode}');
    }

    final body = _decodeBody(response);
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw Exception('Update config is not JSON');
    }
    if (decoded is! Map) {
      throw Exception('Invalid update config');
    }
    final update = AppUpdateInfo.fromJson(decoded.cast<String, dynamic>());
    if (_trustedApkUri(update.apkUrl) == null ||
        !_isSha256(update.sha256) ||
        update.versionName.isEmpty ||
        update.versionCode <= 0) {
      throw Exception('Invalid update config');
    }

    return AppUpdateCheckResult(
      currentVersionName: packageInfo.version,
      currentVersionCode: currentCode,
      hasUpdate: update.versionCode > currentCode,
      update: update,
    );
  }

  Future<File> downloadApk(
    AppUpdateInfo update, {
    void Function(int received, int total)? onProgress,
  }) async {
    final apkUri = _trustedApkUri(update.apkUrl);
    if (apkUri == null || !_isSha256(update.sha256)) {
      throw Exception('Invalid update config');
    }
    final file = await _apkFileFor(update);
    final key = file.absolute.path;
    final active = _activeDownloads[key];
    if (active != null) return active.subscribe(onProgress);

    final flight = _ApkDownloadFlight();
    final progress = _ThrottledDownloadProgress(
      flight.report,
      interval: _progressNotificationInterval,
    );
    flight.future = _downloadApkInternal(
      update: update,
      apkUri: apkUri,
      file: file,
      progress: progress,
    );
    _activeDownloads[key] = flight;
    try {
      return await flight.subscribe(onProgress);
    } finally {
      if (identical(_activeDownloads[key], flight)) {
        _activeDownloads.remove(key);
      }
    }
  }

  Future<File> _downloadApkInternal({
    required AppUpdateInfo update,
    required Uri apkUri,
    required File file,
    required _ThrottledDownloadProgress progress,
  }) async {
    if (await _isValidApk(file, update)) {
      final length = await file.length();
      progress.report(length, length, force: true);
      return file;
    }

    final partialFile = File('${file.path}.download');
    if (await _isValidApk(partialFile, update)) {
      await _replaceFile(partialFile, file);
      final length = await file.length();
      progress.report(length, length, force: true);
      return file;
    }

    final client = httpClient ?? http.Client();
    final closeClient = httpClient == null;
    try {
      final partialBytes = await partialFile.exists()
          ? await partialFile.length()
          : 0;
      if (partialBytes <= 0) {
        final probe = await _probeApk(client, apkUri);
        final fullResponse = probe.fullResponse;
        if (fullResponse != null) {
          return _downloadSingleApk(
            client: client,
            apkUri: apkUri,
            update: update,
            file: file,
            partialFile: partialFile,
            progress: progress,
            initialResponse: fullResponse,
          );
        }
        final totalBytes = probe.totalBytes;
        if (totalBytes != null && _shouldUseParallelDownload(totalBytes)) {
          try {
            return await _downloadParallelApk(
              client: client,
              apkUri: apkUri,
              update: update,
              file: file,
              partialFile: partialFile,
              totalBytes: totalBytes,
              progress: progress,
            );
          } on _ParallelRangeUnsupported {
            // Some CDNs advertise or probe as range-capable but ignore a
            // later range. All part writers have stopped before this fallback.
          }
        }
      }

      return _downloadSingleApk(
        client: client,
        apkUri: apkUri,
        update: update,
        file: file,
        partialFile: partialFile,
        progress: progress,
      );
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<_ApkProbe> _probeApk(http.Client client, Uri apkUri) async {
    final response = await _sendApkRequest(client, apkUri, range: 'bytes=0-0');
    if (!_usesIdentityEncoding(response)) {
      await _cancelResponse(response);
      throw Exception('APK response uses unsupported content encoding');
    }
    if (response.statusCode == 200) {
      final declared = response.contentLength;
      if (declared != null && declared > _maxApkBytes) {
        await _cancelResponse(response);
        throw Exception('APK is too large');
      }
      return _ApkProbe(fullResponse: response);
    }
    if (response.statusCode != 206) {
      await _cancelResponse(response);
      throw Exception('APK range probe failed: ${response.statusCode}');
    }

    final returned = _parseContentRange(response.headers['content-range']);
    if (returned == null ||
        returned.start != 0 ||
        returned.end != 0 ||
        returned.total <= 0 ||
        returned.total > _maxApkBytes ||
        response.contentLength != 1) {
      await _cancelResponse(response);
      throw Exception('APK range probe returned invalid metadata');
    }
    var received = 0;
    await for (final chunk in response.stream.timeout(_responseIdleTimeout)) {
      received += chunk.length;
      if (received > 1) {
        throw Exception('APK range probe returned too much data');
      }
    }
    if (received != 1) {
      throw Exception('APK range probe returned incomplete data');
    }
    return _ApkProbe(totalBytes: returned.total);
  }

  bool _shouldUseParallelDownload(int totalBytes) {
    if (totalBytes < _parallelDownloadThresholdBytes) return false;
    return totalBytes ~/ _parallelDownloadParts >= _minimumParallelPartBytes;
  }

  Future<File> _downloadParallelApk({
    required http.Client client,
    required Uri apkUri,
    required AppUpdateInfo update,
    required File file,
    required File partialFile,
    required int totalBytes,
    required _ThrottledDownloadProgress progress,
  }) async {
    final ranges = List<_ApkByteRange>.generate(_parallelDownloadParts, (
      index,
    ) {
      final start = (totalBytes * index) ~/ _parallelDownloadParts;
      final end = (totalBytes * (index + 1)) ~/ _parallelDownloadParts - 1;
      return _ApkByteRange(start, end);
    });
    final partFiles = [
      for (final range in ranges)
        File('${file.path}.download.part-${range.start}-${range.end}'),
    ];
    final initialLengths = <int>[];
    for (var index = 0; index < partFiles.length; index++) {
      final partFile = partFiles[index];
      var length = await partFile.exists() ? await partFile.length() : 0;
      if (length < 0 || length > ranges[index].length) {
        await partFile.delete();
        length = 0;
      }
      initialLengths.add(length);
    }

    final aggregate = _ParallelDownloadProgress(
      initialLengths: initialLengths,
      ranges: ranges,
      totalBytes: totalBytes,
      progress: progress,
    );
    aggregate.notifyInitial();
    final cancellation = _DownloadCancellation();
    final outcomes = await Future.wait([
      for (var index = 0; index < ranges.length; index++)
        () async {
          try {
            await _downloadRangePartWithRetry(
              client: client,
              apkUri: apkUri,
              range: ranges[index],
              partFile: partFiles[index],
              partIndex: index,
              totalBytes: totalBytes,
              progress: aggregate,
              cancellation: cancellation,
            );
            return null;
          } catch (error, stackTrace) {
            final failure = _PartDownloadFailure(error, stackTrace);
            cancellation.fail(failure);
            return failure;
          }
        }(),
    ]);
    final failures = outcomes.whereType<_PartDownloadFailure>().toList();
    if (failures.isNotEmpty) {
      final primary = cancellation.firstFailure ?? failures.first;
      if (primary.error is _ParallelRangeUnsupported) {
        await _deleteFiles(partFiles);
      }
      Error.throwWithStackTrace(primary.error, primary.stackTrace);
    }

    for (var index = 0; index < partFiles.length; index++) {
      if (!await partFiles[index].exists() ||
          await partFiles[index].length() != ranges[index].length) {
        throw Exception('APK range part is incomplete');
      }
    }

    final mergeFile = File('${file.path}.merge');
    if (await mergeFile.exists()) await mergeFile.delete();
    final sink = mergeFile.openWrite(mode: FileMode.write);
    try {
      for (final partFile in partFiles) {
        await sink.addStream(partFile.openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await mergeFile.length() != totalBytes ||
        !await _isValidApk(mergeFile, update)) {
      await _deleteFiles([mergeFile, ...partFiles]);
      throw Exception('APK checksum mismatch');
    }

    await _replaceFile(mergeFile, file);
    await _deleteFiles(partFiles);
    if (await partialFile.exists()) await partialFile.delete();
    progress.report(totalBytes, totalBytes, force: true);
    return file;
  }

  Future<void> _downloadRangePartWithRetry({
    required http.Client client,
    required Uri apkUri,
    required _ApkByteRange range,
    required File partFile,
    required int partIndex,
    required int totalBytes,
    required _ParallelDownloadProgress progress,
    required _DownloadCancellation cancellation,
  }) async {
    for (var attempt = 0; attempt < _parallelRequestAttempts; attempt++) {
      if (cancellation.isCancelled) {
        throw http.RequestAbortedException(apkUri);
      }
      try {
        await _downloadRangePartOnce(
          client: client,
          apkUri: apkUri,
          range: range,
          partFile: partFile,
          partIndex: partIndex,
          totalBytes: totalBytes,
          progress: progress,
          cancellation: cancellation,
        );
        return;
      } catch (error, stackTrace) {
        if (error is _ParallelRangeUnsupported ||
            error is http.RequestAbortedException ||
            cancellation.isCancelled) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        final retryable =
            error is TimeoutException ||
            error is SocketException ||
            error is http.ClientException ||
            error is _IncompleteRangeResponse;
        if (!retryable || attempt + 1 >= _parallelRequestAttempts) {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }
  }

  Future<void> _downloadRangePartOnce({
    required http.Client client,
    required Uri apkUri,
    required _ApkByteRange range,
    required File partFile,
    required int partIndex,
    required int totalBytes,
    required _ParallelDownloadProgress progress,
    required _DownloadCancellation cancellation,
  }) async {
    var existingBytes = await partFile.exists() ? await partFile.length() : 0;
    if (existingBytes > range.length) {
      await partFile.delete();
      existingBytes = 0;
      progress.setPartBytes(partIndex, 0);
    }
    if (existingBytes == range.length) return;

    final requestStart = range.start + existingBytes;
    final requestedRange = 'bytes=$requestStart-${range.end}';
    final response = await _sendApkRequest(
      client,
      apkUri,
      range: requestedRange,
      cancellation: cancellation.whenCancelled,
    );
    if (!_usesIdentityEncoding(response)) {
      await _cancelResponse(response);
      throw Exception('APK response uses unsupported content encoding');
    }
    if (response.statusCode != 206) {
      await _cancelResponse(response);
      if (response.statusCode == 200 || response.statusCode == 416) {
        throw const _ParallelRangeUnsupported();
      }
      throw Exception('APK range download failed: ${response.statusCode}');
    }

    final returned = _parseContentRange(response.headers['content-range']);
    final expectedBodyBytes = range.end - requestStart + 1;
    if (returned == null ||
        returned.start != requestStart ||
        returned.end != range.end ||
        returned.total != totalBytes ||
        response.contentLength != expectedBodyBytes) {
      await _cancelResponse(response);
      throw Exception('APK range response is invalid');
    }

    final sink = partFile.openWrite(
      mode: existingBytes > 0 ? FileMode.append : FileMode.write,
    );
    var bodyBytes = 0;
    try {
      await for (final chunk in response.stream.timeout(_responseIdleTimeout)) {
        if (cancellation.isCancelled) {
          throw http.RequestAbortedException(apkUri);
        }
        if (bodyBytes + chunk.length > expectedBodyBytes) {
          throw Exception('APK range response is longer than declared');
        }
        sink.add(chunk);
        bodyBytes += chunk.length;
        progress.addPartBytes(partIndex, chunk.length);
      }
    } finally {
      await sink.close();
    }
    if (bodyBytes != expectedBodyBytes) {
      throw const _IncompleteRangeResponse();
    }
  }

  Future<File> _downloadSingleApk({
    required http.Client client,
    required Uri apkUri,
    required AppUpdateInfo update,
    required File file,
    required File partialFile,
    required _ThrottledDownloadProgress progress,
    http.StreamedResponse? initialResponse,
    bool allowRangeRestart = true,
  }) async {
    var resumeFrom = await partialFile.exists()
        ? await partialFile.length()
        : 0;
    if (resumeFrom < 0 || resumeFrom > _maxApkBytes) {
      if (await partialFile.exists()) await partialFile.delete();
      resumeFrom = 0;
    }
    if (initialResponse != null && resumeFrom > 0) {
      await _cancelResponse(initialResponse);
      initialResponse = null;
    }

    final requestedResume = resumeFrom > 0;
    final response =
        initialResponse ??
        await _sendApkRequest(
          client,
          apkUri,
          range: requestedResume ? 'bytes=$resumeFrom-' : null,
        );
    if (!_usesIdentityEncoding(response)) {
      await _cancelResponse(response);
      throw Exception('APK response uses unsupported content encoding');
    }
    if (response.statusCode == 416) {
      await _cancelResponse(response);
      if (await _isValidApk(partialFile, update)) {
        await _replaceFile(partialFile, file);
        final length = await file.length();
        progress.report(length, length, force: true);
        return file;
      }
      if (requestedResume && allowRangeRestart) {
        if (await partialFile.exists()) await partialFile.delete();
        return _downloadSingleApk(
          client: client,
          apkUri: apkUri,
          update: update,
          file: file,
          partialFile: partialFile,
          progress: progress,
          allowRangeRestart: false,
        );
      }
      throw Exception('APK download failed: 416');
    }

    var append = false;
    int? expectedBodyBytes;
    int? totalBytes;
    if (requestedResume && response.statusCode == 206) {
      final returned = _parseContentRange(response.headers['content-range']);
      if (returned == null ||
          returned.start != resumeFrom ||
          returned.end != returned.total - 1 ||
          returned.total > _maxApkBytes) {
        await _cancelResponse(response);
        throw Exception('APK resumed response is invalid');
      }
      expectedBodyBytes = returned.end - returned.start + 1;
      if (response.contentLength != expectedBodyBytes) {
        await _cancelResponse(response);
        throw Exception('APK resumed response length is invalid');
      }
      append = true;
      totalBytes = returned.total;
    } else if (response.statusCode == 200) {
      if (requestedResume && await partialFile.exists()) {
        await partialFile.delete();
      }
      resumeFrom = 0;
      expectedBodyBytes = response.contentLength;
      totalBytes = response.contentLength;
      if (totalBytes != null && totalBytes > _maxApkBytes) {
        await _cancelResponse(response);
        throw Exception('APK is too large');
      }
    } else {
      await _cancelResponse(response);
      throw Exception('APK download failed: ${response.statusCode}');
    }

    final sink = partialFile.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var bodyBytes = 0;
    var received = resumeFrom;
    if (totalBytes != null) {
      progress.report(received, totalBytes, force: true);
    }
    try {
      await for (final chunk in response.stream.timeout(_responseIdleTimeout)) {
        if (bodyBytes + chunk.length > (expectedBodyBytes ?? _maxApkBytes) ||
            received + chunk.length > _maxApkBytes) {
          throw Exception('APK response is longer than declared');
        }
        sink.add(chunk);
        bodyBytes += chunk.length;
        received += chunk.length;
        if (totalBytes != null) {
          progress.report(received, totalBytes);
        }
      }
    } finally {
      await sink.close();
    }
    if (expectedBodyBytes != null && bodyBytes != expectedBodyBytes) {
      throw Exception('APK response ended early');
    }
    if (!await _isValidApk(partialFile, update)) {
      if (await partialFile.exists()) await partialFile.delete();
      throw Exception('APK checksum mismatch');
    }

    await _replaceFile(partialFile, file);
    final length = await file.length();
    progress.report(length, length, force: true);
    return file;
  }

  Future<http.StreamedResponse> _sendApkRequest(
    http.Client client,
    Uri apkUri, {
    String? range,
    Future<void>? cancellation,
  }) async {
    final attemptAbort = Completer<void>();
    final abortTrigger = cancellation == null
        ? attemptAbort.future
        : Future.any<void>([attemptAbort.future, cancellation]);
    final request = http.AbortableRequest(
      'GET',
      apkUri,
      abortTrigger: abortTrigger,
    )..followRedirects = false;
    request.headers.addAll(_apkRequestHeaders(range: range));
    final operation = client.send(request);
    try {
      return await operation.timeout(_requestHeaderTimeout);
    } on TimeoutException catch (error, stackTrace) {
      if (!attemptAbort.isCompleted) attemptAbort.complete();
      try {
        final lateResponse = await operation.timeout(
          _requestAbortSettleTimeout,
          onTimeout: () => throw const _RequestAbortDidNotSettle(),
        );
        await _cancelResponse(lateResponse);
      } on _RequestAbortDidNotSettle {
        unawaited(
          operation.then<void>(
            _cancelResponse,
            onError: (Object _, StackTrace _) {},
          ),
        );
        rethrow;
      } catch (_) {
        // The aborted request settled with an error, so retrying cannot leave
        // a previous request consuming the same byte range in the background.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Map<String, String> _apkRequestHeaders({String? range}) {
    final headers = {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
          'Chrome/125.0 Mobile Safari/537.36',
      'Accept-Encoding': 'identity',
    };
    if (range != null) headers['Range'] = range;
    return headers;
  }

  _ContentRange? _parseContentRange(String? value) {
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(value?.trim() ?? '');
    final start = int.tryParse(match?.group(1) ?? '');
    final end = int.tryParse(match?.group(2) ?? '');
    final total = int.tryParse(match?.group(3) ?? '');
    if (start == null ||
        end == null ||
        total == null ||
        start < 0 ||
        end < start ||
        total <= end) {
      return null;
    }
    return _ContentRange(start: start, end: end, total: total);
  }

  bool _usesIdentityEncoding(http.StreamedResponse response) {
    final encoding = response.headers['content-encoding']?.trim().toLowerCase();
    return encoding == null || encoding.isEmpty || encoding == 'identity';
  }

  Future<void> _cancelResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen(
      (_) {},
      onError: (_) {},
      cancelOnError: true,
    );
    await subscription.cancel();
  }

  Future<void> _deleteFiles(Iterable<File> files) async {
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best-effort cleanup; the verified destination is never deleted.
      }
    }
  }

  Future<void> installApk(File apkFile) {
    final key = apkFile.absolute.path;
    final active = _activeInstalls[key];
    if (active != null) return active;
    final operation = _channel.invokeMethod<void>('installApk', {
      'path': apkFile.absolute.path,
    });
    _activeInstalls[key] = operation;
    unawaited(
      operation.then<void>(
        (_) {
          Timer(const Duration(seconds: 3), () {
            if (identical(_activeInstalls[key], operation)) {
              _activeInstalls.remove(key);
            }
          });
        },
        onError: (Object _, StackTrace _) {
          if (identical(_activeInstalls[key], operation)) {
            _activeInstalls.remove(key);
          }
        },
      ),
    );
    return operation;
  }

  Future<http.Response> _get(Uri uri) async {
    final client = httpClient ?? http.Client();
    final closeClient = httpClient == null;
    try {
      final request = http.Request('GET', uri)..followRedirects = false;
      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      final declaredLength = streamed.contentLength;
      if (declaredLength != null && declaredLength > _maxUpdateMetadataBytes) {
        throw Exception('Update config is too large');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream.timeout(_responseIdleTimeout)) {
        if (bytes.length + chunk.length > _maxUpdateMetadataBytes) {
          throw Exception('Update config is too large');
        }
        bytes.add(chunk);
      }
      return http.Response.bytes(
        bytes.takeBytes(),
        streamed.statusCode,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
        request: request,
      );
    } finally {
      if (closeClient) client.close();
    }
  }

  String _decodeBody(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    }
  }

  Future<File> _apkFileFor(AppUpdateInfo update) async {
    final dir = await _temporaryDirectoryProvider();
    final hashLength = update.sha256.length < 12 ? update.sha256.length : 12;
    final hashPart = update.sha256.isNotEmpty
        ? '-${update.sha256.substring(0, hashLength)}'
        : '';
    return File('${dir.path}/sakura-${update.versionCode}$hashPart.apk');
  }

  Future<bool> _isValidApk(File file, AppUpdateInfo update) async {
    if (!await file.exists()) return false;
    if (await file.length() <= 0) return false;
    if (update.sha256.isEmpty) return false;
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == update.sha256;
  }

  Future<void> _replaceFile(File source, File destination) async {
    if (await destination.exists()) {
      await destination.delete();
    }
    await source.rename(destination.path);
  }

  Uri? _trustedApkUri(String value) {
    final uri = Uri.tryParse(value);
    final metadataUri = Uri.parse(updateJsonUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.toLowerCase() != metadataUri.host.toLowerCase() ||
        !uri.path.toLowerCase().endsWith('.apk')) {
      return null;
    }
    return uri;
  }

  bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}

typedef _DownloadProgressCallback = void Function(int received, int total);

class _ApkDownloadFlight {
  late Future<File> future;

  final Set<_DownloadProgressCallback> _listeners = {};
  int? _lastReceived;
  int? _lastTotal;

  Future<File> subscribe(_DownloadProgressCallback? listener) {
    if (listener != null) {
      _listeners.add(listener);
      final received = _lastReceived;
      final total = _lastTotal;
      if (received != null && total != null) {
        scheduleMicrotask(() {
          if (_listeners.contains(listener)) {
            _notify(listener, received, total);
          }
        });
      }
    }
    return future.whenComplete(() {
      if (listener != null) _listeners.remove(listener);
    });
  }

  void report(int received, int total) {
    _lastReceived = received;
    _lastTotal = total;
    for (final listener in List<_DownloadProgressCallback>.of(_listeners)) {
      _notify(listener, received, total);
    }
  }

  void _notify(_DownloadProgressCallback listener, int received, int total) {
    try {
      listener(received, total);
    } catch (_) {
      // A disposed or faulty UI listener must never abort the shared download.
    }
  }
}

class _ThrottledDownloadProgress {
  _ThrottledDownloadProgress(this._callback, {required this.interval}) {
    _stopwatch.start();
  }

  final _DownloadProgressCallback _callback;
  final Duration interval;
  final Stopwatch _stopwatch = Stopwatch();

  bool _hasNotified = false;
  int _lastNotifiedAtMs = 0;
  int _lastReceived = 0;
  int? _lastTotal;

  void report(int received, int total, {bool force = false}) {
    if (total <= 0) return;
    if (_lastTotal != null && _lastTotal != total) {
      _lastReceived = _lastReceived.clamp(0, total);
    }
    final clamped = received.clamp(0, total);
    final monotonic = clamped < _lastReceived ? _lastReceived : clamped;
    _lastReceived = monotonic.clamp(0, total);
    _lastTotal = total;
    final elapsedMs = _stopwatch.elapsedMilliseconds;
    if (!force &&
        _hasNotified &&
        _lastReceived < total &&
        elapsedMs - _lastNotifiedAtMs < interval.inMilliseconds) {
      return;
    }
    _hasNotified = true;
    _lastNotifiedAtMs = elapsedMs;
    _callback(_lastReceived, total);
  }
}

class _ParallelDownloadProgress {
  _ParallelDownloadProgress({
    required List<int> initialLengths,
    required this.ranges,
    required this.totalBytes,
    required this.progress,
  }) : _partBytes = List<int>.of(initialLengths);

  final List<_ApkByteRange> ranges;
  final int totalBytes;
  final _ThrottledDownloadProgress progress;
  final List<int> _partBytes;

  void notifyInitial() =>
      progress.report(_totalReceived, totalBytes, force: true);

  void addPartBytes(int index, int bytes) {
    setPartBytes(index, _partBytes[index] + bytes);
  }

  void setPartBytes(int index, int bytes) {
    _partBytes[index] = bytes.clamp(0, ranges[index].length);
    progress.report(_totalReceived, totalBytes);
  }

  int get _totalReceived => _partBytes.fold<int>(0, (sum, item) => sum + item);
}

class _DownloadCancellation {
  final Completer<void> _completer = Completer<void>();
  _PartDownloadFailure? _firstFailure;

  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;
  _PartDownloadFailure? get firstFailure => _firstFailure;

  void fail(_PartDownloadFailure failure) {
    _firstFailure ??= failure;
    if (!_completer.isCompleted) _completer.complete();
  }
}

class _PartDownloadFailure {
  const _PartDownloadFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

class _ApkProbe {
  const _ApkProbe({this.totalBytes, this.fullResponse});

  final int? totalBytes;
  final http.StreamedResponse? fullResponse;
}

class _ApkByteRange {
  const _ApkByteRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;
}

class _ContentRange {
  const _ContentRange({
    required this.start,
    required this.end,
    required this.total,
  });

  final int start;
  final int end;
  final int total;
}

class _ParallelRangeUnsupported implements Exception {
  const _ParallelRangeUnsupported();
}

class _IncompleteRangeResponse implements Exception {
  const _IncompleteRangeResponse();
}

class _RequestAbortDidNotSettle implements Exception {
  const _RequestAbortDidNotSettle();
}

String _asString(dynamic value) => value?.toString().trim() ?? '';

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<String> _asStringList(dynamic value) {
  if (value is List) {
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
  final text = _asString(value);
  if (text.isEmpty) return const [];
  return text
      .split(RegExp(r'[\r\n]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}
