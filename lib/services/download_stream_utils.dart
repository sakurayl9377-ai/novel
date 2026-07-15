import 'dart:async';

const Duration defaultDownloadIdleTimeout = Duration(seconds: 30);

class DownloadResponseRange {
  const DownloadResponseRange({
    required this.append,
    required this.expectedBodyBytes,
    required this.totalBytes,
  });

  final bool append;
  final int? expectedBodyBytes;
  final int? totalBytes;
}

DownloadResponseRange validateDownloadResponseRange({
  required int statusCode,
  required int existingBytes,
  required String? contentRange,
  required int? contentLength,
}) {
  if (statusCode == 200) {
    return DownloadResponseRange(
      append: false,
      expectedBodyBytes: contentLength,
      totalBytes: contentLength,
    );
  }
  if (statusCode != 206) {
    throw FormatException('Unexpected download status: $statusCode');
  }

  final match = RegExp(
    r'^bytes (\d+)-(\d+)/(\d+)$',
  ).firstMatch(contentRange?.trim() ?? '');
  final start = int.tryParse(match?.group(1) ?? '');
  final end = int.tryParse(match?.group(2) ?? '');
  final total = int.tryParse(match?.group(3) ?? '');
  if (start == null ||
      end == null ||
      total == null ||
      start != existingBytes ||
      end < start ||
      total <= end ||
      end != total - 1) {
    throw const FormatException('Invalid Content-Range for resumed download');
  }
  final bodyBytes = end - start + 1;
  if (contentLength != null && contentLength != bodyBytes) {
    throw const FormatException('Content-Length does not match Content-Range');
  }
  return DownloadResponseRange(
    append: existingBytes > 0,
    expectedBodyBytes: bodyBytes,
    totalBytes: total,
  );
}

void validateExplicitByteRangeResponse({
  required String requestedRange,
  required String? contentRange,
  required int? contentLength,
}) {
  final requested = RegExp(
    r'^bytes=(\d+)-(\d+)$',
  ).firstMatch(requestedRange.trim());
  final returned = RegExp(
    r'^bytes (\d+)-(\d+)/(?:\d+|\*)$',
  ).firstMatch(contentRange?.trim() ?? '');
  final requestedStart = int.tryParse(requested?.group(1) ?? '');
  final requestedEnd = int.tryParse(requested?.group(2) ?? '');
  final returnedStart = int.tryParse(returned?.group(1) ?? '');
  final returnedEnd = int.tryParse(returned?.group(2) ?? '');
  if (requestedStart == null ||
      requestedEnd == null ||
      returnedStart != requestedStart ||
      returnedEnd != requestedEnd ||
      requestedEnd < requestedStart) {
    throw const FormatException('Invalid explicit byte range response');
  }
  final expectedLength = requestedEnd - requestedStart + 1;
  if (contentLength != null && contentLength != expectedLength) {
    throw const FormatException(
      'Content-Length does not match explicit byte range',
    );
  }
}

void validateHlsResourceResponseStatus({
  required bool requestedRange,
  required int statusCode,
}) {
  final expectedStatus = requestedRange ? 206 : 200;
  if (statusCode != expectedStatus) {
    throw FormatException(
      'Unexpected HLS resource status: $statusCode (expected $expectedStatus)',
    );
  }
}

/// Applies a timeout between consecutive data events, rather than to the
/// entire response body. Cancelling the returned stream still cancels the
/// source subscription, which keeps pause/delete semantics intact.
Stream<T> withDownloadIdleTimeout<T>(
  Stream<T> source, {
  Duration timeout = defaultDownloadIdleTimeout,
}) {
  return source.timeout(timeout);
}
