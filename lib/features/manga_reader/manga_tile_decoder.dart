import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const int mangaTileMaxSourceDimension = 250000;
const int mangaTileMaxSourceRectDimension = 32768;
const int mangaTileMinTargetWidth = 64;
const int mangaTileMaxTargetWidth = 2048;
const int mangaTileMaxDecodedWidth = 2560;
const int mangaTileMaxDecodedHeight = 4096;
const int mangaTileMaxSampleSize = 64;
const int mangaTileMaxSourceBytes = 256 * 1024 * 1024;

final RegExp _mangaTileSourceIdPattern = RegExp(r'^[a-f0-9]{64}$');

/// Platform-neutral contract used by [MangaTiledImage] and test fakes.
abstract interface class MangaTileDecoder {
  Future<bool> isSupported();

  Future<MangaTileSourceInfo> prepareSource(MangaTileSourceRequest request);

  Future<MangaDecodedTile> decodeTile(MangaTileRequest request);

  Future<void> releaseSource(String sourceId);

  Future<MangaTileCachePruneResult> pruneCache({
    int? maxBytes,
    Duration? maxAge,
  });
}

class MangaTileSourceRequest {
  const MangaTileSourceRequest({
    required this.source,
    this.referer,
    this.cacheKey,
  });

  final String source;
  final String? referer;
  final String? cacheKey;

  Map<String, Object?> toChannelArguments() => <String, Object?>{
    'source': source,
    if (referer != null && referer!.trim().isNotEmpty)
      'referer': referer!.trim(),
    if (cacheKey != null && cacheKey!.trim().isNotEmpty)
      'cacheKey': cacheKey!.trim(),
  };
}

@immutable
class MangaTileSourceInfo {
  const MangaTileSourceInfo({
    required this.sourceId,
    required this.width,
    required this.height,
    required this.mimeType,
    required this.byteLength,
    required this.localInput,
  });

  factory MangaTileSourceInfo.fromChannel(Object? value) {
    final map = _channelMap(value, 'source metadata');
    final sourceId = _requiredString(map, 'sourceId');
    if (!_mangaTileSourceIdPattern.hasMatch(sourceId)) {
      throw const MangaTileDecoderException(
        code: 'INVALID_RESPONSE',
        message: 'Native source id is invalid',
      );
    }
    final localInput = map['localInput'];
    if (localInput is! bool) {
      throw const MangaTileDecoderException(
        code: 'INVALID_RESPONSE',
        message: 'Native local-input flag is invalid',
      );
    }
    return MangaTileSourceInfo(
      sourceId: sourceId,
      width: _boundedPositiveInt(
        map,
        'width',
        maximum: mangaTileMaxSourceDimension,
      ),
      height: _boundedPositiveInt(
        map,
        'height',
        maximum: mangaTileMaxSourceDimension,
      ),
      mimeType: _requiredString(map, 'mimeType'),
      byteLength: _boundedNonNegativeInt(
        map,
        'byteLength',
        maximum: mangaTileMaxSourceBytes,
      ),
      localInput: localInput,
    );
  }

  final String sourceId;
  final int width;
  final int height;
  final String mimeType;
  final int byteLength;
  final bool localInput;

  /// Width divided by height, matching Flutter's [AspectRatio] convention.
  double get aspectRatio => width / height;

  bool get isTall => height > width;

  int get pixelCount => width * height;
}

@immutable
class MangaSourceRect {
  const MangaSourceRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  }) : assert(x >= 0),
       assert(y >= 0),
       assert(width > 0),
       assert(height > 0);

  final int x;
  final int y;
  final int width;
  final int height;

  int get right => x + width;
  int get bottom => y + height;

  @override
  bool operator ==(Object other) =>
      other is MangaSourceRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

class MangaTileRequest {
  const MangaTileRequest({
    required this.sourceId,
    required this.sourceRect,
    required this.targetWidth,
    this.quality = 92,
  });

  final String sourceId;
  final MangaSourceRect sourceRect;
  final int targetWidth;
  final int quality;

  Map<String, Object?> toChannelArguments() => <String, Object?>{
    'sourceId': sourceId,
    'x': sourceRect.x,
    'y': sourceRect.y,
    'width': sourceRect.width,
    'height': sourceRect.height,
    'targetWidth': targetWidth,
    'quality': quality,
  };
}

@immutable
class MangaDecodedTile {
  const MangaDecodedTile({
    required this.sourceId,
    required this.tileKey,
    required this.path,
    required this.width,
    required this.height,
    required this.sampleSize,
    required this.sourceRect,
  });

  factory MangaDecodedTile.fromChannel(Object? value) {
    final map = _channelMap(value, 'decoded tile');
    final sourceId = _requiredString(map, 'sourceId');
    if (!_mangaTileSourceIdPattern.hasMatch(sourceId)) {
      throw const MangaTileDecoderException(
        code: 'INVALID_RESPONSE',
        message: 'Native tile source id is invalid',
      );
    }
    final tileKey = _requiredString(map, 'tileKey');
    if (tileKey.length > 256 ||
        !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(tileKey)) {
      throw const MangaTileDecoderException(
        code: 'INVALID_RESPONSE',
        message: 'Native tile key is invalid',
      );
    }
    final path = _requiredString(map, 'path');
    if (path.length > 8192 || !_looksLikeAbsoluteFilePath(path)) {
      throw const MangaTileDecoderException(
        code: 'INVALID_RESPONSE',
        message: 'Native tile path is invalid',
      );
    }
    final sampleSize = _boundedPositiveInt(
      map,
      'sampleSize',
      maximum: mangaTileMaxSampleSize,
    );
    if ((sampleSize & (sampleSize - 1)) != 0) {
      throw const MangaTileDecoderException(
        code: 'INVALID_RESPONSE',
        message: 'Native tile sample size is invalid',
      );
    }
    return MangaDecodedTile(
      sourceId: sourceId,
      tileKey: tileKey,
      path: path,
      width: _boundedPositiveInt(
        map,
        'width',
        maximum: mangaTileMaxDecodedWidth,
      ),
      height: _boundedPositiveInt(
        map,
        'height',
        maximum: mangaTileMaxDecodedHeight,
      ),
      sampleSize: sampleSize,
      sourceRect: MangaSourceRect(
        x: _nonNegativeInt(map, 'sourceX'),
        y: _nonNegativeInt(map, 'sourceY'),
        width: _boundedPositiveInt(
          map,
          'sourceWidth',
          maximum: mangaTileMaxSourceRectDimension,
        ),
        height: _boundedPositiveInt(
          map,
          'sourceHeight',
          maximum: mangaTileMaxSourceRectDimension,
        ),
      ),
    );
  }

  final String sourceId;
  final String tileKey;
  final String path;
  final int width;
  final int height;
  final int sampleSize;
  final MangaSourceRect sourceRect;
}

@immutable
class MangaTileCachePruneResult {
  const MangaTileCachePruneResult({
    required this.removedFiles,
    required this.removedBytes,
    required this.retainedBytes,
  });

  factory MangaTileCachePruneResult.fromChannel(Object? value) {
    final map = _channelMap(value, 'cache prune result');
    return MangaTileCachePruneResult(
      removedFiles: _nonNegativeInt(map, 'removedFiles'),
      removedBytes: _nonNegativeInt(map, 'removedBytes'),
      retainedBytes: _nonNegativeInt(map, 'retainedBytes'),
    );
  }

  final int removedFiles;
  final int removedBytes;
  final int retainedBytes;
}

class MangaTileDecoderException implements Exception {
  const MangaTileDecoderException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'MangaTileDecoderException($code): $message';
}

/// Android BitmapRegionDecoder bridge.
///
/// Only metadata and cached tile paths cross the channel. Original image bytes
/// and decoded bitmap bytes always stay off the MethodChannel.
class MangaTileDecoderService implements MangaTileDecoder {
  MangaTileDecoderService._(this._channel, this._supportedOverride);

  static const channelName = 'com.novel.novel_app/manga_tiles';

  static final MangaTileDecoderService instance = MangaTileDecoderService._(
    const MethodChannel(channelName),
    null,
  );

  @visibleForTesting
  factory MangaTileDecoderService.forTesting(
    MethodChannel channel, {
    bool supported = true,
  }) => MangaTileDecoderService._(channel, supported);

  final MethodChannel _channel;
  final bool? _supportedOverride;

  bool get _platformCanSupport =>
      _supportedOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  @override
  Future<bool> isSupported() async {
    if (!_platformCanSupport) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<MangaTileSourceInfo> prepareSource(
    MangaTileSourceRequest request,
  ) async {
    if (!_platformCanSupport) {
      throw const MangaTileDecoderException(
        code: 'UNSUPPORTED_PLATFORM',
        message: 'Tiled manga decoding is available on Android only',
      );
    }
    final source = request.source.trim();
    if (source.isEmpty || source.length > 8192) {
      throw const MangaTileDecoderException(
        code: 'INVALID_SOURCE',
        message: 'Image source is empty or too long',
      );
    }
    if ((request.cacheKey?.trim().length ?? 0) > 1024) {
      throw const MangaTileDecoderException(
        code: 'INVALID_CACHE_KEY',
        message: 'Image cache key is too long',
      );
    }
    return MangaTileSourceInfo.fromChannel(
      await _invoke('prepareSource', request.toChannelArguments()),
    );
  }

  @override
  Future<MangaDecodedTile> decodeTile(MangaTileRequest request) async {
    if (!_platformCanSupport) {
      throw const MangaTileDecoderException(
        code: 'UNSUPPORTED_PLATFORM',
        message: 'Tiled manga decoding is available on Android only',
      );
    }
    if (!_mangaTileSourceIdPattern.hasMatch(request.sourceId)) {
      throw const MangaTileDecoderException(
        code: 'INVALID_SOURCE_ID',
        message: 'Source id is invalid',
      );
    }
    final rect = request.sourceRect;
    if (rect.x < 0 ||
        rect.y < 0 ||
        rect.width <= 0 ||
        rect.height <= 0 ||
        rect.width > mangaTileMaxSourceRectDimension ||
        rect.height > mangaTileMaxSourceRectDimension ||
        request.targetWidth < mangaTileMinTargetWidth ||
        request.targetWidth > mangaTileMaxTargetWidth ||
        request.quality < 70 ||
        request.quality > 100) {
      throw const MangaTileDecoderException(
        code: 'INVALID_REQUEST',
        message: 'Tile decode parameters are invalid',
      );
    }
    final tile = MangaDecodedTile.fromChannel(
      await _invoke('decodeTile', request.toChannelArguments()),
    );
    if (tile.sourceId != request.sourceId || tile.sourceRect != rect) {
      throw const MangaTileDecoderException(
        code: 'INVALID_RESPONSE',
        message: 'Native tile response does not match the request',
      );
    }
    return tile;
  }

  @override
  Future<void> releaseSource(String sourceId) async {
    if (!_platformCanSupport || !_mangaTileSourceIdPattern.hasMatch(sourceId)) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('releaseSource', <String, Object?>{
        'sourceId': sourceId,
      });
    } on MissingPluginException {
      // The engine may be detaching while the reader route is disposed.
    } on PlatformException {
      // Release is idempotent and best-effort during teardown.
    }
  }

  @override
  Future<MangaTileCachePruneResult> pruneCache({
    int? maxBytes,
    Duration? maxAge,
  }) async {
    if (!_platformCanSupport) {
      return const MangaTileCachePruneResult(
        removedFiles: 0,
        removedBytes: 0,
        retainedBytes: 0,
      );
    }
    return MangaTileCachePruneResult.fromChannel(
      await _invoke('pruneCache', <String, Object?>{
        'maxBytes': ?maxBytes,
        'maxAgeMs': ?maxAge?.inMilliseconds,
      }),
    );
  }

  Future<Object?> _invoke(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw const MangaTileDecoderException(
        code: 'MISSING_PLUGIN',
        message: 'The Android tiled-image decoder is unavailable',
      );
    } on PlatformException catch (error) {
      throw MangaTileDecoderException(
        code: error.code,
        message: error.message ?? 'Android tiled-image request failed',
      );
    }
  }
}

Map<String, Object?> _channelMap(Object? value, String label) {
  if (value is! Map) {
    throw MangaTileDecoderException(
      code: 'INVALID_RESPONSE',
      message: 'Native $label response is not a map',
    );
  }
  return value.map<String, Object?>((key, value) {
    if (key is! String) {
      throw MangaTileDecoderException(
        code: 'INVALID_RESPONSE',
        message: 'Native $label response contains a non-string key',
      );
    }
    return MapEntry(key, value);
  });
}

String _requiredString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is String && value.isNotEmpty) return value;
  throw MangaTileDecoderException(
    code: 'INVALID_RESPONSE',
    message: 'Native response field $key is invalid',
  );
}

int _positiveInt(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is num && value.isFinite && value > 0 && value == value.toInt()) {
    return value.toInt();
  }
  throw MangaTileDecoderException(
    code: 'INVALID_RESPONSE',
    message: 'Native response field $key is invalid',
  );
}

int _nonNegativeInt(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is num && value.isFinite && value >= 0 && value == value.toInt()) {
    return value.toInt();
  }
  throw MangaTileDecoderException(
    code: 'INVALID_RESPONSE',
    message: 'Native response field $key is invalid',
  );
}

int _boundedPositiveInt(
  Map<String, Object?> map,
  String key, {
  required int maximum,
}) {
  final value = _positiveInt(map, key);
  if (value <= maximum) return value;
  throw MangaTileDecoderException(
    code: 'INVALID_RESPONSE',
    message: 'Native response field $key exceeds its safety limit',
  );
}

int _boundedNonNegativeInt(
  Map<String, Object?> map,
  String key, {
  required int maximum,
}) {
  final value = _nonNegativeInt(map, key);
  if (value <= maximum) return value;
  throw MangaTileDecoderException(
    code: 'INVALID_RESPONSE',
    message: 'Native response field $key exceeds its safety limit',
  );
}

bool _looksLikeAbsoluteFilePath(String path) =>
    path.startsWith('/') || RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path);
