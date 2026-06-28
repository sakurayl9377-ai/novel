class Manga {
  const Manga({
    required this.id,
    required this.title,
    this.coverUrl = '',
    this.author = '',
    this.status = '',
    this.latestChapter = '',
    this.description = '',
    this.chapters = const [],
  });

  final String id;
  final String title;
  final String coverUrl;
  final String author;
  final String status;
  final String latestChapter;
  final String description;
  final List<MangaChapter> chapters;

  bool get hasChapters => chapters.isNotEmpty;
}

class MangaChapter {
  const MangaChapter({required this.title, required this.url, this.id = 0});

  final String title;
  final String url;
  final int id;

  Map<String, dynamic> toJson() {
    return {'title': title, 'url': url, 'id': id};
  }

  factory MangaChapter.fromJson(Map<String, dynamic> json) {
    return MangaChapter(
      title: _asString(json['title']),
      url: _asString(json['url']),
      id: _asInt(json['id']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _asString(dynamic value) {
    return value?.toString().trim() ?? '';
  }
}
