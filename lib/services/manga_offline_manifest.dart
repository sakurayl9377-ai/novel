import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const int currentMangaOfflineManifestVersion = 2;

String mangaOfflineSourceDigest(String source) {
  return sha256.convert(utf8.encode(source.trim())).toString();
}

class MangaOfflineManifest {
  const MangaOfflineManifest({
    required this.chapterUrl,
    required this.sources,
    required this.sourceDigests,
    required this.files,
    this.version = currentMangaOfflineManifestVersion,
  });

  final int version;
  final String chapterUrl;
  final List<String> sources;
  final List<String> sourceDigests;
  final List<String> files;

  Map<String, dynamic> toJson() => {
    'version': version,
    'chapterUrl': chapterUrl,
    'sources': sources,
    'sourceDigests': sourceDigests,
    'files': files,
  };

  factory MangaOfflineManifest.fromJson(Map<String, dynamic> json) {
    List<String> strings(dynamic value) {
      if (value is! List) return const [];
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }

    return MangaOfflineManifest(
      version: (json['version'] as num?)?.toInt() ?? 0,
      chapterUrl: json['chapterUrl']?.toString().trim() ?? '',
      sources: strings(json['sources']),
      sourceDigests: strings(json['sourceDigests']),
      files: strings(json['files']),
    );
  }
}

Future<MangaOfflineManifest?> readMangaOfflineManifest(File file) async {
  if (!await file.exists() || await file.length() <= 0) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final manifest = MangaOfflineManifest.fromJson(
      decoded.cast<String, dynamic>(),
    );
    if (manifest.version != currentMangaOfflineManifestVersion ||
        manifest.chapterUrl.isEmpty ||
        manifest.sources.isEmpty ||
        manifest.sources.length != manifest.sourceDigests.length ||
        manifest.sources.length != manifest.files.length ||
        !_hasValidSourceDigests(manifest) ||
        !_hasValidRelativeFiles(manifest.files)) {
      return null;
    }
    return manifest;
  } catch (_) {
    return null;
  }
}

bool _hasValidRelativeFiles(List<String> files) {
  final seen = <String>{};
  for (final path in files) {
    final uri = Uri.tryParse(path);
    if (uri == null ||
        path.contains(r'\') ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isEmpty ||
        uri.path.startsWith('/') ||
        uri.pathSegments.any((segment) => segment == '.' || segment == '..') ||
        !seen.add(path)) {
      return false;
    }
  }
  return true;
}

bool _hasValidSourceDigests(MangaOfflineManifest manifest) {
  for (var index = 0; index < manifest.sources.length; index++) {
    if (manifest.sourceDigests[index] !=
        mangaOfflineSourceDigest(manifest.sources[index])) {
      return false;
    }
  }
  return true;
}

Future<void> writeMangaOfflineManifest(
  File file,
  MangaOfflineManifest manifest,
) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(manifest.toJson()), flush: true);
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
}

/// Removes cached pages that cannot be proven to belong to the refreshed
/// source at the same page index. Matching partial files are kept so a failed
/// download can still resume safely.
Future<void> discardMismatchedMangaOfflinePages({
  required Directory downloadDirectory,
  required MangaOfflineManifest? previousManifest,
  required String chapterUrl,
  required List<String> refreshedSources,
  required List<String> refreshedFiles,
}) async {
  if (refreshedSources.length != refreshedFiles.length ||
      !_hasValidRelativeFiles(refreshedFiles)) {
    throw const FormatException('Invalid refreshed manga page manifest');
  }

  final previousIsUsable =
      previousManifest != null &&
      previousManifest.chapterUrl == chapterUrl &&
      previousManifest.sources.length ==
          previousManifest.sourceDigests.length &&
      previousManifest.sources.length == previousManifest.files.length &&
      _hasValidSourceDigests(previousManifest) &&
      _hasValidRelativeFiles(previousManifest.files);
  if (!previousIsUsable) {
    final pagesDirectory = Directory('${downloadDirectory.path}/pages');
    if (await pagesDirectory.exists()) {
      await pagesDirectory.delete(recursive: true);
    }
    return;
  }

  final refreshedDigests = refreshedSources
      .map(mangaOfflineSourceDigest)
      .toList(growable: false);
  final previous = previousManifest;
  final reusableFiles = <String>{};
  final comparableCount = previous.files.length < refreshedFiles.length
      ? previous.files.length
      : refreshedFiles.length;
  for (var index = 0; index < comparableCount; index++) {
    if (previous.sourceDigests[index] == refreshedDigests[index] &&
        previous.files[index] == refreshedFiles[index]) {
      reusableFiles.add(refreshedFiles[index]);
    }
  }

  final staleFiles = <String>{
    ...previous.files.where((path) => !reusableFiles.contains(path)),
    ...refreshedFiles.where((path) => !reusableFiles.contains(path)),
  };
  for (final relativePath in staleFiles) {
    final file = File.fromUri(downloadDirectory.uri.resolve(relativePath));
    if (await file.exists()) await file.delete();
    final partial = File('${file.path}.part');
    if (await partial.exists()) await partial.delete();
  }
}

Future<List<String>> validateMangaOfflineArchive({
  required File manifestFile,
  required Directory allowedRoot,
  required String expectedChapterUrl,
  int expectedPageCount = 0,
}) async {
  final manifest = await readMangaOfflineManifest(manifestFile);
  if (manifest == null ||
      manifest.chapterUrl != expectedChapterUrl ||
      (expectedPageCount > 0 && manifest.files.length != expectedPageCount)) {
    return const [];
  }

  try {
    if (!await allowedRoot.exists()) return const [];
    final resolvedRoot = await allowedRoot.resolveSymbolicLinks();
    final resolvedManifest = await manifestFile.resolveSymbolicLinks();
    if (!_isWithinDirectory(resolvedRoot, resolvedManifest)) return const [];

    final paths = <String>[];
    final seen = <String>{};
    for (final relativePath in manifest.files) {
      final uri = Uri.tryParse(relativePath);
      if (uri == null ||
          uri.hasScheme ||
          uri.hasAuthority ||
          uri.path.startsWith('/') ||
          uri.pathSegments.contains('..')) {
        return const [];
      }
      final file = File.fromUri(manifestFile.parent.uri.resolveUri(uri));
      if (!await file.exists() || !await isLikelyMangaImageFile(file)) {
        return const [];
      }
      final resolvedFile = await file.resolveSymbolicLinks();
      if (!_isWithinDirectory(resolvedRoot, resolvedFile) ||
          !seen.add(resolvedFile)) {
        return const [];
      }
      paths.add(file.absolute.path);
    }
    return paths;
  } catch (_) {
    return const [];
  }
}

Future<bool> isLikelyMangaImageFile(File file) async {
  if (!await file.exists()) return false;
  final length = await file.length();
  if (length < 4) return false;
  RandomAccessFile? handle;
  try {
    handle = await file.open();
    final bytes = await handle.read(16);
    await handle.setPosition((length - 16).clamp(0, length));
    final tail = await handle.read(16);
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return tail.length >= 2 &&
          tail[tail.length - 2] == 0xff &&
          tail.last == 0xd9;
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return tail.length >= 8 &&
          ascii.decode(
                tail.skip(tail.length - 8).take(4).toList(),
                allowInvalid: true,
              ) ==
              'IEND';
    }
    if (bytes.length >= 6) {
      final signature = ascii.decode(
        bytes.take(6).toList(),
        allowInvalid: true,
      );
      if (signature == 'GIF87a' || signature == 'GIF89a') {
        return tail.isNotEmpty && tail.last == 0x3b;
      }
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.take(4).toList(), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.skip(8).take(4).toList(), allowInvalid: true) ==
            'WEBP') {
      final declaredLength =
          bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24);
      return declaredLength + 8 == length;
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.skip(4).take(4).toList(), allowInvalid: true) ==
            'ftyp') {
      final boxSize =
          (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      if (boxSize < 16 || boxSize > length || boxSize > 64 * 1024) {
        return false;
      }
      await handle.setPosition(0);
      final box = await handle.read(boxSize);
      const allowedBrands = {'avif', 'avis', 'mif1'};
      String brandAt(int offset) => ascii
          .decode(box.skip(offset).take(4).toList(), allowInvalid: true)
          .toLowerCase();
      if (allowedBrands.contains(brandAt(8))) return true;
      for (var offset = 16; offset + 4 <= box.length; offset += 4) {
        if (allowedBrands.contains(brandAt(offset))) return true;
      }
      return false;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    await handle?.close();
  }
}

bool _isWithinDirectory(String root, String path) {
  final normalizedRoot = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  return path == root || path.startsWith(normalizedRoot);
}
