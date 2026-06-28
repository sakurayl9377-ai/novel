class Anime {
  final int id;
  final String title;
  final String subtitle;
  final String coverUrl;
  final String slideUrl;
  final String status;
  final String year;
  final String area;
  final String category;
  final String actors;
  final String director;
  final String description;
  final List<AnimePlaySource> playSources;

  const Anime({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.coverUrl = '',
    this.slideUrl = '',
    this.status = '',
    this.year = '',
    this.area = '',
    this.category = '',
    this.actors = '',
    this.director = '',
    this.description = '',
    this.playSources = const [],
  });

  bool get hasPlayableEpisode =>
      playSources.any((source) => source.episodes.isNotEmpty);

  AnimeEpisode? get firstEpisode {
    for (final source in playSources) {
      if (source.episodes.isNotEmpty) return source.episodes.first;
    }
    return null;
  }

  factory Anime.fromJson(Map<String, dynamic> json) {
    return Anime(
      id: _asInt(json['vod_id']),
      title: _asString(json['vod_name']),
      subtitle: _asString(json['vod_sub']),
      coverUrl: _normalizeImageUrl(_asString(json['vod_pic'])),
      slideUrl: _normalizeImageUrl(_asString(json['vod_pic_slide'])),
      status: _asString(json['vod_remarks']),
      year: _asString(json['vod_year']),
      area: _asString(json['vod_area']),
      category: _asString(json['vod_class']),
      actors: _asString(json['vod_actor']),
      director: _asString(json['vod_director']),
      description: _stripHtml(
        _asString(json['vod_blurb']).isNotEmpty
            ? _asString(json['vod_blurb'])
            : _asString(json['vod_content']),
      ),
      playSources: _parsePlaySources(
        _asString(json['vod_play_from']),
        _asString(json['vod_play_url']),
      ),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _asString(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  static String _normalizeImageUrl(String value) {
    if (value.isEmpty) return '';
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('//')) return 'https:$value';
    return 'https://www.yinhuadm.xyz/${value.replaceFirst(RegExp(r'^/+'), '')}';
  }

  static String _stripHtml(String value) {
    return value
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static List<AnimePlaySource> _parsePlaySources(
    String fromValue,
    String playValue,
  ) {
    if (playValue.isEmpty) return const [];

    final sourceNames = fromValue.split(r'$$$');
    final sourceBlocks = playValue.split(r'$$$');
    final sources = <AnimePlaySource>[];
    for (var i = 0; i < sourceBlocks.length; i++) {
      final episodes = sourceBlocks[i]
          .split('#')
          .map((part) => AnimeEpisode.fromRaw(part))
          .whereType<AnimeEpisode>()
          .toList();
      if (episodes.isEmpty) continue;
      final rawName = i < sourceNames.length
          ? sourceNames[i]
          : 'source${i + 1}';
      sources.add(
        AnimePlaySource(name: _friendlySourceName(rawName), episodes: episodes),
      );
    }
    return sources;
  }

  static String _friendlySourceName(String value) {
    final lower = value.toLowerCase();
    if (lower.contains('lz')) return 'Laoz';
    if (lower.contains('bf')) return 'Bfeng';
    if (lower.contains('ff')) return 'Diff';
    return value.isEmpty ? '播放源' : value;
  }
}

class AnimePlaySource {
  final String name;
  final List<AnimeEpisode> episodes;

  const AnimePlaySource({required this.name, required this.episodes});
}

class AnimeEpisode {
  final String title;
  final String url;

  const AnimeEpisode({required this.title, required this.url});

  static AnimeEpisode? fromRaw(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final separator = trimmed.indexOf(r'$');
    if (separator <= 0 || separator >= trimmed.length - 1) return null;
    final title = trimmed.substring(0, separator).trim();
    final url = trimmed.substring(separator + 1).trim();
    if (title.isEmpty || url.isEmpty) return null;
    return AnimeEpisode(title: title, url: url);
  }
}
