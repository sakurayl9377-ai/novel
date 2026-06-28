import 'dart:async';

import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../services/manga_service.dart';
import 'manga_detail_screen.dart';
import 'manga_screen.dart';

class MangaMoreScreen extends StatefulWidget {
  const MangaMoreScreen({super.key, required this.title, required this.url});

  final String title;
  final String url;

  @override
  State<MangaMoreScreen> createState() => _MangaMoreScreenState();
}

class _MangaMoreScreenState extends State<MangaMoreScreen> {
  final MangaService _service = MangaService();
  final ScrollController _scrollController = ScrollController();
  final List<MangaHomeItem> _items = [];

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _errorMessage;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    unawaited(_loadFirstPage());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients ||
        _isLoading ||
        _isLoadingMore ||
        !_hasMore) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 360) {
      unawaited(_loadNextPage());
    }
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _isLoading = true;
      _isLoadingMore = false;
      _errorMessage = null;
      _page = 1;
      _hasMore = true;
      _items.clear();
    });

    try {
      final result = await _service.fetchList(widget.url, page: 1);
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _page = result.page;
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '加载失败，请稍后重试';
      });
    }
  }

  Future<void> _loadNextPage() async {
    setState(() => _isLoadingMore = true);
    try {
      final result = await _service.fetchList(widget.url, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _appendUnique(result.items);
        _page = result.page;
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingMore = false;
        _hasMore = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加载更多失败')));
    }
  }

  void _appendUnique(List<MangaHomeItem> items) {
    final seenSet = _items
        .map((item) => item.id.isNotEmpty ? 'id:${item.id}' : item.url)
        .toSet();
    for (final item in items) {
      final key = item.id.isNotEmpty ? 'id:${item.id}' : item.url;
      if (seenSet.add(key)) _items.add(item);
    }
  }

  void _openItem(MangaHomeItem item) {
    if (item.id.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MangaDetailScreen(mangaId: item.id, title: item.title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: RefreshIndicator(
        onRefresh: _loadFirstPage,
        child: _buildBody(isNight),
      ),
    );
  }

  Widget _buildBody(bool isNight) {
    if (_isLoading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && _items.isEmpty) {
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
              _errorMessage!,
              style: TextStyle(
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: OutlinedButton.icon(
              onPressed: _loadFirstPage,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
        ],
      );
    }

    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.24),
          Icon(
            Icons.image_outlined,
            size: 60,
            color: isNight ? AppTheme.nightText : AppTheme.textHint,
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '暂无内容',
              style: TextStyle(
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      );
    }

    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 14,
              childAspectRatio: 0.6,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final item = _items[index];
              return _MoreMangaCard(
                item: item,
                isNight: isNight,
                onTap: () => _openItem(item),
              );
            }, childCount: _items.length),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Center(child: _buildFooter(isNight)),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(bool isNight) {
    if (_isLoadingMore) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (!_hasMore) {
      return Text(
        '已加载全部',
        style: TextStyle(
          color: isNight ? AppTheme.nightText : AppTheme.textHint,
          fontSize: 12,
        ),
      );
    }
    return TextButton.icon(
      onPressed: _loadNextPage,
      icon: const Icon(Icons.keyboard_arrow_down),
      label: const Text('继续加载'),
    );
  }
}

class _MoreMangaCard extends StatelessWidget {
  const _MoreMangaCard({
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
