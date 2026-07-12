import 'dart:io';

import '../player_models.dart';

class ExternalTrackException implements Exception {
  const ExternalTrackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ExternalTrackService {
  static const Set<String> subtitleExtensions = {
    '.srt',
    '.vtt',
    '.ass',
    '.ssa',
  };
  static const Set<String> audioExtensions = {
    '.aac',
    '.ac3',
    '.eac3',
    '.flac',
    '.m4a',
    '.mka',
    '.mp3',
    '.ogg',
    '.opus',
    '.wav',
  };

  Future<PlayerTrackSelection> subtitle(
    Uri uri, {
    String title = '',
    String language = '',
  }) async {
    await _validate(uri, subtitleExtensions, kind: '字幕');
    return PlayerTrackSelection.external(
      PlayerTrackKind.subtitle,
      uri,
      title: title,
      language: language,
    );
  }

  Future<PlayerTrackSelection> audio(
    Uri uri, {
    String title = '',
    String language = '',
  }) async {
    await _validate(uri, audioExtensions, kind: '音轨');
    return PlayerTrackSelection.external(
      PlayerTrackKind.audio,
      uri,
      title: title,
      language: language,
    );
  }

  Future<void> _validate(
    Uri uri,
    Set<String> extensions, {
    required String kind,
  }) async {
    if (!{'file', 'content', 'http', 'https'}.contains(uri.scheme)) {
      throw ExternalTrackException('不支持的$kind地址：${uri.scheme}');
    }
    final extension = _extension(uri.path);
    if (!extensions.contains(extension)) {
      throw ExternalTrackException('不支持的$kind格式：$extension');
    }
    if (uri.scheme == 'file') {
      final file = File(uri.toFilePath());
      if (!await file.exists()) throw ExternalTrackException('$kind文件不存在');
      if (await file.length() <= 0) throw ExternalTrackException('$kind文件为空');
    } else if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        !uri.hasAuthority) {
      throw ExternalTrackException('$kind网络地址无效');
    }
  }

  String _extension(String path) {
    final name = path.toLowerCase().split('/').last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot);
  }
}
