import 'manga.dart';

class MangaReadHistory {
  const MangaReadHistory({
    required this.mangaId,
    required this.title,
    required this.coverUrl,
    required this.chapterTitle,
    required this.chapterUrl,
    required this.chapterIndex,
    required this.scrollOffset,
    required this.contentExtent,
    required this.updatedAtMs,
    required this.chapters,
    this.pageIndex = 0,
    this.pageOffsetRatio = 0,
  });

  final String mangaId;
  final String title;
  final String coverUrl;
  final String chapterTitle;
  final String chapterUrl;
  final int chapterIndex;
  final double scrollOffset;
  final double contentExtent;
  final int updatedAtMs;
  final List<MangaChapter> chapters;
  final int pageIndex;
  final double pageOffsetRatio;

  double get progress {
    if (contentExtent <= 0) return scrollOffset > 0 ? 1 : 0;
    return (scrollOffset / contentExtent).clamp(0, 1);
  }

  Manga get manga => Manga(
    id: mangaId,
    title: title,
    coverUrl: coverUrl,
    chapters: chapters.isEmpty ? [chapter] : chapters,
  );

  MangaChapter get chapter =>
      MangaChapter(title: chapterTitle, url: chapterUrl);

  Map<String, dynamic> toJson() {
    return {
      'mangaId': mangaId,
      'title': title,
      'coverUrl': coverUrl,
      'chapterTitle': chapterTitle,
      'chapterUrl': chapterUrl,
      'chapterIndex': chapterIndex,
      'scrollOffset': scrollOffset,
      'contentExtent': contentExtent,
      'updatedAtMs': updatedAtMs,
      'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
      'pageIndex': pageIndex,
      'pageOffsetRatio': pageOffsetRatio,
    };
  }

  factory MangaReadHistory.fromJson(Map<String, dynamic> json) {
    return MangaReadHistory(
      mangaId: _asString(json['mangaId']),
      title: _asString(json['title']),
      coverUrl: _asString(json['coverUrl']),
      chapterTitle: _asString(json['chapterTitle']),
      chapterUrl: _asString(json['chapterUrl']),
      chapterIndex: _asInt(json['chapterIndex']),
      scrollOffset: _asDouble(json['scrollOffset']),
      contentExtent: _asDouble(json['contentExtent']),
      updatedAtMs: _asInt(json['updatedAtMs']),
      chapters: _parseChapters(json['chapters']),
      pageIndex: _asInt(json['pageIndex']),
      pageOffsetRatio: _asDouble(json['pageOffsetRatio']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double _asDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _asString(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  static List<MangaChapter> _parseChapters(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => MangaChapter.fromJson(item.cast<String, dynamic>()))
        .where((chapter) => chapter.title.isNotEmpty && chapter.url.isNotEmpty)
        .toList();
  }
}
