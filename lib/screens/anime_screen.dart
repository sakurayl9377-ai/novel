import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../config/theme.dart';
import '../models/anime.dart';
import '../services/anime_service.dart';
import '../services/bounded_task_scheduler.dart';
import '../services/image_cache_service.dart';
import 'anime_detail_screen.dart';
import 'anime_more_screen.dart';

class AnimeScreen extends StatefulWidget {
  const AnimeScreen({super.key});

  @override
  State<AnimeScreen> createState() => _AnimeScreenState();
}

class _AnimeScreenState extends State<AnimeScreen> {
  final AnimeService _service = AnimeService();
  final TextEditingController _searchController = TextEditingController();
  final BoundedTaskScheduler _imagePrefetchScheduler = BoundedTaskScheduler(
    maxConcurrent: 3,
  );
  final PageController _featuredPageController = PageController();
  final PageController _rankingPageController = PageController(
    viewportFraction: 0.9,
  );

  bool _isLoadingHome = true;
  bool _isSearching = false;
  String? _errorMessage;
  String _searchedKeyword = '';
  int _featuredPageIndex = 0;
  AnimeHomeData _homeData = const AnimeHomeData.empty();
  List<Anime> _searchResults = [];
  int _searchGeneration = 0;

  bool get _showingSearchResults => _searchedKeyword.isNotEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHome());
  }

  @override
  void dispose() {
    _searchGeneration++;
    _featuredPageController.dispose();
    _rankingPageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHome({bool forceRefresh = false}) async {
    setState(() {
      _isLoadingHome = true;
      _errorMessage = null;
    });

    try {
      final data = await _service.fetchHome(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _homeData = data;
        _isLoadingHome = false;
      });
      _precacheHomeImages(data);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '首页加载失败，请稍后重试';
        _isLoadingHome = false;
      });
    }
  }

  Future<void> _search(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return;
    final searchGeneration = ++_searchGeneration;

    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _searchedKeyword = query;
      _searchResults = [];
    });

    try {
      final results = await _service.search(query);
      if (!mounted || searchGeneration != _searchGeneration) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
      _precacheAnimeImages(results);
    } catch (_) {
      if (!mounted || searchGeneration != _searchGeneration) return;
      setState(() {
        _errorMessage = '搜索失败，请稍后重试';
        _isSearching = false;
      });
    }
  }

  void _clearSearch() {
    _searchGeneration++;
    _searchController.clear();
    setState(() {
      _searchedKeyword = '';
      _searchResults = [];
      _errorMessage = null;
    });
  }

  void _precacheHomeImages(AnimeHomeData data) {
    final urls = <String>{
      for (final item in data.featured) item.imageUrl,
      for (final group in data.rankings)
        for (final item in group.items) item.imageUrl,
      for (final section in data.sections.take(4))
        for (final item in section.items.take(6)) item.imageUrl,
    };
    _precacheImageUrls(urls);
  }

  void _precacheAnimeImages(List<Anime> items) {
    _precacheImageUrls(items.map((item) => item.coverUrl));
  }

  void _precacheImageUrls(Iterable<String> urls) {
    final uniqueUrls = urls.where((url) => url.isNotEmpty).take(32).toList();
    if (uniqueUrls.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (var index = 0; index < uniqueUrls.length; index++) {
        final url = uniqueUrls[index];
        unawaited(
          _imagePrefetchScheduler
              .schedule(() {
                if (!mounted) return Future<void>.value();
                return precacheImage(
                  CachedNetworkImageProvider(
                    url,
                    cacheManager: AppImageCacheService.manager,
                    headers: animeImageHeaders(url),
                  ),
                  context,
                );
              }, priority: uniqueUrls.length - index)
              .catchError((_) {}),
        );
      }
    });
  }

  void _openHomeItem(AnimeHomeItem item) {
    if (item.id <= 0) {
      _searchController.text = item.title;
      unawaited(_search(item.title));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimeDetailScreen(animeId: item.id, title: item.title),
      ),
    );
  }

  void _openAnime(Anime anime) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AnimeDetailScreen(initialAnime: anime)),
    );
  }

  void _openMore(AnimeHomeSection section) {
    if (!section.hasMore) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AnimeMoreScreen(title: section.title, url: section.moreUrl),
      ),
    );
  }

  void _openMoreList(String title, String url) {
    if (url.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimeMoreScreen(title: title, url: url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: _buildSearchField(isNight),
        actions: [
          if (_showingSearchResults)
            IconButton(
              tooltip: '返回首页',
              onPressed: _clearSearch,
              icon: const Icon(Icons.home_outlined),
            )
          else
            IconButton(
              tooltip: '刷新',
              onPressed: _isLoadingHome
                  ? null
                  : () => _loadHome(forceRefresh: true),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _showingSearchResults
            ? () => _search(_searchedKeyword)
            : () => _loadHome(forceRefresh: true),
        child: _showingSearchResults
            ? _buildSearchBody(isNight)
            : _buildHomeBody(isNight),
      ),
    );
  }

  Widget _buildSearchField(bool isNight) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: isNight ? const Color(0xFF242424) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isNight ? const Color(0xFF3A3A3A) : AppTheme.dividerColor,
        ),
      ),
      child: TextField(
        controller: _searchController,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
          fontSize: 14,
          color: isNight ? Colors.white : AppTheme.textPrimary,
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: _search,
        decoration: InputDecoration(
          hintText: '搜索动漫',
          hintStyle: TextStyle(
            fontSize: 14,
            color: isNight ? AppTheme.nightText : AppTheme.textHint,
          ),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: IconButton(
            tooltip: '搜索',
            onPressed: () => _search(_searchController.text),
            icon: const Icon(Icons.arrow_forward, size: 18),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 38,
            minHeight: 36,
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
      ),
    );
  }

  Widget _buildHomeBody(bool isNight) {
    if (_isLoadingHome && _homeData.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && _homeData.isEmpty) {
      return _ErrorState(message: _errorMessage!, onRetry: _loadHome);
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      scrollCacheExtent: const ScrollCacheExtent.pixels(900),
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        if (_homeData.featured.isNotEmpty) _buildFeatured(isNight),
        if (_homeData.hotSearches.isNotEmpty) _buildHotSearches(),
        if (_homeData.rankings.isNotEmpty) _buildRankingSection(isNight),
        for (final section in _homeData.sections)
          _buildPosterSection(section, isNight),
      ],
    );
  }

  Widget _buildSearchBody(bool isNight) {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return _ErrorState(
        message: _errorMessage!,
        onRetry: () => _search(_searchedKeyword),
      );
    }

    if (_searchResults.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.22),
          Icon(
            Icons.search_off,
            size: 64,
            color: isNight ? AppTheme.nightText : AppTheme.textHint,
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              '没有找到“$_searchedKeyword”',
              style: TextStyle(
                fontSize: 15,
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _searchResults.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final anime = _searchResults[index];
        return _AnimeResultTile(
          anime: anime,
          isNight: isNight,
          onTap: () => _openAnime(anime),
        );
      },
    );
  }

  Widget _buildFeatured(bool isNight) {
    final items = _homeData.featured;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '樱花推荐', subtitle: 'Yinhuadm'),
        SizedBox(
          height: 276,
          child: Stack(
            children: [
              PageView.builder(
                controller: _featuredPageController,
                allowImplicitScrolling: true,
                itemCount: items.length,
                onPageChanged: (index) {
                  setState(() => _featuredPageIndex = index);
                },
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _FeaturedAnimeCard(
                      item: item,
                      isNight: isNight,
                      onTap: () => _openHomeItem(item),
                    ),
                  );
                },
              ),
              if (items.length > 1) ...[
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: _FeaturedArrowButton(
                    icon: Icons.chevron_left_rounded,
                    onTap: _previousFeatured,
                  ),
                ),
                Positioned(
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: _FeaturedArrowButton(
                    icon: Icons.chevron_right_rounded,
                    onTap: _nextFeatured,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: IgnorePointer(
                    child: _CarouselDots(
                      count: items.length,
                      activeIndex: _featuredPageIndex.clamp(
                        0,
                        items.length - 1,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _previousFeatured() {
    final itemCount = _homeData.featured.length;
    if (itemCount <= 1) return;
    final next = (_featuredPageIndex - 1 + itemCount) % itemCount;
    _featuredPageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _nextFeatured() {
    final itemCount = _homeData.featured.length;
    if (itemCount <= 1) return;
    final next = (_featuredPageIndex + 1) % itemCount;
    _featuredPageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildHotSearches() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in _homeData.hotSearches)
            ActionChip(
              avatar: const Icon(Icons.local_fire_department, size: 16),
              label: Text(item.title, maxLines: 1),
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _searchController.text = item.title;
                unawaited(_search(item.title));
              },
            ),
        ],
      ),
    );
  }

  Widget _buildPosterSection(AnimeHomeSection section, bool isNight) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: section.title,
          onMore: section.hasMore ? () => _openMore(section) : null,
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = _posterGridColumns(constraints.maxWidth);
            return GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 10,
                mainAxisSpacing: 14,
                childAspectRatio: 0.6,
              ),
              itemCount: section.items.length.clamp(0, columns * 4),
              itemBuilder: (context, index) {
                final item = section.items[index];
                return _PosterAnimeCard(
                  item: item,
                  isNight: isNight,
                  onTap: () => _openHomeItem(item),
                );
              },
            );
          },
        ),
      ],
    );
  }

  int _posterGridColumns(double width) {
    final usableWidth = (width - 32).clamp(0, double.infinity);
    return (usableWidth / 132).floor().clamp(3, 6).toInt();
  }

  Widget _buildRankingSection(bool isNight) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '热榜',
          onMore: _homeData.rankingsMoreUrl.isEmpty
              ? null
              : () => _openMoreList('热榜', _homeData.rankingsMoreUrl),
        ),
        SizedBox(
          height: 282,
          child: PageView.builder(
            controller: _rankingPageController,
            padEnds: false,
            allowImplicitScrolling: true,
            itemCount: _homeData.rankings.length,
            itemBuilder: (context, index) {
              return Padding(
                padding: EdgeInsets.only(
                  left: index == 0 ? 16 : 6,
                  right: index == _homeData.rankings.length - 1 ? 16 : 6,
                ),
                child: _RankingGroup(
                  group: _homeData.rankings[index],
                  isNight: isNight,
                  onTap: _openHomeItem,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AnimeResultTile extends StatelessWidget {
  const _AnimeResultTile({
    required this.anime,
    required this.isNight,
    required this.onTap,
  });

  final Anime anime;
  final bool isNight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 72,
                height: 102,
                child: AnimeCover(imageUrl: anime.coverUrl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    anime.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isNight ? Colors.white : AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    [
                      anime.status,
                      anime.year,
                      anime.area,
                    ].where((value) => value.isNotEmpty).join(' / '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    anime.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isNight
                          ? AppTheme.nightText
                          : AppTheme.textSecondary,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        anime.hasPlayableEpisode
                            ? Icons.play_circle_outline
                            : Icons.info_outline,
                        size: 16,
                        color: AppTheme.primaryColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        anime.hasPlayableEpisode ? '可播放' : '查看详情',
                        style: const TextStyle(
                          color: AppTheme.primaryColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeaturedAnimeCard extends StatelessWidget {
  const _FeaturedAnimeCard({
    required this.item,
    required this.isNight,
    required this.onTap,
  });

  final AnimeHomeItem item;
  final bool isNight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = isNight
        ? const Color(0xFF3A3A3A)
        : AppTheme.dividerColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isNight ? AppTheme.nightCard : const Color(0xFFE9EDF4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimeCover(imageUrl: item.imageUrl, fit: BoxFit.cover),
            ColoredBox(
              color: Colors.black.withValues(alpha: isNight ? 0.48 : 0.36),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.black.withValues(alpha: 0.06),
                    Colors.black.withValues(alpha: 0.12),
                    Colors.black.withValues(alpha: 0.32),
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.62),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cardWidth = constraints.maxWidth;
                  final cardHeight = constraints.maxHeight;
                  final leftInset = (cardWidth * 0.12)
                      .clamp(36.0, 44.0)
                      .toDouble();
                  final rightInset = (cardWidth * 0.055)
                      .clamp(16.0, 22.0)
                      .toDouble();
                  final contentGap = (cardWidth * 0.045)
                      .clamp(13.0, 18.0)
                      .toDouble();
                  final preferredCoverWidth = (cardWidth * 0.47)
                      .clamp(126.0, 164.0)
                      .toDouble();
                  final maxCoverWidth =
                      cardWidth - leftInset - rightInset - contentGap - 88;
                  final coverWidth = preferredCoverWidth > maxCoverWidth
                      ? maxCoverWidth
                      : preferredCoverWidth;
                  final coverHeight = (coverWidth / 0.69)
                      .clamp(0.0, cardHeight - 42)
                      .toDouble();
                  final coverTop = ((cardHeight - 24 - coverHeight) / 2)
                      .clamp(10.0, 28.0)
                      .toDouble();
                  final textLeft = leftInset + coverWidth + contentGap;
                  final textWidth = cardWidth - textLeft - rightInset;
                  final titleFontSize = textWidth < 100 ? 18.0 : 20.0;

                  return Stack(
                    children: [
                      Positioned(
                        left: leftInset,
                        top: coverTop,
                        width: coverWidth,
                        height: coverHeight,
                        child: Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: isNight ? 0.08 : 0.28,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.36),
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x66000000),
                                blurRadius: 24,
                                spreadRadius: 2,
                                offset: Offset(0, 14),
                              ),
                              BoxShadow(
                                color: Color(0x33000000),
                                blurRadius: 6,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              AnimeCover(imageUrl: item.imageUrl),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Colors.white.withValues(alpha: 0.22),
                                      Colors.transparent,
                                      Colors.black.withValues(alpha: 0.08),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: textLeft,
                        right: rightInset,
                        top: 28,
                        bottom: 34,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              item.title,
                              maxLines: 3,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: titleFontSize,
                                height: 1.08,
                                fontWeight: FontWeight.w800,
                                shadows: const [
                                  Shadow(
                                    color: Color(0xAA000000),
                                    blurRadius: 8,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (item.status.isNotEmpty)
                              Text(
                                item.status,
                                maxLines: 1,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  height: 1,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            if (item.description.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                item.description,
                                maxLines: 4,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xE8FFFFFF),
                                  fontSize: 12,
                                  height: 1.28,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeaturedArrowButton extends StatelessWidget {
  const _FeaturedArrowButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isLeft = icon == Icons.chevron_left_rounded;
    return SizedBox(
      width: 42,
      child: Material(
        color: Colors.black.withValues(alpha: 0.12),
        child: InkWell(
          onTap: onTap,
          child: Align(
            alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              width: 28,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.28),
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(isLeft ? 0 : 999),
                  right: Radius.circular(isLeft ? 999 : 0),
                ),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
          ),
        ),
      ),
    );
  }
}

class _CarouselDots extends StatelessWidget {
  const _CarouselDots({required this.count, required this.activeIndex});

  final int count;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    final visibleCount = count.clamp(0, 8);
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < visibleCount; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: i == activeIndex ? 18 : 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: i == activeIndex
                    ? AppTheme.primaryColor
                    : AppTheme.dividerColor,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
        ],
      ),
    );
  }
}

class _PosterAnimeCard extends StatelessWidget {
  const _PosterAnimeCard({
    required this.item,
    required this.isNight,
    required this.onTap,
  });

  final AnimeHomeItem item;
  final bool isNight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimeCover(imageUrl: item.imageUrl),
                  if (item.status.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        color: Colors.black.withValues(alpha: 0.58),
                        child: Text(
                          item.status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 20,
            child: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isNight ? Colors.white : AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RankingGroup extends StatelessWidget {
  const _RankingGroup({
    required this.group,
    required this.isNight,
    required this.onTap,
  });

  final AnimeRankingGroup group;
  final bool isNight;
  final void Function(AnimeHomeItem item) onTap;

  @override
  Widget build(BuildContext context) {
    final cardColor = isNight ? AppTheme.nightCard : AppTheme.cardColor;

    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isNight ? const Color(0xFF3A3A3A) : AppTheme.dividerColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(
              group.title,
              style: TextStyle(
                color: isNight ? Colors.white : AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (var i = 0; i < group.items.length.clamp(0, 5); i++)
            _RankingItemRow(
              item: group.items[i],
              index: i,
              isNight: isNight,
              onTap: () => onTap(group.items[i]),
            ),
        ],
      ),
    );
  }
}

class _RankingItemRow extends StatelessWidget {
  const _RankingItemRow({
    required this.item,
    required this.index,
    required this.isNight,
    required this.onTap,
  });

  final AnimeHomeItem item;
  final int index;
  final bool isNight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 45,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _RankBadge(index: index),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isNight ? Colors.white : AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (item.status.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isNight
                              ? AppTheme.nightText
                              : AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = [
      AppTheme.accentColor,
      AppTheme.primaryColor,
      const Color(0xFF4CAF50),
    ];
    final color = index < colors.length ? colors[index] : AppTheme.textHint;

    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${index + 1}',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class AnimeCover extends StatelessWidget {
  const AnimeCover({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
  });

  final String imageUrl;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (imageUrl.isEmpty) {
      return const ColoredBox(
        color: AppTheme.dividerColor,
        child: Center(child: Icon(Icons.movie_outlined)),
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      cacheManager: AppImageCacheService.manager,
      fit: fit,
      httpHeaders: animeImageHeaders(imageUrl),
      errorWidget: (context, url, error) {
        final fallbackUrl = _fallbackImageUrl(imageUrl);
        if (fallbackUrl != null) {
          return CachedNetworkImage(
            imageUrl: fallbackUrl,
            cacheManager: AppImageCacheService.manager,
            fit: fit,
            httpHeaders: animeImageHeaders(fallbackUrl),
            errorWidget: (context, url, error) => const ColoredBox(
              color: AppTheme.dividerColor,
              child: Center(child: Icon(Icons.broken_image_outlined)),
            ),
            placeholder: (context, url) => const ColoredBox(
              color: AppTheme.dividerColor,
              child: SizedBox.expand(),
            ),
          );
        }
        return const ColoredBox(
          color: AppTheme.dividerColor,
          child: Center(child: Icon(Icons.broken_image_outlined)),
        );
      },
      placeholder: (context, url) {
        return const ColoredBox(
          color: AppTheme.dividerColor,
          child: SizedBox.expand(),
        );
      },
    );
  }

  String? _fallbackImageUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final path = uri.path.replaceFirst(RegExp(r'^/+'), '');
    final cdnPath = path.replaceFirst(RegExp(r'^upload/vod/'), '');
    if (cdnPath == path && !path.startsWith('upload/')) return null;
    return 'https://img-dm.l-il.cn/$cdnPath';
  }
}

Map<String, String> animeImageHeaders(String imageUrl) {
  final uri = Uri.tryParse(imageUrl);
  final origin = uri == null || uri.host.isEmpty
      ? ''
      : '${uri.scheme}://${uri.host}/';
  return {
    'Referer': origin.isNotEmpty ? origin : 'https://www.yinhuadm.xyz/',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
  };
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle, this.onMore});

  final String title;
  final String? subtitle;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isNight ? Colors.white : AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: isNight ? AppTheme.nightText : AppTheme.textHint,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onMore != null)
            Tooltip(
              message: '查看全部',
              child: InkWell(
                onTap: onMore,
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (isNight ? Colors.white : AppTheme.primaryColor)
                        .withValues(alpha: isNight ? 0.08 : 0.1),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 15,
                    color: isNight
                        ? AppTheme.primaryLight
                        : AppTheme.primaryColor,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.22),
        Icon(
          Icons.cloud_off_outlined,
          size: 64,
          color: isNight ? AppTheme.nightText : AppTheme.textHint,
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            message,
            style: TextStyle(
              fontSize: 15,
              color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      ],
    );
  }
}
