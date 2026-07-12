enum LibraryItemType {
  novel('novel'),
  anime('anime'),
  manga('manga');

  const LibraryItemType(this.value);

  final String value;

  static LibraryItemType fromValue(String value) {
    return LibraryItemType.values.firstWhere(
      (item) => item.value == value,
      orElse: () => LibraryItemType.manga,
    );
  }
}

class FavoriteFolder {
  const FavoriteFolder({
    required this.id,
    required this.name,
    required this.createdAtMs,
  });

  final String id;
  final String name;
  final int createdAtMs;

  Map<String, dynamic> toJson() {
    return {'id': id, 'name': name, 'createdAtMs': createdAtMs};
  }

  factory FavoriteFolder.fromJson(Map<String, dynamic> json) {
    return FavoriteFolder(
      id: _asString(json['id']),
      name: _asString(json['name']).isEmpty ? '默认收藏' : _asString(json['name']),
      createdAtMs: _asInt(json['createdAtMs']),
    );
  }
}

class FavoriteItem {
  const FavoriteItem({
    required this.id,
    required this.type,
    required this.itemId,
    required this.title,
    required this.coverUrl,
    required this.folderId,
    required this.createdAtMs,
    this.subtitle = '',
  });

  final String id;
  final LibraryItemType type;
  final String itemId;
  final String title;
  final String coverUrl;
  final String subtitle;
  final String folderId;
  final int createdAtMs;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.value,
      'itemId': itemId,
      'title': title,
      'coverUrl': coverUrl,
      'subtitle': subtitle,
      'folderId': folderId,
      'createdAtMs': createdAtMs,
    };
  }

  factory FavoriteItem.fromJson(Map<String, dynamic> json) {
    return FavoriteItem(
      id: _asString(json['id']),
      type: LibraryItemType.fromValue(_asString(json['type'])),
      itemId: _asString(json['itemId']),
      title: _asString(json['title']),
      coverUrl: _asString(json['coverUrl']),
      subtitle: _asString(json['subtitle']),
      folderId: _asString(json['folderId']).isEmpty
          ? defaultFavoriteFolderId
          : _asString(json['folderId']),
      createdAtMs: _asInt(json['createdAtMs']),
    );
  }
}

class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.type,
    required this.itemId,
    required this.title,
    required this.coverUrl,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.status,
    this.subtitle = '',
    this.sourceName = '',
    this.episodeTitle = '',
    this.episodeUrl = '',
    this.chapterTitle = '',
    this.chapterUrl = '',
    this.chapterIndex = 0,
    this.totalCount = 0,
    this.cachedCount = 0,
    this.localPath = '',
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.errorMessage = '',
  });

  final String id;
  final LibraryItemType type;
  final String itemId;
  final String title;
  final String coverUrl;
  final String subtitle;
  final String sourceName;
  final String episodeTitle;
  final String episodeUrl;
  final String chapterTitle;
  final String chapterUrl;
  final int chapterIndex;
  final int totalCount;
  final int cachedCount;
  final String localPath;
  final int downloadedBytes;
  final int totalBytes;
  final String errorMessage;
  final int createdAtMs;
  final int updatedAtMs;
  final String status;

  double? get progress => totalBytes > 0
      ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
      : totalCount > 0
      ? (cachedCount / totalCount).clamp(0.0, 1.0)
      : null;

  bool get isPlayable => status == 'done' && localPath.isNotEmpty;

  DownloadItem copyWith({
    String? id,
    LibraryItemType? type,
    String? itemId,
    String? title,
    String? coverUrl,
    String? subtitle,
    String? sourceName,
    String? episodeTitle,
    String? episodeUrl,
    String? chapterTitle,
    String? chapterUrl,
    int? chapterIndex,
    int? totalCount,
    int? cachedCount,
    String? localPath,
    int? downloadedBytes,
    int? totalBytes,
    String? errorMessage,
    int? createdAtMs,
    int? updatedAtMs,
    String? status,
  }) {
    return DownloadItem(
      id: id ?? this.id,
      type: type ?? this.type,
      itemId: itemId ?? this.itemId,
      title: title ?? this.title,
      coverUrl: coverUrl ?? this.coverUrl,
      subtitle: subtitle ?? this.subtitle,
      sourceName: sourceName ?? this.sourceName,
      episodeTitle: episodeTitle ?? this.episodeTitle,
      episodeUrl: episodeUrl ?? this.episodeUrl,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      chapterUrl: chapterUrl ?? this.chapterUrl,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      totalCount: totalCount ?? this.totalCount,
      cachedCount: cachedCount ?? this.cachedCount,
      localPath: localPath ?? this.localPath,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.value,
      'itemId': itemId,
      'title': title,
      'coverUrl': coverUrl,
      'subtitle': subtitle,
      'sourceName': sourceName,
      'episodeTitle': episodeTitle,
      'episodeUrl': episodeUrl,
      'chapterTitle': chapterTitle,
      'chapterUrl': chapterUrl,
      'chapterIndex': chapterIndex,
      'totalCount': totalCount,
      'cachedCount': cachedCount,
      'localPath': localPath,
      'downloadedBytes': downloadedBytes,
      'totalBytes': totalBytes,
      'errorMessage': errorMessage,
      'createdAtMs': createdAtMs,
      'updatedAtMs': updatedAtMs,
      'status': status,
    };
  }

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    return DownloadItem(
      id: _asString(json['id']),
      type: LibraryItemType.fromValue(_asString(json['type'])),
      itemId: _asString(json['itemId']),
      title: _asString(json['title']),
      coverUrl: _asString(json['coverUrl']),
      subtitle: _asString(json['subtitle']),
      sourceName: _asString(json['sourceName']),
      episodeTitle: _asString(json['episodeTitle']),
      episodeUrl: _asString(json['episodeUrl']),
      chapterTitle: _asString(json['chapterTitle']),
      chapterUrl: _asString(json['chapterUrl']),
      chapterIndex: _asInt(json['chapterIndex']),
      totalCount: _asInt(json['totalCount']),
      cachedCount: _asInt(json['cachedCount']),
      localPath: _asString(json['localPath']),
      downloadedBytes: _asInt(json['downloadedBytes']),
      totalBytes: _asInt(json['totalBytes']),
      errorMessage: _asString(json['errorMessage']),
      createdAtMs: _asInt(json['createdAtMs']),
      updatedAtMs: _asInt(json['updatedAtMs']),
      status: _asString(json['status']).isEmpty
          ? 'done'
          : _asString(json['status']),
    );
  }
}

const String defaultFavoriteFolderId = 'default';

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _asString(dynamic value) => value?.toString().trim() ?? '';
