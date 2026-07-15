import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/services/download_stream_utils.dart';

void main() {
  test('accepts only a complete 206 range starting at existing bytes', () {
    final range = validateDownloadResponseRange(
      statusCode: 206,
      existingBytes: 100,
      contentRange: 'bytes 100-199/200',
      contentLength: 100,
    );

    expect(range.append, isTrue);
    expect(range.expectedBodyBytes, 100);
    expect(range.totalBytes, 200);
  });

  test(
    'rejects resumed responses with a wrong start or inconsistent length',
    () {
      expect(
        () => validateDownloadResponseRange(
          statusCode: 206,
          existingBytes: 100,
          contentRange: 'bytes 0-199/200',
          contentLength: 200,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validateDownloadResponseRange(
          statusCode: 206,
          existingBytes: 100,
          contentRange: 'bytes 100-199/200',
          contentLength: 99,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validateDownloadResponseRange(
          statusCode: 206,
          existingBytes: 100,
          contentRange: 'bytes 100-199/250',
          contentLength: 100,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'idle timeout resets after every download chunk and cancels upstream',
    () async {
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final received = <List<int>>[];
      final timedOut = Completer<void>();

      withDownloadIdleTimeout(
        controller.stream,
        timeout: const Duration(milliseconds: 80),
      ).listen(
        received.add,
        onError: (Object error, StackTrace stack) {
          expect(error, isA<TimeoutException>());
          if (!timedOut.isCompleted) timedOut.complete();
        },
        cancelOnError: true,
      );

      controller.add([1]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      controller.add([2]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(timedOut.isCompleted, isFalse);

      await timedOut.future.timeout(const Duration(milliseconds: 100));
      await Future<void>.delayed(Duration.zero);
      expect(received, [
        [1],
        [2],
      ]);
      expect(cancelled, isTrue);
      await controller.close();
    },
  );

  test('validates explicit HLS byte-range responses', () {
    expect(
      () => validateExplicitByteRangeResponse(
        requestedRange: 'bytes=100-199',
        contentRange: 'bytes 100-199/1000',
        contentLength: 100,
      ),
      returnsNormally,
    );
    expect(
      () => validateExplicitByteRangeResponse(
        requestedRange: 'bytes=100-199',
        contentRange: 'bytes 0-99/1000',
        contentLength: 100,
      ),
      throwsFormatException,
    );
    expect(
      () => validateExplicitByteRangeResponse(
        requestedRange: 'bytes=100-199',
        contentRange: 'bytes 100-199/1000',
        contentLength: 99,
      ),
      throwsFormatException,
    );
  });

  test('accepts 206 only for HLS resources requested with a byte range', () {
    expect(
      () => validateHlsResourceResponseStatus(
        requestedRange: false,
        statusCode: 200,
      ),
      returnsNormally,
    );
    expect(
      () => validateHlsResourceResponseStatus(
        requestedRange: false,
        statusCode: 206,
      ),
      throwsFormatException,
    );
    expect(
      () => validateHlsResourceResponseStatus(
        requestedRange: true,
        statusCode: 206,
      ),
      returnsNormally,
    );
    expect(
      () => validateHlsResourceResponseStatus(
        requestedRange: true,
        statusCode: 200,
      ),
      throwsFormatException,
    );
  });
}
