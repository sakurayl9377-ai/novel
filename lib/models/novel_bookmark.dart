class NovelBookmark {
  const NovelBookmark({
    required this.id,
    required this.novelContentKey,
    required this.chapterIndex,
    required this.chapterId,
    required this.chapterTitle,
    required this.charPosition,
    required this.contextText,
    required this.contentDigest,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String novelContentKey;
  final int chapterIndex;
  final String chapterId;
  final String chapterTitle;
  final int charPosition;
  final String contextText;
  final String contentDigest;
  final int createdAtMs;
  final int updatedAtMs;

  NovelBookmark copyWith({
    String? id,
    String? novelContentKey,
    int? chapterIndex,
    String? chapterId,
    String? chapterTitle,
    int? charPosition,
    String? contextText,
    String? contentDigest,
    int? createdAtMs,
    int? updatedAtMs,
  }) {
    return NovelBookmark(
      id: id ?? this.id,
      novelContentKey: novelContentKey ?? this.novelContentKey,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      chapterId: chapterId ?? this.chapterId,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      charPosition: charPosition ?? this.charPosition,
      contextText: contextText ?? this.contextText,
      contentDigest: contentDigest ?? this.contentDigest,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'novelContentKey': novelContentKey,
    'chapterIndex': chapterIndex,
    'chapterId': chapterId,
    'chapterTitle': chapterTitle,
    'charPosition': charPosition,
    'contextText': contextText,
    'contentDigest': contentDigest,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory NovelBookmark.fromJson(Map<String, dynamic> json) {
    return NovelBookmark(
      id: _asString(json['id']),
      novelContentKey: _asString(json['novelContentKey']),
      chapterIndex: _asInt(json['chapterIndex']),
      chapterId: _asString(json['chapterId']),
      chapterTitle: _asString(json['chapterTitle']),
      charPosition: _asInt(json['charPosition']),
      contextText: _asString(json['contextText']),
      contentDigest: _asString(json['contentDigest']),
      createdAtMs: _asInt(json['createdAtMs']),
      updatedAtMs: _asInt(json['updatedAtMs']),
    );
  }

  static String _asString(dynamic value) => value?.toString() ?? '';

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
