import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../models/novel.dart';
import '../providers/book_source_provider.dart';
import '../providers/bookshelf_provider.dart';
import '../services/book_source_service.dart';
import '../widgets/book_cover_widget.dart';
import 'book_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.autofocus = true});

  final bool autofocus;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final BookSourceService _service = BookSourceService();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoadingHome = true;
  bool _isSearching = false;
  String? _errorMessage;
  String _searchedKeyword = '';
  NovelHomeData _homeData = const NovelHomeData.empty();
  List<Novel> _results = [];

  bool get _showingSearchResults => _searchedKeyword.isNotEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHome());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<BookSourceProvider>().loadSources());
    });
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
        _errorMessage = '小说首页加载失败，请稍后重试';
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
      _results = [];
    });

    try {
      await context.read<BookSourceProvider>().searchBooks(query);
      if (!mounted) return;
      setState(() {
        _results = context.read<BookSourceProvider>().searchResults;
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
      _results = [];
      _errorMessage = null;
    });
  }

  void _openNovel(Novel novel) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailScreen(novel: novel)),
    );
  }

  void _openCategory(NovelCategory category) {
    if (category.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NovelCategoryScreen(category: category),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
        autofocus: widget.autofocus,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
          fontSize: 14,
          color: isNight ? Colors.white : AppTheme.textPrimary,
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: _search,
        decoration: InputDecoration(
          hintText: '搜索小说',
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

    if (_homeData.isEmpty) {
      return _EmptyHomeState(onRetry: () => _loadHome(forceRefresh: true));
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

    if (_results.isEmpty) {
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

    return _NovelList(
      novels: _results,
      onTap: _openNovel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
  }

  Widget _buildCategories(bool isNight) {
    if (_homeData.categories.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Row(
        children: [
          for (final category in _homeData.categories.take(5))
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: InkWell(
                  onTap: () => _openCategory(category),
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
                          category.title,
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
        _SectionHeader(
          title: '笔趣阁推荐',
          subtitle: _homeData.sourceName.isEmpty ? null : _homeData.sourceName,
        ),
        SizedBox(
          height: 216,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: _homeData.featured.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final novel = _homeData.featured[index];
              return _FeaturedNovelCard(
                novel: novel,
                isNight: isNight,
                onTap: () => _openNovel(novel),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGridSection(NovelHomeSection section) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: section.title,
          onMore: section.hasMore
              ? () => _openCategory(section.category)
              : null,
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
                childAspectRatio: 0.62,
              ),
              itemCount: section.items.length.clamp(0, columns * 4),
              itemBuilder: (context, index) {
                final novel = section.items[index];
                return _PosterNovelCard(
                  novel: novel,
                  onTap: () => _openNovel(novel),
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
}

class NovelCategoryScreen extends StatefulWidget {
  const NovelCategoryScreen({super.key, required this.category});

  final NovelCategory category;

  @override
  State<NovelCategoryScreen> createState() => _NovelCategoryScreenState();
}

class _NovelCategoryScreenState extends State<NovelCategoryScreen> {
  final BookSourceService _service = BookSourceService();
  late Future<List<Novel>> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.fetchCategory(widget.category);
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _service.fetchCategory(widget.category);
    });
    await _future;
  }

  void _openNovel(Novel novel) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailScreen(novel: novel)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: Text(widget.category.title)),
      body: FutureBuilder<List<Novel>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorState(message: '列表加载失败，请稍后重试', onRetry: _refresh);
          }
          final novels = snapshot.data ?? const [];
          if (novels.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(height: MediaQuery.of(context).size.height * 0.22),
                Icon(
                  Icons.menu_book_outlined,
                  size: 64,
                  color: isNight ? AppTheme.nightText : AppTheme.textHint,
                ),
                const SizedBox(height: 14),
                Center(
                  child: Text(
                    '暂无小说',
                    style: TextStyle(
                      fontSize: 15,
                      color: isNight
                          ? AppTheme.nightText
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: _NovelList(
              novels: novels,
              onTap: _openNovel,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          );
        },
      ),
    );
  }
}

class _NovelList extends StatelessWidget {
  const _NovelList({
    required this.novels,
    required this.onTap,
    required this.padding,
  });

  final List<Novel> novels;
  final void Function(Novel novel) onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: padding,
      itemCount: novels.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final novel = novels[index];
        return _NovelResultTile(novel: novel, onTap: () => onTap(novel));
      },
    );
  }
}

class _NovelResultTile extends StatelessWidget {
  const _NovelResultTile({required this.novel, required this.onTap});

  final Novel novel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bookshelfProvider = context.watch<BookshelfProvider>();
    final onShelf = bookshelfProvider.isOnShelf(novel.id);
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            BookCoverWidget(novel: novel, width: 64, height: 90),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    novel.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isNight ? Colors.white : AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    novel.author.isNotEmpty ? novel.author : '未知作者',
                    style: TextStyle(
                      fontSize: 13,
                      color: isNight
                          ? AppTheme.nightText
                          : AppTheme.textSecondary,
                    ),
                  ),
                  if (novel.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      novel.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: isNight
                            ? AppTheme.nightText
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.accentColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          novel.status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.accentColor,
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (!onShelf)
                        TextButton(
                          onPressed: () async {
                            await bookshelfProvider.addToBookshelf(novel);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已加入书架')),
                            );
                          },
                          child: const Text(
                            '加入书架',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.primaryColor,
                            ),
                          ),
                        )
                      else
                        const Icon(
                          Icons.check_circle,
                          size: 18,
                          color: Colors.green,
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

class _FeaturedNovelCard extends StatelessWidget {
  const _FeaturedNovelCard({
    required this.novel,
    required this.isNight,
    required this.onTap,
  });

  final Novel novel;
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
              height: 144,
              width: double.infinity,
              child: BookCoverWidget(novel: novel, width: 132, height: 144),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 9, 9, 0),
              child: Text(
                novel.title,
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
                novel.author.isNotEmpty ? novel.author : novel.status,
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

class _PosterNovelCard extends StatelessWidget {
  const _PosterNovelCard({required this.novel, required this.onTap});

  final Novel novel;
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
          Expanded(child: BookCoverWidget.fill(novel: novel)),
          const SizedBox(height: 6),
          SizedBox(
            height: 20,
            child: Text(
              novel.title,
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
          if (novel.author.isNotEmpty)
            SizedBox(
              height: 18,
              child: Text(
                novel.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isNight ? AppTheme.nightText : AppTheme.textHint,
                  fontSize: 11,
                  height: 1.2,
                ),
              ),
            ),
        ],
      ),
    );
  }
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

class _EmptyHomeState extends StatelessWidget {
  const _EmptyHomeState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.22),
        Icon(
          Icons.menu_book_outlined,
          size: 64,
          color: isNight ? AppTheme.nightText : AppTheme.textHint,
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            '暂无小说推荐',
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
            label: const Text('刷新'),
          ),
        ),
      ],
    );
  }
}

Color _categoryColor(String value) {
  switch (value) {
    case 'hot':
      return AppTheme.accentColor;
    case 'magic':
      return AppTheme.primaryColor;
    case 'sword':
      return const Color(0xFF7E57C2);
    case 'city':
      return const Color(0xFF00897B);
    case 'history':
      return const Color(0xFF6D4C41);
    case 'game':
      return const Color(0xFF3949AB);
    case 'science':
      return const Color(0xFF2E7D32);
    case 'female':
      return const Color(0xFFD81B60);
    case 'done':
      return const Color(0xFF455A64);
    default:
      return AppTheme.primaryColor;
  }
}

IconData _categoryIcon(String value) {
  switch (value) {
    case 'hot':
      return Icons.local_fire_department_outlined;
    case 'magic':
      return Icons.auto_awesome_outlined;
    case 'sword':
      return Icons.gesture_outlined;
    case 'city':
      return Icons.location_city_outlined;
    case 'history':
      return Icons.account_balance_outlined;
    case 'game':
      return Icons.sports_esports_outlined;
    case 'science':
      return Icons.public_outlined;
    case 'female':
      return Icons.favorite_border;
    case 'done':
      return Icons.done_all_outlined;
    default:
      return Icons.menu_book_outlined;
  }
}
