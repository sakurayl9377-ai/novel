import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/anime.dart';
import '../models/wuhandky_video.dart';
import '../services/wuhandky_service.dart';
import 'anime_player_screen.dart';

class VideoDetailScreen extends StatefulWidget {
  const VideoDetailScreen({super.key, required this.item});

  final WuhandkyVideoItem item;

  @override
  State<VideoDetailScreen> createState() => _VideoDetailScreenState();
}

class _VideoDetailScreenState extends State<VideoDetailScreen> {
  final WuhandkyService _service = WuhandkyService();
  WuhandkyVideoDetail? _detail;
  bool _loading = true;
  String _error = '';
  int _sourceIndex = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final detail = await _service.fetchDetail(widget.item.detailUrl);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _sourceIndex = 0;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _play(
    WuhandkyVideoDetail detail,
    WuhandkyPlaySource source,
    WuhandkyEpisode episode,
  ) {
    final animeSources = detail.sources
        .map(
          (item) => AnimePlaySource(
            name: item.name,
            episodes: item.episodes
                .map(
                  (episode) =>
                      AnimeEpisode(title: episode.title, url: episode.pageUrl),
                )
                .toList(),
          ),
        )
        .toList();
    final selectedSource = animeSources[detail.sources.indexOf(source)];
    final selectedEpisode =
        selectedSource.episodes[source.episodes.indexOf(episode)];
    final anime = Anime(
      id: _stableVideoId(detail.detailUrl),
      title: detail.title,
      coverUrl: detail.coverUrl,
      status: detail.status,
      year: detail.year,
      area: detail.area,
      category: detail.category,
      actors: detail.actors,
      director: detail.director,
      description: detail.description,
      playSources: animeSources,
    );
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AnimePlayerScreen(
          anime: anime,
          source: selectedSource,
          episode: selectedEpisode,
          episodeUrlResolver: (episode) =>
              _service.resolveEpisodeUrl(episode.url),
          requireLoginAfterFirstEpisode: false,
        ),
      ),
    );
  }

  int _stableVideoId(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return 1500000000 + (hash % 500000000);
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(detail?.title ?? widget.item.title)),
      body: _loading && detail == null
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty && detail == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _load,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : detail == null
          ? const SizedBox.shrink()
          : _buildDetail(detail),
    );
  }

  Widget _buildDetail(WuhandkyVideoDetail detail) {
    final source = detail.sources.isEmpty ? null : detail.sources[_sourceIndex];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 118,
                height: 174,
                child: detail.coverUrl.isEmpty
                    ? const ColoredBox(
                        color: Color(0xFFE7E7E7),
                        child: Icon(Icons.movie_outlined),
                      )
                    : CachedNetworkImage(
                        imageUrl: detail.coverUrl,
                        fit: BoxFit.cover,
                        httpHeaders: const {
                          'Referer': 'https://www.wuhandky.com/',
                        },
                        errorWidget: (_, _, _) => const ColoredBox(
                          color: Color(0xFFE7E7E7),
                          child: Icon(Icons.movie_outlined),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    detail.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  _infoLine('状态', detail.status),
                  _infoLine('类型', detail.category),
                  _infoLine('年份', detail.year),
                  _infoLine('地区', detail.area),
                  _infoLine('导演', detail.director),
                ],
              ),
            ),
          ],
        ),
        if (detail.actors.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            '主演：${detail.actors}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
        if (detail.description.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text('剧情简介', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(detail.description, style: const TextStyle(height: 1.65)),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Text('播放选集', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            Text('${source?.episodes.length ?? 0} 集'),
          ],
        ),
        if (detail.sources.length > 1) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: detail.sources.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => ChoiceChip(
                label: Text(detail.sources[index].name),
                selected: index == _sourceIndex,
                onSelected: (_) => setState(() => _sourceIndex = index),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (source == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: Text('暂无可用播放线路')),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              childAspectRatio: 2.15,
              crossAxisSpacing: 9,
              mainAxisSpacing: 9,
            ),
            itemCount: source.episodes.length,
            itemBuilder: (context, index) {
              final episode = source.episodes[index];
              return OutlinedButton(
                onPressed: () => _play(detail, source, episode),
                child: Text(
                  episode.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _infoLine(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '$label：$value',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
