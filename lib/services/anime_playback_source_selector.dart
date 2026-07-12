import '../models/anime.dart';

class AnimePlaybackSourceSelector {
  const AnimePlaybackSourceSelector._();

  static int preferredIndex(Anime? anime) {
    final sources = anime?.playSources ?? const <AnimePlaySource>[];
    var bestIndex = -1;
    var bestScore = 1 << 20;
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      if (source.episodes.isEmpty) continue;
      final sourceScore = score(source);
      if (sourceScore < bestScore) {
        bestScore = sourceScore;
        bestIndex = index;
      }
    }
    return bestIndex < 0 ? 0 : bestIndex;
  }

  static int score(AnimePlaySource source) {
    final name = source.name.toLowerCase();
    if (name.contains('laoz') || name.contains('lz')) return 0;
    if (name.contains('diff') || name.contains('ff')) return 1;
    if (name.contains('bfeng') || name.contains('bf')) return 2;
    return 3;
  }

  static AnimeEpisode episodeForSource({
    required AnimePlaySource source,
    required AnimeEpisode currentEpisode,
    required int currentIndex,
  }) {
    final matchingIndex = source.episodes.indexWhere(
      (item) => item.title.trim() == currentEpisode.title.trim(),
    );
    final targetIndex = matchingIndex >= 0
        ? matchingIndex
        : currentIndex.clamp(0, source.episodes.length - 1).toInt();
    return source.episodes[targetIndex];
  }
}
