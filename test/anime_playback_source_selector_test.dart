import 'package:flutter_test/flutter_test.dart';
import 'package:novel_app/models/anime.dart';
import 'package:novel_app/services/anime_playback_source_selector.dart';

void main() {
  const episode1 = AnimeEpisode(title: '第01集', url: 'https://bf/1.m3u8');
  const episode2 = AnimeEpisode(title: '第02集', url: 'https://bf/2.m3u8');
  const bfeng = AnimePlaySource(name: 'Bfeng', episodes: [episode1, episode2]);
  const laoz = AnimePlaySource(
    name: 'Laoz',
    episodes: [
      AnimeEpisode(title: '第01集', url: 'https://lz/1.m3u8'),
      AnimeEpisode(title: '第02集', url: 'https://lz/2.m3u8'),
    ],
  );
  const diff = AnimePlaySource(
    name: 'Diff',
    episodes: [
      AnimeEpisode(title: '第00集', url: 'https://ff/0.m3u8'),
      AnimeEpisode(title: '第01集', url: 'https://ff/1.m3u8'),
    ],
  );

  test('prefers the more reliable Laoz line over Bfeng', () {
    const anime = Anime(id: 1, title: 'test', playSources: [bfeng, diff, laoz]);
    expect(AnimePlaybackSourceSelector.preferredIndex(anime), 2);
  });

  test('fallback aligns episodes by title before using list index', () {
    final selected = AnimePlaybackSourceSelector.episodeForSource(
      source: diff,
      currentEpisode: episode1,
      currentIndex: 0,
    );
    expect(selected.title, '第01集');
    expect(selected.url, 'https://ff/1.m3u8');
  });
}
