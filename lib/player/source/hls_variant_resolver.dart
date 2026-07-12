import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../services/offline_hls_parser.dart';

class HlsVariant {
  const HlsVariant({
    required this.uri,
    required this.bandwidth,
    this.averageBandwidth = 0,
    this.width,
    this.height,
    this.frameRate,
    this.codecs = '',
    this.name = '',
  });

  final Uri uri;
  final int bandwidth;
  final int averageBandwidth;
  final int? width;
  final int? height;
  final double? frameRate;
  final String codecs;
  final String name;

  String get label {
    if (name.isNotEmpty) return name;
    if (height != null && height! > 0) return '${height}P';
    final bits = averageBandwidth > 0 ? averageBandwidth : bandwidth;
    if (bits > 0) return '${(bits / 1000000).toStringAsFixed(1)} Mbps';
    return '线路清晰度';
  }
}

class HlsVariantResolver {
  HlsVariantResolver({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  List<HlsVariant> parse(String manifest, Uri baseUri) {
    if (!manifest.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('Invalid HLS manifest');
    }
    final lines = const LineSplitter().convert(manifest);
    final result = <HlsVariant>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      var uriIndex = index + 1;
      while (uriIndex < lines.length) {
        final candidate = lines[uriIndex].trim();
        if (candidate.isNotEmpty && !candidate.startsWith('#')) break;
        uriIndex++;
      }
      if (uriIndex >= lines.length) continue;
      final attributes = parseHlsAttributeList(
        line.substring('#EXT-X-STREAM-INF:'.length),
      );
      final resolution = _unquote(attributes['RESOLUTION'] ?? '').split('x');
      result.add(
        HlsVariant(
          uri: baseUri.resolve(lines[uriIndex].trim()),
          bandwidth: int.tryParse(attributes['BANDWIDTH'] ?? '') ?? 0,
          averageBandwidth:
              int.tryParse(attributes['AVERAGE-BANDWIDTH'] ?? '') ?? 0,
          width: resolution.length == 2 ? int.tryParse(resolution[0]) : null,
          height: resolution.length == 2 ? int.tryParse(resolution[1]) : null,
          frameRate: double.tryParse(attributes['FRAME-RATE'] ?? ''),
          codecs: _unquote(attributes['CODECS'] ?? ''),
          name: _unquote(attributes['NAME'] ?? ''),
        ),
      );
    }
    result.sort((left, right) {
      final byHeight = (left.height ?? 0).compareTo(right.height ?? 0);
      if (byHeight != 0) return byHeight;
      return left.bandwidth.compareTo(right.bandwidth);
    });
    return List.unmodifiable(result);
  }

  Future<List<HlsVariant>> resolve(
    Uri manifestUri, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!manifestUri.hasAuthority ||
        (manifestUri.scheme != 'http' && manifestUri.scheme != 'https')) {
      throw FormatException('Unsupported HLS URI: $manifestUri');
    }
    final response = await _client
        .get(manifestUri, headers: headers)
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'HLS manifest request failed: HTTP ${response.statusCode}',
        uri: manifestUri,
      );
    }
    return parse(
      utf8.decode(response.bodyBytes, allowMalformed: true),
      manifestUri,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

String _unquote(String value) {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
