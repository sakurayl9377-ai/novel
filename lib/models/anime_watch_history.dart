import 'anime.dart';

class AnimeWatchHistory {
  const AnimeWatchHistory({
    required this.animeId,
    required this.title,
    required this.coverUrl,
    required this.sourceName,
    required this.episodeTitle,
    required this.episodeUrl,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
    required this.episodes,
  });

  final int animeId;
  final String title;
  final String coverUrl;
  final String sourceName;
  final String episodeTitle;
  final String episodeUrl;
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;
  final List<AnimeEpisode> episodes;

  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);

  double get progress {
    if (durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0, 1);
  }

  Anime get anime => Anime(
    id: animeId,
    title: title,
    coverUrl: coverUrl,
    playSources: [source],
  );

  AnimePlaySource get source => AnimePlaySource(
    name: sourceName.isEmpty ? '播放源' : sourceName,
    episodes: episodes.isEmpty ? [episode] : episodes,
  );

  AnimeEpisode get episode =>
      AnimeEpisode(title: episodeTitle, url: episodeUrl);

  Map<String, dynamic> toJson() {
    return {
      'animeId': animeId,
      'title': title,
      'coverUrl': coverUrl,
      'sourceName': sourceName,
      'episodeTitle': episodeTitle,
      'episodeUrl': episodeUrl,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'updatedAtMs': updatedAtMs,
      'episodes': episodes
          .map((episode) => {'title': episode.title, 'url': episode.url})
          .toList(),
    };
  }

  factory AnimeWatchHistory.fromJson(Map<String, dynamic> json) {
    return AnimeWatchHistory(
      animeId: _asInt(json['animeId']),
      title: _asString(json['title']),
      coverUrl: _asString(json['coverUrl']),
      sourceName: _asString(json['sourceName']),
      episodeTitle: _asString(json['episodeTitle']),
      episodeUrl: _asString(json['episodeUrl']),
      positionMs: _asInt(json['positionMs']),
      durationMs: _asInt(json['durationMs']),
      updatedAtMs: _asInt(json['updatedAtMs']),
      episodes: _parseEpisodes(json['episodes']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _asString(dynamic value) {
    return value?.toString().trim() ?? '';
  }

  static List<AnimeEpisode> _parseEpisodes(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map(
          (item) => AnimeEpisode(
            title: _asString(item['title']),
            url: _asString(item['url']),
          ),
        )
        .where((episode) => episode.title.isNotEmpty && episode.url.isNotEmpty)
        .toList();
  }
}
