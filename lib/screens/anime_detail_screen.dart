import 'dart:async';

import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/anime.dart';
import '../services/anime_service.dart';
import 'anime_player_screen.dart';
import 'anime_screen.dart';

class AnimeDetailScreen extends StatefulWidget {
  final int? animeId;
  final String? title;
  final Anime? initialAnime;

  const AnimeDetailScreen({
    super.key,
    this.animeId,
    this.title,
    this.initialAnime,
  });

  @override
  State<AnimeDetailScreen> createState() => _AnimeDetailScreenState();
}

class _AnimeDetailScreenState extends State<AnimeDetailScreen>
    with SingleTickerProviderStateMixin {
  final AnimeService _service = AnimeService();

  Anime? _anime;
  bool _isLoading = true;
  String? _errorMessage;
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    _anime = widget.initialAnime;
    if (_anime != null && _anime!.playSources.isNotEmpty) {
      _isLoading = false;
      _syncTabs();
    } else {
      unawaited(_loadDetail());
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    final id = widget.animeId ?? widget.initialAnime?.id ?? 0;
    if (id <= 0) {
      setState(() {
        _isLoading = false;
        _errorMessage = '详情加载失败';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final anime = await _service.fetchDetail(id);
      if (!mounted) return;
      setState(() {
        _anime = anime;
        _isLoading = false;
      });
      _syncTabs();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '详情加载失败，请稍后重试';
      });
    }
  }

  void _syncTabs() {
    final sourceCount = _anime?.playSources.length ?? 0;
    _tabController?.dispose();
    _tabController = sourceCount > 0
        ? TabController(length: sourceCount, vsync: this)
        : null;
  }

  void _playEpisode(AnimePlaySource source, AnimeEpisode episode) {
    final anime = _anime;
    if (anime == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AnimePlayerScreen(anime: anime, source: source, episode: episode),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final anime = _anime;
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: Text(anime?.title ?? widget.title ?? '动漫详情')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? _buildError()
          : anime == null
          ? _buildError()
          : _buildDetail(anime, isNight),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 56, color: AppTheme.textHint),
          const SizedBox(height: 12),
          Text(_errorMessage ?? '详情加载失败'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _loadDetail,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetail(Anime anime, bool isNight) {
    final sources = anime.playSources;

    return NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) {
        return [
          SliverToBoxAdapter(child: _buildInfo(anime, isNight)),
          if (sources.isNotEmpty)
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabHeaderDelegate(
                color: isNight ? AppTheme.nightBackground : Colors.white,
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabs: [
                    for (final source in sources)
                      Tab(text: '${source.name} ${source.episodes.length}'),
                  ],
                ),
              ),
            ),
        ];
      },
      body: sources.isEmpty
          ? const Center(child: Text('暂无可播放剧集'))
          : TabBarView(
              controller: _tabController,
              children: [
                for (final source in sources) _buildEpisodeGrid(source),
              ],
            ),
    );
  }

  Widget _buildInfo(Anime anime, bool isNight) {
    final meta = [
      anime.status,
      anime.year,
      anime.area,
      anime.category,
    ].where((value) => value.isNotEmpty).join(' / ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 104,
                  height: 146,
                  child: AnimeCover(imageUrl: anime.coverUrl),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      anime.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isNight ? Colors.white : AppTheme.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (anime.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        anime.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isNight
                              ? AppTheme.nightText
                              : AppTheme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      meta,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.accentColor,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: anime.firstEpisode == null
                          ? null
                          : () => _playEpisode(
                              anime.playSources.firstWhere(
                                (source) => source.episodes.isNotEmpty,
                              ),
                              anime.firstEpisode!,
                            ),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('立即播放'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (anime.description.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              anime.description,
              style: TextStyle(
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
                fontSize: 13,
                height: 1.55,
              ),
            ),
          ],
          if (anime.director.isNotEmpty || anime.actors.isNotEmpty) ...[
            const SizedBox(height: 12),
            _MetaLine(label: '导演', value: anime.director),
            _MetaLine(label: '主演', value: anime.actors),
          ],
        ],
      ),
    );
  }

  Widget _buildEpisodeGrid(AnimePlaySource source) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 2.2,
      ),
      itemCount: source.episodes.length,
      itemBuilder: (context, index) {
        final episode = source.episodes[index];
        return OutlinedButton(
          onPressed: () => _playEpisode(source, episode),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: Text(
            episode.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        );
      },
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '$label：$value',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}

class _TabHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _TabHeaderDelegate({required this.child, required this.color});

  final Widget child;
  final Color color;

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(color: color, child: child);
  }

  @override
  bool shouldRebuild(covariant _TabHeaderDelegate oldDelegate) {
    return oldDelegate.child != child || oldDelegate.color != color;
  }
}
