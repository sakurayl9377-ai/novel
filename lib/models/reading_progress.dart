class ReadingProgress {
  final String novelId;
  final int chapterIndex;
  final double scrollPosition;
  final int charPosition;
  final DateTime lastReadAt;

  ReadingProgress({
    required this.novelId,
    this.chapterIndex = 0,
    this.scrollPosition = 0.0,
    this.charPosition = 0,
    DateTime? lastReadAt,
  }) : lastReadAt = lastReadAt ?? DateTime.now();

  ReadingProgress copyWith({
    String? novelId,
    int? chapterIndex,
    double? scrollPosition,
    int? charPosition,
    DateTime? lastReadAt,
  }) {
    return ReadingProgress(
      novelId: novelId ?? this.novelId,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      scrollPosition: scrollPosition ?? this.scrollPosition,
      charPosition: charPosition ?? this.charPosition,
      lastReadAt: lastReadAt ?? this.lastReadAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'novelId': novelId,
    'chapterIndex': chapterIndex,
    'scrollPosition': scrollPosition,
    'charPosition': charPosition,
    'lastReadAt': lastReadAt.toIso8601String(),
  };

  factory ReadingProgress.fromJson(Map<String, dynamic> json) => ReadingProgress(
    novelId: json['novelId'] as String,
    chapterIndex: json['chapterIndex'] as int? ?? 0,
    scrollPosition: (json['scrollPosition'] as num?)?.toDouble() ?? 0.0,
    charPosition: json['charPosition'] as int? ?? 0,
    lastReadAt: json['lastReadAt'] != null ? DateTime.parse(json['lastReadAt'] as String) : DateTime.now(),
  );
}
