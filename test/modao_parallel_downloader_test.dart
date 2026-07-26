import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:novel_app/services/modao_parallel_downloader.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('modao-parts-test-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'opens five real range requests concurrently and publishes atomically',
    () async {
      final payloads = List.generate(
        5,
        (index) => Uint8List.fromList(
          List.generate(64, (offset) => index * 64 + offset),
        ),
      );
      final plan = _plan(directory, payloads, suffix: 'concurrent');
      final allStarted = Completer<void>();
      final release = Completer<void>();
      final ranges = <String>[];
      var started = 0;
      final client = _CallbackClient((request) async {
        ranges.add(request.headers['Range']!);
        started++;
        if (started == payloads.length) allStarted.complete();
        await release.future;
        return _rangeResponse(request, payloads[_partIndex(request)]);
      });
      final downloader = ModaoParallelDownloader(httpClient: client);

      final initial = await downloader.start(plan);
      await allStarted.future.timeout(const Duration(seconds: 1));

      expect(initial.status, ModaoParallelDownloadStatus.downloading);
      expect(started, 5);
      expect(ranges.toSet(), {'bytes=0-63'});
      release.complete();
      final completed = await downloader.waitForCompletion(
        plan.artifactKey,
        releaseKey: plan.releaseKey,
      );

      expect(completed.status, ModaoParallelDownloadStatus.completed);
      for (var index = 0; index < payloads.length; index++) {
        expect(await plan.parts[index].file.readAsBytes(), payloads[index]);
        expect(await plan.parts[index].partialFile.exists(), isFalse);
      }
    },
  );

  test('resumes an interrupted part at its exact persisted offset', () async {
    final payloads = [
      Uint8List.fromList(List.generate(20, (index) => index)),
      Uint8List.fromList(List.generate(20, (index) => index + 20)),
    ];
    final plan = _plan(directory, payloads, suffix: 'resume');
    await plan.parts[0].partialFile.writeAsBytes(payloads[0].sublist(0, 7));
    await plan.parts[1].file.writeAsBytes(payloads[1]);
    final ranges = <String>[];
    final downloader = ModaoParallelDownloader(
      httpClient: _CallbackClient((request) async {
        ranges.add(request.headers['Range']!);
        return _rangeResponse(request, payloads[_partIndex(request)]);
      }),
    );

    await downloader.start(plan);
    final completed = await downloader.waitForCompletion(
      plan.artifactKey,
      releaseKey: plan.releaseKey,
    );

    expect(completed.status, ModaoParallelDownloadStatus.completed);
    expect(ranges, ['bytes=7-19']);
    expect(await plan.parts[0].file.readAsBytes(), payloads[0]);
  });

  test('same artifact generation is a single flight', () async {
    final payloads = [
      Uint8List.fromList(List.generate(16, (index) => index + 1)),
      Uint8List.fromList(List.generate(16, (index) => index + 30)),
    ];
    final plan = _plan(directory, payloads, suffix: 'single-flight');
    final bothStarted = Completer<void>();
    final release = Completer<void>();
    var requests = 0;
    final downloader = ModaoParallelDownloader(
      httpClient: _CallbackClient((request) async {
        requests++;
        if (requests == 2) bothStarted.complete();
        await release.future;
        return _rangeResponse(request, payloads[_partIndex(request)]);
      }),
    );

    await downloader.start(plan);
    await downloader.start(plan);
    await bothStarted.future;
    expect(requests, 2);
    release.complete();
    final completed = await downloader.waitForCompletion(
      plan.artifactKey,
      releaseKey: plan.releaseKey,
    );

    expect(completed.status, ModaoParallelDownloadStatus.completed);
    expect(requests, 2);
  });

  test('503 and 429 retry from the same offset and then succeed', () async {
    for (final statusCode in [503, 429]) {
      final payloads = [
        Uint8List.fromList(List.generate(16, (index) => index + 1)),
        Uint8List.fromList(List.generate(16, (index) => index + 30)),
      ];
      final plan = _plan(
        directory,
        payloads,
        suffix: 'retry-status-$statusCode',
      );
      await plan.parts[1].file.writeAsBytes(payloads[1]);
      final ranges = <String>[];
      var attempts = 0;
      final downloader = ModaoParallelDownloader(
        httpClient: _CallbackClient((request) async {
          ranges.add(request.headers['Range']!);
          attempts++;
          return _rangeResponse(
            request,
            payloads[0],
            statusCode: attempts == 1 ? statusCode : 206,
          );
        }),
        requestAttempts: 2,
      );

      await downloader.start(plan);
      final completed = await downloader.waitForCompletion(
        plan.artifactKey,
        releaseKey: plan.releaseKey,
      );

      expect(completed.status, ModaoParallelDownloadStatus.completed);
      expect(ranges, ['bytes=0-15', 'bytes=0-15']);
    }
  });

  test('different releases do not share a flight or cancellation', () async {
    final payloads = [
      Uint8List.fromList(List.generate(16, (index) => index + 1)),
      Uint8List.fromList(List.generate(16, (index) => index + 30)),
    ];
    final oldPlan = _plan(
      directory,
      payloads,
      suffix: 'old-generation',
      artifactKey: 'shared-artifact',
      releaseKey: 'old-release',
    );
    final newPlan = _plan(
      directory,
      payloads,
      suffix: 'new-generation',
      artifactKey: 'shared-artifact',
      releaseKey: 'new-release',
    );
    final oldStarted = Completer<void>();
    final newStarted = Completer<void>();
    final releaseNew = Completer<void>();
    var oldRequests = 0;
    var newRequests = 0;
    final downloader = ModaoParallelDownloader(
      httpClient: _CallbackClient((request) async {
        if (request.url.path.contains('old-generation')) {
          oldRequests++;
          if (oldRequests == 2) oldStarted.complete();
          return _waitForAbort(request);
        }
        newRequests++;
        if (newRequests == 2) newStarted.complete();
        await releaseNew.future;
        return _rangeResponse(request, payloads[_partIndex(request)]);
      }),
    );

    await downloader.start(oldPlan);
    await oldStarted.future;
    await downloader.start(newPlan);
    await newStarted.future;
    await downloader.cancel(
      oldPlan.artifactKey,
      releaseKey: oldPlan.releaseKey,
    );

    expect(
      downloader
          .snapshot(newPlan.artifactKey, releaseKey: newPlan.releaseKey)
          ?.status,
      ModaoParallelDownloadStatus.downloading,
    );
    releaseNew.complete();
    final completed = await downloader.waitForCompletion(
      newPlan.artifactKey,
      releaseKey: newPlan.releaseKey,
    );

    expect(completed.status, ModaoParallelDownloadStatus.completed);
    expect(oldRequests, 2);
    expect(newRequests, 2);
  });

  test('multi-gigabyte plan totals remain 64-bit safe', () async {
    const partSize = 1500000000;
    final plan = ModaoParallelDownloadPlan(
      artifactKey: 'artifact-large',
      releaseKey: 'release-large',
      totalBytes: partSize * 2,
      parts: [
        for (var index = 0; index < 2; index++)
          ModaoPartDownloadTarget(
            index: index,
            url: Uri.parse('https://novel.kxhub.xyz/large/part-$index'),
            path: '${directory.path}${Platform.pathSeparator}large-$index.apk',
            sizeBytes: partSize,
            sha256: '${index + 1}' * 64,
          ),
      ],
    );
    final bothStarted = Completer<void>();
    var requests = 0;
    final downloader = ModaoParallelDownloader(
      httpClient: _CallbackClient((request) {
        requests++;
        if (requests == 2) bothStarted.complete();
        return _waitForAbort(request);
      }),
    );

    final initial = await downloader.start(plan);
    await bothStarted.future;

    expect(initial.totalBytes, 3000000000);
    expect(initial.downloadedBytes, 0);
    await downloader.cancel(plan.artifactKey, releaseKey: plan.releaseKey);
  });

  test('retries a short response from the newly persisted offset', () async {
    final payloads = [
      Uint8List.fromList(List.generate(20, (index) => index + 40)),
      Uint8List.fromList(List.generate(20, (index) => index + 80)),
    ];
    final plan = _plan(directory, payloads, suffix: 'short');
    await plan.parts[1].file.writeAsBytes(payloads[1]);
    final ranges = <String>[];
    var attempts = 0;
    final downloader = ModaoParallelDownloader(
      httpClient: _CallbackClient((request) async {
        ranges.add(request.headers['Range']!);
        attempts++;
        if (attempts == 1) {
          return _rangeResponse(request, payloads[0], truncateBodyTo: 8);
        }
        return _rangeResponse(request, payloads[0]);
      }),
      requestAttempts: 2,
    );

    await downloader.start(plan);
    final completed = await downloader.waitForCompletion(
      plan.artifactKey,
      releaseKey: plan.releaseKey,
    );

    expect(completed.status, ModaoParallelDownloadStatus.completed);
    expect(ranges, ['bytes=0-19', 'bytes=8-19']);
    expect(await plan.parts[0].file.readAsBytes(), payloads[0]);
  });

  test(
    'deletes a full-sized part with a wrong SHA before redownloading',
    () async {
      final payloads = [
        Uint8List.fromList(List.generate(20, (index) => index + 1)),
        Uint8List.fromList(List.generate(20, (index) => index + 30)),
      ];
      final plan = _plan(directory, payloads, suffix: 'wrong-sha');
      await plan.parts[0].partialFile.writeAsBytes(Uint8List(20));
      await plan.parts[1].file.writeAsBytes(payloads[1]);
      final ranges = <String>[];
      final downloader = ModaoParallelDownloader(
        httpClient: _CallbackClient((request) async {
          ranges.add(request.headers['Range']!);
          return _rangeResponse(request, payloads[0]);
        }),
      );

      await downloader.start(plan);
      final completed = await downloader.waitForCompletion(
        plan.artifactKey,
        releaseKey: plan.releaseKey,
      );

      expect(completed.status, ModaoParallelDownloadStatus.completed);
      expect(ranges, ['bytes=0-19']);
      expect(await plan.parts[0].file.readAsBytes(), payloads[0]);
    },
  );

  test(
    'rejects non-206, invalid Content-Range, and encoded responses',
    () async {
      for (final invalid in ['status', 'range', 'length', 'encoding']) {
        final payloads = [
          Uint8List.fromList(List.generate(12, (index) => index + 1)),
          Uint8List.fromList(List.generate(12, (index) => index + 20)),
        ];
        final plan = _plan(directory, payloads, suffix: 'invalid-$invalid');
        await plan.parts[1].file.writeAsBytes(payloads[1]);
        final downloader = ModaoParallelDownloader(
          httpClient: _CallbackClient((request) async {
            return _rangeResponse(
              request,
              payloads[0],
              statusCode: invalid == 'status' ? 200 : 206,
              contentRange: invalid == 'range' ? 'bytes 1-11/12' : null,
              declaredLength: invalid == 'length' ? 11 : null,
              contentEncoding: invalid == 'encoding' ? 'gzip' : 'identity',
            );
          }),
        );

        await downloader.start(plan);
        final completed = await downloader.waitForCompletion(
          plan.artifactKey,
          releaseKey: plan.releaseKey,
        );

        expect(
          completed.status,
          ModaoParallelDownloadStatus.failed,
          reason: invalid,
        );
        expect(await plan.parts[0].file.exists(), isFalse);
      }
    },
  );

  test(
    'a slow part restarts alone while a healthy part is not cancelled',
    () async {
      final payloads = [
        Uint8List.fromList(List.generate(16, (index) => index + 1)),
        Uint8List.fromList(List.generate(16, (index) => index + 40)),
      ];
      final plan = _plan(directory, payloads, suffix: 'slow');
      final attempts = <int, int>{};
      final client = _CallbackClient((request) async {
        final index = _partIndex(request);
        attempts[index] = (attempts[index] ?? 0) + 1;
        final response = _rangeResponse(request, payloads[index]);
        if (index != 0 || attempts[index]! > 1) return response;
        final bytes = await response.stream.toBytes();
        return http.StreamedResponse(
          (() async* {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            yield bytes.sublist(0, 1);
            yield bytes.sublist(1);
          })(),
          response.statusCode,
          contentLength: response.contentLength,
          headers: response.headers,
          request: request,
        );
      });
      final downloader = ModaoParallelDownloader(
        httpClient: client,
        requestAttempts: 2,
        slowPartWindow: const Duration(milliseconds: 10),
        minimumHealthyPartBytesPerSecond: 1024 * 1024,
        minimumSlowPartRemainingBytes: 1,
      );

      await downloader.start(plan);
      final completed = await downloader.waitForCompletion(
        plan.artifactKey,
        releaseKey: plan.releaseKey,
      );

      expect(completed.status, ModaoParallelDownloadStatus.completed);
      expect(attempts[0], 2);
      expect(attempts[1], 1);
    },
  );

  test(
    'cancel waits for response subscriptions and file writers to settle',
    () async {
      final payloads = [
        Uint8List.fromList(List.generate(64, (index) => index)),
        Uint8List.fromList(List.generate(64, (index) => index + 64)),
      ];
      final plan = _plan(directory, payloads, suffix: 'cancel');
      final bothStarted = Completer<void>();
      final settled = <Completer<void>>[Completer<void>(), Completer<void>()];
      var started = 0;
      final client = _CallbackClient((request) async {
        final index = _partIndex(request);
        final controller = StreamController<List<int>>();
        var listened = false;
        var aborted = false;
        controller.onListen = () {
          listened = true;
          if (aborted) {
            controller.addError(http.RequestAbortedException(request.url));
            unawaited(controller.close());
          } else {
            controller.add(payloads[index].sublist(0, 1));
          }
        };
        controller.onCancel = () async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          if (!settled[index].isCompleted) settled[index].complete();
        };
        if (request is http.Abortable) {
          unawaited(
            request.abortTrigger!.then((_) async {
              aborted = true;
              if (!listened) return;
              if (!controller.isClosed) {
                try {
                  controller.addError(
                    http.RequestAbortedException(request.url),
                  );
                } on StateError {
                  // The response subscription settled first.
                }
              }
              if (!controller.isClosed) {
                await controller.close();
              }
            }),
          );
        }
        started++;
        if (started == 2) bothStarted.complete();
        return http.StreamedResponse(
          controller.stream,
          206,
          contentLength: payloads[index].length,
          headers: {
            'content-range':
                'bytes 0-${payloads[index].length - 1}/${payloads[index].length}',
            'content-length': payloads[index].length.toString(),
            'content-encoding': 'identity',
          },
          request: request,
        );
      });
      final downloader = ModaoParallelDownloader(httpClient: client);
      await downloader.start(plan);
      await bothStarted.future;

      var cancelReturned = false;
      final cancellation = downloader
          .cancel(plan.artifactKey, releaseKey: plan.releaseKey)
          .then((_) => cancelReturned = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cancelReturned, isFalse);
      await cancellation;

      expect(settled.every((item) => item.isCompleted), isTrue);
    },
  );

  test(
    'policy pause preserves partials and resumes from exact offsets',
    () async {
      final payloads = [
        Uint8List.fromList(List.generate(64, (index) => index)),
        Uint8List.fromList(List.generate(64, (index) => index + 64)),
      ];
      final plan = _plan(directory, payloads, suffix: 'policy-pause');
      final firstRequestsStarted = Completer<void>();
      final ranges = <String>[];
      var firstRequests = 0;
      final client = _CallbackClient((request) async {
        ranges.add(request.headers['Range']!);
        if (request.headers['Range'] == 'bytes=0-63') {
          firstRequests++;
          final index = _partIndex(request);
          if (firstRequests == payloads.length &&
              !firstRequestsStarted.isCompleted) {
            firstRequestsStarted.complete();
          }
          return http.StreamedResponse(
            (() async* {
              yield payloads[index].sublist(0, 8);
              await (request as http.Abortable).abortTrigger;
            })(),
            206,
            contentLength: payloads[index].length,
            headers: {
              'content-range':
                  'bytes 0-${payloads[index].length - 1}/${payloads[index].length}',
              'content-length': payloads[index].length.toString(),
              'content-encoding': 'identity',
            },
            request: request,
          );
        }
        return _rangeResponse(request, payloads[_partIndex(request)]);
      });
      final downloader = ModaoParallelDownloader(httpClient: client);

      await downloader.start(plan);
      await firstRequestsStarted.future;
      await _waitForPartLengths(plan, const [8, 8]);
      await downloader.pause(
        plan.artifactKey,
        releaseKey: plan.releaseKey,
        reason: '等待 Wi-Fi 网络',
      );

      final paused = downloader.snapshot(
        plan.artifactKey,
        releaseKey: plan.releaseKey,
      );
      expect(paused?.status, ModaoParallelDownloadStatus.paused);
      expect(paused?.downloadedBytes, 16);
      expect(paused?.reason, '等待 Wi-Fi 网络');
      expect(
        await Future.wait(plan.parts.map((part) => part.partialFile.length())),
        [8, 8],
      );

      await downloader.start(plan);
      final completed = await downloader.waitForCompletion(
        plan.artifactKey,
        releaseKey: plan.releaseKey,
      );

      expect(completed.status, ModaoParallelDownloadStatus.completed);
      expect(ranges, ['bytes=0-63', 'bytes=0-63', 'bytes=8-63', 'bytes=8-63']);
      for (var index = 0; index < plan.parts.length; index++) {
        expect(await plan.parts[index].file.readAsBytes(), payloads[index]);
      }
    },
  );

  test(
    'cancelAllExcept forgets completed and failed stale generations',
    () async {
      final payloads = [
        Uint8List.fromList(List.generate(12, (index) => index + 1)),
        Uint8List.fromList(List.generate(12, (index) => index + 30)),
      ];
      final completedStale = _plan(
        directory,
        payloads,
        suffix: 'settled-completed',
      );
      final failedStale = _plan(directory, payloads, suffix: 'settled-failed');
      final keep = _plan(directory, payloads, suffix: 'settled-keep');
      final downloader = ModaoParallelDownloader(
        httpClient: _CallbackClient((request) async {
          return _rangeResponse(
            request,
            payloads[_partIndex(request)],
            statusCode: request.url.path.contains('settled-failed') ? 200 : 206,
          );
        }),
      );

      await downloader.start(completedStale);
      await downloader.waitForCompletion(
        completedStale.artifactKey,
        releaseKey: completedStale.releaseKey,
      );
      await downloader.start(failedStale);
      final failed = await downloader.waitForCompletion(
        failedStale.artifactKey,
        releaseKey: failedStale.releaseKey,
      );
      expect(failed.status, ModaoParallelDownloadStatus.failed);
      await downloader.cancelAllExcept(
        artifactKey: keep.artifactKey,
        releaseKey: keep.releaseKey,
      );

      expect(
        () => downloader.waitForCompletion(
          completedStale.artifactKey,
          releaseKey: completedStale.releaseKey,
        ),
        throwsStateError,
      );
      expect(
        () => downloader.waitForCompletion(
          failedStale.artifactKey,
          releaseKey: failedStale.releaseKey,
        ),
        throwsStateError,
      );
    },
  );

  test('session namespaces isolate different game downloads', () async {
    final payloads = [
      Uint8List.fromList(List.generate(16, (index) => index + 1)),
      Uint8List.fromList(List.generate(16, (index) => index + 30)),
    ];
    final kdjxPlan = _plan(
      directory,
      payloads,
      suffix: 'namespace-kdjx',
      artifactKey: 'shared-artifact',
      releaseKey: 'shared-release',
    );
    final modaoPlan = _plan(
      directory,
      payloads,
      suffix: 'namespace-modao',
      artifactKey: 'shared-artifact',
      releaseKey: 'shared-release',
    );
    final kdjxStarted = Completer<void>();
    final releaseKdjx = Completer<void>();
    var kdjxRequests = 0;
    final kdjxDownloader = ModaoParallelDownloader(
      sessionNamespace: 'kdjx',
      httpClient: _CallbackClient((request) async {
        kdjxRequests++;
        if (kdjxRequests == payloads.length) kdjxStarted.complete();
        await releaseKdjx.future;
        return _rangeResponse(request, payloads[_partIndex(request)]);
      }),
    );
    final modaoDownloader = ModaoParallelDownloader(
      sessionNamespace: 'modao',
      httpClient: _CallbackClient((request) async {
        return _rangeResponse(request, payloads[_partIndex(request)]);
      }),
    );

    await kdjxDownloader.start(kdjxPlan);
    await kdjxStarted.future;
    await modaoDownloader.start(modaoPlan);
    await modaoDownloader.cancelAllExcept(
      artifactKey: modaoPlan.artifactKey,
      releaseKey: modaoPlan.releaseKey,
    );
    final modaoCompleted = await modaoDownloader.waitForCompletion(
      modaoPlan.artifactKey,
      releaseKey: modaoPlan.releaseKey,
    );

    expect(modaoCompleted.status, ModaoParallelDownloadStatus.completed);
    expect(
      kdjxDownloader
          .snapshot(kdjxPlan.artifactKey, releaseKey: kdjxPlan.releaseKey)
          ?.status,
      ModaoParallelDownloadStatus.downloading,
    );
    releaseKdjx.complete();
    final kdjxCompleted = await kdjxDownloader.waitForCompletion(
      kdjxPlan.artifactKey,
      releaseKey: kdjxPlan.releaseKey,
    );
    expect(kdjxCompleted.status, ModaoParallelDownloadStatus.completed);
  });
}

ModaoParallelDownloadPlan _plan(
  Directory directory,
  List<Uint8List> payloads, {
  required String suffix,
  String? artifactKey,
  String? releaseKey,
}) {
  return ModaoParallelDownloadPlan(
    artifactKey: artifactKey ?? 'artifact-$suffix',
    releaseKey: releaseKey ?? 'release-$suffix',
    totalBytes: payloads.fold<int>(0, (sum, bytes) => sum + bytes.length),
    parts: [
      for (var index = 0; index < payloads.length; index++)
        ModaoPartDownloadTarget(
          index: index,
          url: Uri.parse('https://novel.kxhub.xyz/$suffix/part-$index'),
          path:
              '${directory.path}${Platform.pathSeparator}$suffix-part-$index.apk',
          sizeBytes: payloads[index].length,
          sha256: crypto.sha256.convert(payloads[index]).toString(),
        ),
    ],
  );
}

Future<http.StreamedResponse> _waitForAbort(http.BaseRequest request) {
  final completer = Completer<http.StreamedResponse>();
  final abortable = request as http.Abortable;
  unawaited(
    abortable.abortTrigger!.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(http.RequestAbortedException(request.url));
      }
    }),
  );
  return completer.future;
}

int _partIndex(http.BaseRequest request) =>
    int.parse(request.url.pathSegments.last.split('-').last);

http.StreamedResponse _rangeResponse(
  http.BaseRequest request,
  Uint8List payload, {
  int statusCode = 206,
  int? truncateBodyTo,
  String? contentRange,
  int? declaredLength,
  String contentEncoding = 'identity',
}) {
  final match = RegExp(
    r'^bytes=(\d+)-(\d+)$',
  ).firstMatch(request.headers['Range'] ?? '');
  final start = int.parse(match!.group(1)!);
  final end = int.parse(match.group(2)!);
  final body = payload.sublist(
    start,
    truncateBodyTo == null ? end + 1 : start + truncateBodyTo,
  );
  final expectedLength = end - start + 1;
  return http.StreamedResponse(
    Stream.value(body),
    statusCode,
    contentLength: declaredLength ?? expectedLength,
    headers: {
      'content-range': contentRange ?? 'bytes $start-$end/${payload.length}',
      'content-length': (declaredLength ?? expectedLength).toString(),
      'content-encoding': contentEncoding,
    },
    request: request,
  );
}

class _CallbackClient extends http.BaseClient {
  _CallbackClient(this.callback);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  callback;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      callback(request);
}

Future<void> _waitForPartLengths(
  ModaoParallelDownloadPlan plan,
  List<int> expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (true) {
    final lengths = await Future.wait(
      plan.parts.map(
        (part) async =>
            await part.partialFile.exists() ? part.partialFile.length() : 0,
      ),
    );
    if (lengths.toString() == expected.toString()) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for partial writes: $lengths');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
