import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

enum ModaoParallelDownloadStatus {
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

class ModaoPartDownloadTarget {
  const ModaoPartDownloadTarget({
    required this.index,
    required this.url,
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  final int index;
  final Uri url;
  final String path;
  final int sizeBytes;
  final String sha256;

  File get file => File(path);
  File get partialFile => File('$path.download');
}

class ModaoParallelDownloadPlan {
  const ModaoParallelDownloadPlan({
    required this.artifactKey,
    required this.releaseKey,
    required this.totalBytes,
    required this.parts,
  });

  final String artifactKey;
  final String releaseKey;
  final int totalBytes;
  final List<ModaoPartDownloadTarget> parts;
}

class ModaoParallelDownloadSnapshot {
  const ModaoParallelDownloadSnapshot({
    required this.artifactKey,
    required this.releaseKey,
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.partCount,
    this.reason = '',
  });

  final String artifactKey;
  final String releaseKey;
  final ModaoParallelDownloadStatus status;
  final int downloadedBytes;
  final int totalBytes;
  final int partCount;
  final String reason;

  bool get isActive => status == ModaoParallelDownloadStatus.downloading;
}

class ModaoParallelDownloader {
  ModaoParallelDownloader({
    this.httpClient,
    this.requestAttempts = 5,
    this.requestHeaderTimeout = const Duration(seconds: 20),
    this.responseIdleTimeout = const Duration(seconds: 30),
    this.requestAbortSettleTimeout = const Duration(seconds: 2),
    this.slowPartWindow = const Duration(seconds: 15),
    this.minimumHealthyPartBytesPerSecond = 160 * 1024,
    this.minimumSlowPartRemainingBytes = 2 * 1024 * 1024,
  }) : assert(requestAttempts > 0),
       assert(requestHeaderTimeout > Duration.zero),
       assert(responseIdleTimeout > Duration.zero),
       assert(requestAbortSettleTimeout > Duration.zero),
       assert(slowPartWindow > Duration.zero),
       assert(minimumHealthyPartBytesPerSecond > 0),
       assert(minimumSlowPartRemainingBytes >= 0);

  static final Map<String, _ModaoDownloadSession> _sessions = {};

  final http.Client? httpClient;
  final int requestAttempts;
  final Duration requestHeaderTimeout;
  final Duration responseIdleTimeout;
  final Duration requestAbortSettleTimeout;
  final Duration slowPartWindow;
  final int minimumHealthyPartBytesPerSecond;
  final int minimumSlowPartRemainingBytes;

  ModaoParallelDownloadSnapshot? snapshot(
    String artifactKey, {
    required String releaseKey,
  }) => _sessions[_sessionKey(artifactKey, releaseKey)]?.snapshot;

  Future<ModaoParallelDownloadSnapshot> waitForCompletion(
    String artifactKey, {
    required String releaseKey,
  }) async {
    final session = _sessions[_sessionKey(artifactKey, releaseKey)];
    if (session == null) {
      throw StateError('Game download session does not exist');
    }
    await session.future;
    return session.snapshot;
  }

  Future<ModaoParallelDownloadSnapshot> start(
    ModaoParallelDownloadPlan plan, {
    Future<void> Function()? onPartsReady,
  }) async {
    _validatePlan(plan);
    final key = _sessionKey(plan.artifactKey, plan.releaseKey);
    final existing = _sessions[key];
    if (existing != null && existing.snapshot.isActive) {
      return existing.snapshot;
    }

    final session = _ModaoDownloadSession(plan);
    _sessions[key] = session;
    session.future = _runSession(session, onPartsReady: onPartsReady);
    unawaited(session.future);
    return session.snapshot;
  }

  Future<void> cancel(String artifactKey, {required String releaseKey}) async {
    final key = _sessionKey(artifactKey, releaseKey);
    final session = _sessions[key];
    if (session == null) return;
    session.cancel(explicit: true);
    await session.future;
    if (identical(_sessions[key], session)) {
      _sessions.remove(key);
    }
  }

  Future<void> pause(
    String artifactKey, {
    required String releaseKey,
    required String reason,
  }) async {
    final session = _sessions[_sessionKey(artifactKey, releaseKey)];
    if (session == null || !session.snapshot.isActive) return;
    session.pause(reason);
    await session.future;
  }

  Future<void> cancelAllExcept({
    required String artifactKey,
    required String releaseKey,
  }) async {
    final keepKey = _sessionKey(artifactKey, releaseKey);
    final staleEntries = _sessions.entries
        .where((entry) => entry.key != keepKey)
        .map((entry) => MapEntry(entry.key, entry.value))
        .toList(growable: false);

    final activeStaleEntries = <MapEntry<String, _ModaoDownloadSession>>[];
    for (final entry in staleEntries) {
      if (entry.value.snapshot.isActive) {
        activeStaleEntries.add(entry);
      } else if (identical(_sessions[entry.key], entry.value)) {
        _sessions.remove(entry.key);
      }
    }
    await Future.wait(
      activeStaleEntries.map((entry) async {
        final session = entry.value;
        session.cancel(explicit: true);
        await session.future;
        if (identical(_sessions[entry.key], session)) {
          _sessions.remove(entry.key);
        }
      }),
    );
  }

  void forget(String artifactKey, {required String releaseKey}) {
    final key = _sessionKey(artifactKey, releaseKey);
    final session = _sessions[key];
    if (session != null && !session.snapshot.isActive) {
      _sessions.remove(key);
    }
  }

  String _sessionKey(String artifactKey, String releaseKey) =>
      '$artifactKey\u0000$releaseKey';

  Future<void> _runSession(
    _ModaoDownloadSession session, {
    Future<void> Function()? onPartsReady,
  }) async {
    final client = httpClient ?? http.Client();
    final closeClient = httpClient == null;
    try {
      final initialLengths = await Future.wait(
        session.plan.parts.map(_preparePart),
      );
      session.setInitialLengths(initialLengths);
      if (session.cancellation.isCancelled) {
        if (session.cancellation.paused) {
          session.markPaused();
        } else {
          session.markCancelled();
        }
        return;
      }

      final failures = await Future.wait([
        for (var index = 0; index < session.plan.parts.length; index++)
          () async {
            try {
              await _downloadPartWithRetry(
                client: client,
                session: session,
                target: session.plan.parts[index],
                partPosition: index,
              );
              return null;
            } catch (error, stackTrace) {
              if (session.cancellation.intentional) return null;
              final failure = _ModaoPartFailure(error, stackTrace);
              session.fail(failure);
              return failure;
            }
          }(),
      ]);

      if (session.cancellation.explicit) {
        session.markCancelled();
        return;
      }
      if (session.cancellation.paused) {
        session.markPaused();
        return;
      }
      final failure =
          session.firstFailure ??
          failures.whereType<_ModaoPartFailure>().firstOrNull;
      if (failure != null) {
        session.markFailed(_failureMessage(failure.error));
        return;
      }

      if (onPartsReady != null) await onPartsReady();
      session.markCompleted();
    } catch (error) {
      if (session.cancellation.explicit) {
        session.markCancelled();
      } else if (session.cancellation.paused) {
        session.markPaused();
      } else {
        session.markFailed(_failureMessage(error));
      }
    } finally {
      if (closeClient) client.close();
    }
  }

  Future<int> _preparePart(ModaoPartDownloadTarget target) async {
    final finalFile = target.file;
    if (await finalFile.exists()) {
      final length = await finalFile.length();
      if (length == target.sizeBytes &&
          await _hasExpectedSha256(finalFile, target.sha256)) {
        final partial = target.partialFile;
        if (await partial.exists()) await partial.delete();
        return length;
      }
      await finalFile.delete();
    }

    final partial = target.partialFile;
    if (!await partial.exists()) return 0;
    final length = await partial.length();
    if (length < 0 || length > target.sizeBytes) {
      await partial.delete();
      return 0;
    }
    if (length == target.sizeBytes) {
      if (!await _hasExpectedSha256(partial, target.sha256)) {
        await partial.delete();
        return 0;
      }
      await _promotePart(partial, finalFile);
    }
    return length;
  }

  Future<void> _downloadPartWithRetry({
    required http.Client client,
    required _ModaoDownloadSession session,
    required ModaoPartDownloadTarget target,
    required int partPosition,
  }) async {
    for (var attempt = 0; attempt < requestAttempts; attempt++) {
      if (session.cancellation.isCancelled) {
        throw http.RequestAbortedException(target.url);
      }
      try {
        await _downloadPartOnce(
          client: client,
          session: session,
          target: target,
          partPosition: partPosition,
          restartIfSlow: attempt + 1 < requestAttempts,
        );
        return;
      } catch (error, stackTrace) {
        if (error is http.RequestAbortedException ||
            session.cancellation.isCancelled) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        final retryable =
            error is TimeoutException ||
            error is SocketException ||
            error is http.ClientException ||
            error is _RetryablePartStatus ||
            error is _IncompletePartResponse ||
            error is _SlowPartResponse ||
            error is _PartChecksumMismatch;
        if (!retryable || attempt + 1 >= requestAttempts) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        await _retryDelay(attempt, session.cancellation);
      }
    }
  }

  Future<void> _downloadPartOnce({
    required http.Client client,
    required _ModaoDownloadSession session,
    required ModaoPartDownloadTarget target,
    required int partPosition,
    required bool restartIfSlow,
  }) async {
    final finalFile = target.file;
    if (await finalFile.exists()) {
      final length = await finalFile.length();
      if (length == target.sizeBytes &&
          await _hasExpectedSha256(finalFile, target.sha256)) {
        session.setPartBytes(partPosition, length);
        return;
      }
      await finalFile.delete();
      session.setPartBytes(partPosition, 0);
    }

    final partial = target.partialFile;
    var existingBytes = await partial.exists() ? await partial.length() : 0;
    if (existingBytes < 0 || existingBytes > target.sizeBytes) {
      await partial.delete();
      existingBytes = 0;
      session.setPartBytes(partPosition, 0);
    }
    if (existingBytes == target.sizeBytes) {
      if (await _hasExpectedSha256(partial, target.sha256)) {
        await _promotePart(partial, finalFile);
        session.setPartBytes(partPosition, existingBytes);
        return;
      }
      await partial.delete();
      existingBytes = 0;
      session.setPartBytes(partPosition, 0);
    }

    final requestedEnd = target.sizeBytes - 1;
    final requestedRange = 'bytes=$existingBytes-$requestedEnd';
    final response = await _sendPartRequest(
      client,
      target.url,
      range: requestedRange,
      cancellation: session.cancellation.whenCancelled,
    );
    if (!_usesIdentityEncoding(response)) {
      await _cancelResponse(response);
      throw const FormatException(
        'Game part response uses unsupported content encoding',
      );
    }
    if (response.statusCode != 206) {
      await _cancelResponse(response);
      if (response.statusCode == 408 ||
          response.statusCode == 429 ||
          response.statusCode >= 500) {
        throw _RetryablePartStatus(response.statusCode);
      }
      throw FormatException(
        'Game part range request returned ${response.statusCode}',
      );
    }

    final returned = _parseContentRange(response.headers['content-range']);
    final expectedBodyBytes = target.sizeBytes - existingBytes;
    if (returned == null ||
        returned.start != existingBytes ||
        returned.end != requestedEnd ||
        returned.total != target.sizeBytes ||
        response.contentLength != expectedBodyBytes) {
      await _cancelResponse(response);
      throw const FormatException('Game part range response is invalid');
    }

    await partial.parent.create(recursive: true);
    final output = await partial.open(
      mode: existingBytes > 0 ? FileMode.append : FileMode.write,
    );
    var bodyBytes = 0;
    var speedWindowBytes = 0;
    final speedWindow = Stopwatch()..start();
    try {
      await for (final chunk in response.stream.timeout(responseIdleTimeout)) {
        if (session.cancellation.isCancelled) {
          throw http.RequestAbortedException(target.url);
        }
        if (bodyBytes + chunk.length > expectedBodyBytes) {
          throw const FormatException(
            'Game part response is longer than declared',
          );
        }
        await output.writeFrom(chunk);
        bodyBytes += chunk.length;
        speedWindowBytes += chunk.length;
        session.addPartBytes(partPosition, chunk.length);

        if (restartIfSlow && speedWindow.elapsed >= slowPartWindow) {
          final remainingBytes = expectedBodyBytes - bodyBytes;
          final bytesPerSecond =
              speedWindowBytes *
              Duration.microsecondsPerSecond /
              speedWindow.elapsedMicroseconds;
          if (remainingBytes >= minimumSlowPartRemainingBytes &&
              bytesPerSecond < minimumHealthyPartBytesPerSecond) {
            throw const _SlowPartResponse();
          }
          speedWindow
            ..reset()
            ..start();
          speedWindowBytes = 0;
        }
      }
      await output.flush();
    } finally {
      await output.close();
    }

    if (bodyBytes != expectedBodyBytes ||
        !await partial.exists() ||
        await partial.length() != target.sizeBytes) {
      throw const _IncompletePartResponse();
    }
    if (!await _hasExpectedSha256(partial, target.sha256)) {
      await partial.delete();
      session.setPartBytes(partPosition, 0);
      throw const _PartChecksumMismatch();
    }
    await _promotePart(partial, finalFile);
    session.setPartBytes(partPosition, target.sizeBytes);
  }

  Future<http.StreamedResponse> _sendPartRequest(
    http.Client client,
    Uri uri, {
    required String range,
    required Future<void> cancellation,
  }) async {
    final attemptAbort = Completer<void>();
    final abortTrigger = Future.any<void>([attemptAbort.future, cancellation]);
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                'Chrome/125.0 Mobile Safari/537.36',
            'Accept-Encoding': 'identity',
            'Range': range,
          });
    final operation = client.send(request);
    try {
      return await Future.any<http.StreamedResponse>([
        operation,
        cancellation.then<http.StreamedResponse>(
          (_) => throw http.RequestAbortedException(uri),
        ),
      ]).timeout(requestHeaderTimeout);
    } on TimeoutException catch (error, stackTrace) {
      await _abortAndSettle(operation, attemptAbort);
      Error.throwWithStackTrace(error, stackTrace);
    } on http.RequestAbortedException catch (error, stackTrace) {
      await _abortAndSettle(operation, attemptAbort);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _abortAndSettle(
    Future<http.StreamedResponse> operation,
    Completer<void> attemptAbort,
  ) async {
    if (!attemptAbort.isCompleted) attemptAbort.complete();
    try {
      final lateResponse = await operation.timeout(requestAbortSettleTimeout);
      await _cancelResponse(lateResponse);
    } on TimeoutException {
      unawaited(
        operation.then<void>(
          _cancelResponse,
          onError: (Object _, StackTrace _) {},
        ),
      );
    } catch (_) {
      // The aborted request has settled with an error.
    }
  }

  Future<void> _retryDelay(
    int attempt,
    _ModaoDownloadCancellation cancellation,
  ) async {
    final delay = Duration(milliseconds: 250 * (attempt + 1));
    await Future.any<void>([
      Future<void>.delayed(delay),
      cancellation.whenCancelled,
    ]);
  }

  Future<void> _promotePart(File partial, File finalFile) async {
    if (await finalFile.exists()) await finalFile.delete();
    await partial.rename(finalFile.path);
  }

  Future<bool> _hasExpectedSha256(File file, String expected) async {
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == expected;
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
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
  }

  void _validatePlan(ModaoParallelDownloadPlan plan) {
    if (plan.artifactKey.trim().isEmpty ||
        plan.releaseKey.trim().isEmpty ||
        plan.totalBytes <= 0 ||
        plan.parts.length < 2 ||
        plan.parts.length > 16) {
      throw const FormatException('Invalid game download plan');
    }
    var total = 0;
    final paths = <String>{};
    for (var position = 0; position < plan.parts.length; position++) {
      final part = plan.parts[position];
      if (part.index != position ||
          part.url.scheme != 'https' ||
          part.url.host.isEmpty ||
          part.path.trim().isEmpty ||
          part.sizeBytes <= 0 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(part.sha256) ||
          !paths.add(part.path)) {
        throw const FormatException('Invalid game download part');
      }
      total += part.sizeBytes;
    }
    if (total != plan.totalBytes) {
      throw const FormatException('Game download part sizes do not match');
    }
  }

  String _failureMessage(Object error) {
    if (error is http.RequestAbortedException) return '游戏分包下载已取消';
    if (error is TimeoutException || error is SocketException) {
      return '游戏分包连接超时，请重试';
    }
    if (error is _PartChecksumMismatch) return '游戏分包校验失败，请重试';
    if (error is _IncompletePartResponse) return '游戏分包传输不完整，请重试';
    if (error is _SlowPartResponse) return '游戏分包连接速度过慢，请重试';
    return '游戏分包下载失败，请重试';
  }
}

class _ModaoDownloadSession {
  _ModaoDownloadSession(this.plan)
    : _partBytes = List<int>.filled(plan.parts.length, 0),
      snapshot = ModaoParallelDownloadSnapshot(
        artifactKey: plan.artifactKey,
        releaseKey: plan.releaseKey,
        status: ModaoParallelDownloadStatus.downloading,
        downloadedBytes: 0,
        totalBytes: plan.totalBytes,
        partCount: plan.parts.length,
      );

  final ModaoParallelDownloadPlan plan;
  final List<int> _partBytes;
  final _ModaoDownloadCancellation cancellation = _ModaoDownloadCancellation();
  late Future<void> future;
  ModaoParallelDownloadSnapshot snapshot;
  _ModaoPartFailure? firstFailure;

  void setInitialLengths(List<int> lengths) {
    for (var index = 0; index < _partBytes.length; index++) {
      _partBytes[index] = lengths[index].clamp(0, plan.parts[index].sizeBytes);
    }
    _report();
  }

  void addPartBytes(int index, int bytes) {
    setPartBytes(index, _partBytes[index] + bytes);
  }

  void setPartBytes(int index, int bytes) {
    _partBytes[index] = bytes.clamp(0, plan.parts[index].sizeBytes);
    _report();
  }

  void fail(_ModaoPartFailure failure) {
    firstFailure ??= failure;
    cancellation.cancel();
  }

  void cancel({required bool explicit}) {
    cancellation.cancel(explicit: explicit);
  }

  void pause(String reason) {
    cancellation.pause(reason);
  }

  void markCompleted() {
    snapshot = ModaoParallelDownloadSnapshot(
      artifactKey: plan.artifactKey,
      releaseKey: plan.releaseKey,
      status: ModaoParallelDownloadStatus.completed,
      downloadedBytes: plan.totalBytes,
      totalBytes: plan.totalBytes,
      partCount: plan.parts.length,
    );
  }

  void markFailed(String reason) {
    snapshot = ModaoParallelDownloadSnapshot(
      artifactKey: plan.artifactKey,
      releaseKey: plan.releaseKey,
      status: ModaoParallelDownloadStatus.failed,
      downloadedBytes: _totalReceived,
      totalBytes: plan.totalBytes,
      partCount: plan.parts.length,
      reason: reason,
    );
  }

  void markPaused() {
    snapshot = ModaoParallelDownloadSnapshot(
      artifactKey: plan.artifactKey,
      releaseKey: plan.releaseKey,
      status: ModaoParallelDownloadStatus.paused,
      downloadedBytes: _totalReceived,
      totalBytes: plan.totalBytes,
      partCount: plan.parts.length,
      reason: cancellation.pauseReason,
    );
  }

  void markCancelled() {
    snapshot = ModaoParallelDownloadSnapshot(
      artifactKey: plan.artifactKey,
      releaseKey: plan.releaseKey,
      status: ModaoParallelDownloadStatus.cancelled,
      downloadedBytes: _totalReceived,
      totalBytes: plan.totalBytes,
      partCount: plan.parts.length,
    );
  }

  void _report() {
    snapshot = ModaoParallelDownloadSnapshot(
      artifactKey: plan.artifactKey,
      releaseKey: plan.releaseKey,
      status: ModaoParallelDownloadStatus.downloading,
      downloadedBytes: _totalReceived,
      totalBytes: plan.totalBytes,
      partCount: plan.parts.length,
    );
  }

  int get _totalReceived =>
      _partBytes.fold<int>(0, (sum, bytes) => sum + bytes);
}

class _ModaoDownloadCancellation {
  final Completer<void> _completer = Completer<void>();
  bool explicit = false;
  bool paused = false;
  String pauseReason = '';

  bool get isCancelled => _completer.isCompleted;
  bool get intentional => explicit || paused;
  Future<void> get whenCancelled => _completer.future;

  void cancel({bool explicit = false}) {
    this.explicit = this.explicit || explicit;
    if (!_completer.isCompleted) _completer.complete();
  }

  void pause(String reason) {
    if (explicit) return;
    paused = true;
    pauseReason = reason;
    if (!_completer.isCompleted) _completer.complete();
  }
}

class _ModaoPartFailure {
  const _ModaoPartFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
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

class _IncompletePartResponse implements Exception {
  const _IncompletePartResponse();
}

class _SlowPartResponse implements Exception {
  const _SlowPartResponse();
}

class _PartChecksumMismatch implements Exception {
  const _PartChecksumMismatch();
}

class _RetryablePartStatus implements Exception {
  const _RetryablePartStatus(this.statusCode);

  final int statusCode;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
