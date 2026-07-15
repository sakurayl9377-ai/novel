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
    this.pageCount = 0,
    this.chapterProgress,
    this.sourceKey = 'manga_baozi',
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
  final int pageCount;
  final double? chapterProgress;
  final String sourceKey;

  double get progress {
    final savedProgress = chapterProgress;
    if (savedProgress != null && savedProgress.isFinite) {
      return savedProgress.clamp(0, 1);
    }
    if (contentExtent <= 0) {
      if (pageCount > 0) {
        return ((pageIndex + pageOffsetRatio) / pageCount).clamp(0, 1);
      }
      return scrollOffset > 0 ? 1 : 0;
    }
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

  /// A downloaded chapter may be the only catalog entry we know while its
  /// absolute chapter index is greater than zero. The reader uses index zero
  /// for that one-entry catalog, so history writes must retain the absolute
  /// index separately until a complete catalog is available again.
  int? get sparseCatalogChapterIndexOverride {
    if (chapterIndex <= 0) return null;
    final catalog = chapters.isEmpty ? [chapter] : chapters;
    if (catalog.length > chapterIndex) return null;
    final localIndex = catalog.indexWhere(
      (candidate) => candidate.url == chapterUrl,
    );
    return localIndex >= 0 ? chapterIndex : null;
  }

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
      'pageCount': pageCount,
      if (chapterProgress != null) 'chapterProgress': chapterProgress,
      'sourceKey': sourceKey,
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
      pageCount: _asInt(json['pageCount']),
      chapterProgress: json.containsKey('chapterProgress')
          ? _asDouble(json['chapterProgress'])
          : null,
      sourceKey: _asString(json['sourceKey']).isEmpty
          ? 'manga_baozi'
          : _asString(json['sourceKey']),
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
