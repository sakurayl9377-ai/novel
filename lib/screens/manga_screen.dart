import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../services/image_cache_service.dart';
import '../services/manga_service.dart';
import 'manga_detail_screen.dart';
import 'manga_more_screen.dart';

class MangaScreen extends StatefulWidget {
  const MangaScreen({super.key});

  @override
  State<MangaScreen> createState() => _MangaScreenState();
}

class _MangaScreenState extends State<MangaScreen> {
  final MangaService _service = MangaService();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoadingHome = true;
  bool _isSearching = false;
  String? _errorMessage;
  String _searchedKeyword = '';
  MangaHomeData _homeData = const MangaHomeData.empty();
  List<MangaHomeItem> _searchResults = [];

  bool get _showingSearchResults => _searchedKeyword.isNotEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHome());
  }

  @override
  void dispose() {
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '漫画首页加载失败，请稍后重试';
        _isLoadingHome = false;
      });
    }
  }

  Future<void> _search(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return;

    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _searchedKeyword = query;
      _searchResults = [];
    });

    try {
      final results = await _service.search(query);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '搜索失败，请稍后重试';
        _isSearching = false;
      });
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchedKeyword = '';
      _searchResults = [];
      _errorMessage = null;
    });
  }

  void _openItem(MangaHomeItem item) {
    if (item.id.isEmpty) {
      _searchController.text = item.title;
      unawaited(_search(item.title));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MangaDetailScreen(mangaId: item.id, title: item.title),
      ),
    );
  }

  void _openMore(String title, String url) {
    if (url.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MangaMoreScreen(title: title, url: url),
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
          hintText: '搜索漫画',
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
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        _buildCategories(isNight),
        if (_homeData.featured.isNotEmpty) _buildFeatured(isNight),
        for (final section in _homeData.sections) _buildGridSection(section),
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
        final item = _searchResults[index];
        return _MangaResultTile(
          item: item,
          isNight: isNight,
          onTap: () => _openItem(item),
        );
      },
    );
  }

  Widget _buildCategories(bool isNight) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Row(
        children: [
          for (final category in _homeData.categories)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: InkWell(
                  onTap: () => _openMore(category.title, category.url),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _categoryColor(
                              category.icon,
                            ).withValues(alpha: isNight ? 0.18 : 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            _categoryIcon(category.icon),
                            size: 21,
                            color: _categoryColor(category.icon),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          category.title.replaceAll('漫画', ''),
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
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFeatured(bool isNight) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '漫画推荐', subtitle: '包子漫画'),
        SizedBox(
          height: 206,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: _homeData.featured.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = _homeData.featured[index];
              return _FeaturedMangaCard(
                item: item,
                isNight: isNight,
                onTap: () => _openItem(item),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGridSection(MangaHomeSection section) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: section.title,
          onMore: section.hasMore
              ? () => _openMore(section.title, section.moreUrl)
              : null,
        ),
        GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 14,
            childAspectRatio: 0.6,
          ),
          itemCount: section.items.length.clamp(0, 12),
          itemBuilder: (context, index) {
            final item = section.items[index];
            return _PosterMangaCard(item: item, onTap: () => _openItem(item));
          },
        ),
      ],
    );
  }

  Color _categoryColor(String value) {
    switch (value) {
      case 'hot':
        return AppTheme.primaryColor;
      case 'new':
        return AppTheme.accentColor;
      case 'cn':
        return AppTheme.primaryColor;
      case 'jp':
        return const Color(0xFF7E57C2);
      case 'kr':
        return const Color(0xFF2E7D32);
      case 'us':
        return const Color(0xFF2E7D32);
      default:
        return const Color(0xFF00897B);
    }
  }

  IconData _categoryIcon(String value) {
    switch (value) {
      case 'hot':
        return Icons.local_fire_department_outlined;
      case 'new':
        return Icons.update_outlined;
      case 'cn':
        return Icons.flag_outlined;
      case 'jp':
        return Icons.auto_awesome_outlined;
      case 'kr':
        return Icons.favorite_border;
      case 'us':
        return Icons.public_outlined;
      default:
        return Icons.dashboard_outlined;
    }
  }
}

class _MangaResultTile extends StatelessWidget {
  const _MangaResultTile({
    required this.item,
    required this.isNight,
    required this.onTap,
  });

  final MangaHomeItem item;
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
                child: MangaCover(imageUrl: item.imageUrl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isNight ? Colors.white : AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      item.latestChapter,
                      item.status,
                      item.author,
                    ].where((value) => value.isNotEmpty).join(' / '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: 12,
                    ),
                  ),
                  if (item.description.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      item.description,
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
                  ],
                  const SizedBox(height: 8),
                  const Row(
                    children: [
                      Icon(
                        Icons.menu_book_outlined,
                        size: 16,
                        color: AppTheme.primaryColor,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '查看章节',
                        style: TextStyle(
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

class _FeaturedMangaCard extends StatelessWidget {
  const _FeaturedMangaCard({
    required this.item,
    required this.isNight,
    required this.onTap,
  });

  final MangaHomeItem item;
  final bool isNight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cardColor = isNight ? AppTheme.nightCard : AppTheme.cardColor;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 132,
        clipBehavior: Clip.antiAlias,
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
            SizedBox(
              height: 150,
              width: double.infinity,
              child: MangaCover(imageUrl: item.imageUrl),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 9, 9, 0),
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isNight ? Colors.white : AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 5, 9, 0),
              child: Text(
                item.latestChapter.isNotEmpty
                    ? item.latestChapter
                    : item.status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.accentColor,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PosterMangaCard extends StatelessWidget {
  const _PosterMangaCard({required this.item, required this.onTap});

  final MangaHomeItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

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
                  MangaCover(imageUrl: item.imageUrl),
                  if (item.latestChapter.isNotEmpty || item.status.isNotEmpty)
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
                          item.latestChapter.isNotEmpty
                              ? item.latestChapter
                              : item.status,
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

class MangaCover extends StatelessWidget {
  const MangaCover({
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
        child: Center(child: Icon(Icons.image_outlined)),
      );
    }

    return CachedNetworkImage(
      imageUrl: imageUrl,
      cacheManager: AppImageCacheService.manager,
      fit: fit,
      httpHeaders: mangaImageHeaders(),
      errorWidget: (context, url, error) => const ColoredBox(
        color: AppTheme.dividerColor,
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
      placeholder: (context, url) {
        return const ColoredBox(
          color: AppTheme.dividerColor,
          child: SizedBox.expand(),
        );
      },
    );
  }
}

Map<String, String> mangaImageHeaders({String referer = ''}) {
  return {
    'Referer': referer.isEmpty ? 'https://cn.bzmgcn.com/' : referer,
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
