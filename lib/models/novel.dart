import 'dart:convert';

class Novel {
  final String id;
  final String title;
  final String author;
  final String coverUrl;
  final String description;
  final String sourceId;
  final String sourceName;
  final String localPath;
  final String chapterUrl;
  final bool isLocal;
  final double rating;
  final String status;
  final int chapterCount;
  final DateTime addedAt;
  final DateTime lastReadAt;
  final int currentChapterIndex;
  final int totalChapters;

  Novel({
    required this.id,
    required this.title,
    this.author = '',
    this.coverUrl = '',
    this.description = '',
    this.sourceId = '',
    this.sourceName = '',
    this.localPath = '',
    this.chapterUrl = '',
    this.isLocal = false,
    this.rating = 0.0,
    this.status = '连载中',
    this.chapterCount = 0,
    DateTime? addedAt,
    DateTime? lastReadAt,
    this.currentChapterIndex = 0,
    this.totalChapters = 0,
  })  : addedAt = addedAt ?? DateTime.now(),
        lastReadAt = lastReadAt ?? DateTime.now();

  Novel copyWith({
    String? id,
    String? title,
    String? author,
    String? coverUrl,
    String? description,
    String? sourceId,
    String? sourceName,
    String? localPath,
    String? chapterUrl,
    bool? isLocal,
    double? rating,
    String? status,
    int? chapterCount,
    DateTime? addedAt,
    DateTime? lastReadAt,
    int? currentChapterIndex,
    int? totalChapters,
  }) {
    return Novel(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      coverUrl: coverUrl ?? this.coverUrl,
      description: description ?? this.description,
      sourceId: sourceId ?? this.sourceId,
      sourceName: sourceName ?? this.sourceName,
      localPath: localPath ?? this.localPath,
      chapterUrl: chapterUrl ?? this.chapterUrl,
      isLocal: isLocal ?? this.isLocal,
      rating: rating ?? this.rating,
      status: status ?? this.status,
      chapterCount: chapterCount ?? this.chapterCount,
      addedAt: addedAt ?? this.addedAt,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      currentChapterIndex: currentChapterIndex ?? this.currentChapterIndex,
      totalChapters: totalChapters ?? this.totalChapters,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'coverUrl': coverUrl,
    'description': description,
    'sourceId': sourceId,
    'sourceName': sourceName,
    'localPath': localPath,
    'chapterUrl': chapterUrl,
    'isLocal': isLocal,
    'rating': rating,
    'status': status,
    'chapterCount': chapterCount,
    'addedAt': addedAt.toIso8601String(),
    'lastReadAt': lastReadAt.toIso8601String(),
    'currentChapterIndex': currentChapterIndex,
    'totalChapters': totalChapters,
  };

  factory Novel.fromJson(Map<String, dynamic> json) => Novel(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    author: json['author'] as String? ?? '',
    coverUrl: json['coverUrl'] as String? ?? '',
    description: json['description'] as String? ?? '',
    sourceId: json['sourceId'] as String? ?? '',
    sourceName: json['sourceName'] as String? ?? '',
    localPath: json['localPath'] as String? ?? '',
    chapterUrl: json['chapterUrl'] as String? ?? '',
    isLocal: json['isLocal'] as bool? ?? false,
    rating: (json['rating'] as num?)?.toDouble() ?? 0.0,
    status: json['status'] as String? ?? '连载中',
    chapterCount: json['chapterCount'] as int? ?? 0,
    addedAt: json['addedAt'] != null ? DateTime.parse(json['addedAt'] as String) : DateTime.now(),
    lastReadAt: json['lastReadAt'] != null ? DateTime.parse(json['lastReadAt'] as String) : DateTime.now(),
    currentChapterIndex: json['currentChapterIndex'] as int? ?? 0,
    totalChapters: json['totalChapters'] as int? ?? 0,
  );

  String toJsonString() => jsonEncode(toJson());
}
