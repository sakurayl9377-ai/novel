class WuhandkyVideoItem {
  const WuhandkyVideoItem({
    required this.title,
    required this.detailUrl,
    this.coverUrl = '',
    this.note = '',
    this.score = '',
  });

  final String title;
  final String detailUrl;
  final String coverUrl;
  final String note;
  final String score;
}

class WuhandkyVideoDetail {
  const WuhandkyVideoDetail({
    required this.title,
    required this.detailUrl,
    this.coverUrl = '',
    this.status = '',
    this.year = '',
    this.area = '',
    this.category = '',
    this.actors = '',
    this.director = '',
    this.description = '',
    this.sources = const [],
  });

  final String title;
  final String detailUrl;
  final String coverUrl;
  final String status;
  final String year;
  final String area;
  final String category;
  final String actors;
  final String director;
  final String description;
  final List<WuhandkyPlaySource> sources;
}

class WuhandkyPlaySource {
  const WuhandkyPlaySource({required this.name, required this.episodes});

  final String name;
  final List<WuhandkyEpisode> episodes;
}

class WuhandkyEpisode {
  const WuhandkyEpisode({required this.title, required this.pageUrl});

  final String title;
  final String pageUrl;
}
