class ReadingProgress {
  final String novelId;
  final int chapterIndex;
  final double scrollPosition;
  final int charPosition;
  final String chapterTitle;
  final String chapterUrl;
  final DateTime lastReadAt;

  ReadingProgress({
    required this.novelId,
    this.chapterIndex = 0,
    this.scrollPosition = 0.0,
    this.charPosition = 0,
    this.chapterTitle = '',
    this.chapterUrl = '',
    DateTime? lastReadAt,
  }) : lastReadAt = lastReadAt ?? DateTime.now();

  ReadingProgress copyWith({
    String? novelId,
    int? chapterIndex,
    double? scrollPosition,
    int? charPosition,
    String? chapterTitle,
    String? chapterUrl,
    DateTime? lastReadAt,
  }) {
    return ReadingProgress(
      novelId: novelId ?? this.novelId,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      scrollPosition: scrollPosition ?? this.scrollPosition,
      charPosition: charPosition ?? this.charPosition,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      chapterUrl: chapterUrl ?? this.chapterUrl,
      lastReadAt: lastReadAt ?? this.lastReadAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'novelId': novelId,
    'chapterIndex': chapterIndex,
    'scrollPosition': scrollPosition,
    'charPosition': charPosition,
    'chapterTitle': chapterTitle,
    'chapterUrl': chapterUrl,
    'lastReadAt': lastReadAt.toIso8601String(),
  };

  factory ReadingProgress.fromJson(Map<String, dynamic> json) =>
      ReadingProgress(
        novelId: json['novelId'] as String,
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        scrollPosition: (json['scrollPosition'] as num?)?.toDouble() ?? 0.0,
        charPosition: json['charPosition'] as int? ?? 0,
        chapterTitle: json['chapterTitle'] as String? ?? '',
        chapterUrl: json['chapterUrl'] as String? ?? '',
        lastReadAt: json['lastReadAt'] != null
            ? DateTime.parse(json['lastReadAt'] as String)
            : DateTime.now(),
      );
}

ReadingProgress? latestReadingProgress(
  ReadingProgress? first,
  ReadingProgress? second,
) {
  if (first == null) return second;
  if (second == null) return first;
  return first.lastReadAt.isAfter(second.lastReadAt) ? first : second;
}

class NovelReadingHistory {
  const NovelReadingHistory({
    required this.novelId,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.sourceId,
    required this.sourceName,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.chapterUrl,
    required this.charPosition,
    required this.scrollPosition,
    required this.lastReadAt,
  });

  final String novelId;
  final String title;
  final String author;
  final String coverUrl;
  final String sourceId;
  final String sourceName;
  final int chapterIndex;
  final String chapterTitle;
  final String chapterUrl;
  final int charPosition;
  final double scrollPosition;
  final DateTime lastReadAt;
}
