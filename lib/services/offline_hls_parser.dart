import 'dart:convert';

class OfflineHlsVariant {
  const OfflineHlsVariant({
    required this.uri,
    required this.bandwidth,
    required this.streamInfLine,
    this.audioGroup = '',
  });

  final Uri uri;
  final int bandwidth;
  final String streamInfLine;
  final String audioGroup;
}

class OfflineHlsResource {
  const OfflineHlsResource({
    required this.uri,
    required this.fileName,
    this.range,
  });

  final Uri uri;
  final String fileName;
  final String? range;
}

class OfflineHlsRendition {
  const OfflineHlsRendition({
    required this.uri,
    required this.line,
    required this.uriText,
  });

  final Uri uri;
  final String line;
  final String uriText;

  String localLine(String localUri) => line.replaceFirst(uriText, localUri);
}

class OfflineHlsManifest {
  const OfflineHlsManifest({required this.lines, required this.resources});

  final List<String> lines;
  final List<OfflineHlsResource> resources;
}

OfflineHlsVariant? selectHighestBandwidthHlsVariant(
  String manifest,
  Uri baseUri,
) {
  final lines = const LineSplitter().convert(manifest);
  OfflineHlsVariant? selected;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    var next = index + 1;
    while (next < lines.length &&
        (lines[next].trim().isEmpty || lines[next].trim().startsWith('#'))) {
      next += 1;
    }
    if (next >= lines.length) continue;
    final attributes = parseHlsAttributeList(
      line.substring('#EXT-X-STREAM-INF:'.length),
    );
    final bandwidth =
        int.tryParse(
          attributes['AVERAGE-BANDWIDTH'] ?? attributes['BANDWIDTH'] ?? '',
        ) ??
        0;
    final candidate = OfflineHlsVariant(
      uri: baseUri.resolve(lines[next].trim()),
      bandwidth: bandwidth,
      streamInfLine: line,
      audioGroup: _unquote(attributes['AUDIO'] ?? ''),
    );
    if (selected == null || candidate.bandwidth >= selected.bandwidth) {
      selected = candidate;
    }
  }
  return selected;
}

OfflineHlsRendition? selectHlsMediaRendition(
  String manifest,
  Uri baseUri, {
  required String type,
  required String groupId,
}) {
  OfflineHlsRendition? fallback;
  for (final original in const LineSplitter().convert(manifest)) {
    final line = original.trim();
    if (!line.startsWith('#EXT-X-MEDIA:')) continue;
    final attributes = parseHlsAttributeList(
      line.substring('#EXT-X-MEDIA:'.length),
    );
    if (_unquote(attributes['TYPE'] ?? '') != type ||
        _unquote(attributes['GROUP-ID'] ?? '') != groupId) {
      continue;
    }
    final uriText = _unquote(attributes['URI'] ?? '');
    if (uriText.isEmpty) continue;
    final rendition = OfflineHlsRendition(
      uri: baseUri.resolve(uriText),
      line: line,
      uriText: uriText,
    );
    if (_unquote(attributes['DEFAULT'] ?? '').toUpperCase() == 'YES') {
      return rendition;
    }
    fallback ??= rendition;
  }
  return fallback;
}

OfflineHlsManifest parseOfflineHlsMediaPlaylist(
  String manifest,
  Uri baseUri, {
  String segmentPrefix = 'segment',
  String assetPrefix = 'asset',
}) {
  if (!manifest.trimLeft().startsWith('#EXTM3U')) {
    throw const FormatException('播放列表格式无效');
  }
  final lines = const LineSplitter().convert(manifest);
  final output = <String>[];
  final resources = <OfflineHlsResource>[];
  final assetNames = <String, String>{};
  final lastRangeEndByUri = <String, int>{};
  String? pendingRangeSpec;
  var sequence = 0;
  var assetSequence = 0;

  for (final original in lines) {
    final line = original.trim();
    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      pendingRangeSpec = line.substring('#EXT-X-BYTERANGE:'.length).trim();
      continue;
    }
    if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')) {
      final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
      if (uriMatch == null) {
        output.add(original);
        continue;
      }
      final uriText = uriMatch.group(1)!;
      final uri = baseUri.resolve(uriText);
      if (uri.scheme == 'data') {
        output.add(original);
        continue;
      }
      final mapRangeMatch = line.startsWith('#EXT-X-MAP:')
          ? RegExp(r'BYTERANGE="([^"]+)"').firstMatch(line)
          : null;
      final range = mapRangeMatch == null
          ? null
          : _rangeHeader(mapRangeMatch.group(1)!, 0);
      final assetKey = '${uri.toString()}|${range ?? ''}';
      final fileName = assetNames.putIfAbsent(assetKey, () {
        final extension = safeHlsExtension(uri.path, fallback: '.bin');
        return '${assetPrefix}_${assetSequence++}$extension';
      });
      if (!resources.any((resource) => resource.fileName == fileName)) {
        resources.add(
          OfflineHlsResource(uri: uri, fileName: fileName, range: range),
        );
      }
      var rewritten = original.replaceFirst(uriText, fileName);
      if (mapRangeMatch != null) {
        rewritten = rewritten
            .replaceFirst(RegExp(r',?BYTERANGE="[^"]+"'), '')
            .replaceAll(',,', ',');
      }
      output.add(rewritten);
      continue;
    }
    if (line.isEmpty || line.startsWith('#')) {
      output.add(original);
      continue;
    }

    final uri = baseUri.resolve(line);
    String? range;
    if (pendingRangeSpec != null) {
      final implicitStart = lastRangeEndByUri[uri.toString()] ?? 0;
      range = _rangeHeader(pendingRangeSpec, implicitStart);
      if (range != null) {
        final end = int.tryParse(range.split('-').last);
        if (end != null) lastRangeEndByUri[uri.toString()] = end + 1;
      }
    }
    pendingRangeSpec = null;
    final extension = safeHlsExtension(uri.path, fallback: '.ts');
    final fileName =
        '${segmentPrefix}_${sequence.toString().padLeft(6, '0')}$extension';
    sequence += 1;
    resources.add(
      OfflineHlsResource(uri: uri, fileName: fileName, range: range),
    );
    output.add(fileName);
  }
  return OfflineHlsManifest(lines: output, resources: resources);
}

Map<String, String> parseHlsAttributeList(String value) {
  final result = <String, String>{};
  final matcher = RegExp(r'([A-Z0-9-]+)=((?:"[^"]*")|[^,]*)');
  for (final match in matcher.allMatches(value)) {
    result[match.group(1)!] = match.group(2)!.trim();
  }
  return result;
}

String safeHlsExtension(String path, {required String fallback}) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot < 0) return fallback;
  final extension = name.substring(dot).toLowerCase();
  return RegExp(r'^\.[a-z0-9]{1,6}$').hasMatch(extension)
      ? extension
      : fallback;
}

String? _rangeHeader(String value, int implicitStart) {
  final parts = value.trim().split('@');
  final length = int.tryParse(parts.first);
  if (length == null || length <= 0) return null;
  final start = parts.length > 1 ? int.tryParse(parts[1]) : implicitStart;
  if (start == null || start < 0) return null;
  return 'bytes=$start-${start + length - 1}';
}

String _unquote(String value) {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}
