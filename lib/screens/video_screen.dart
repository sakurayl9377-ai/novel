import 'dart:async';

import 'package:flutter/material.dart';

import '../models/wuhandky_video.dart';
import '../services/wuhandky_service.dart';
import '../widgets/wuhandky_cover_image.dart';
import 'video_detail_screen.dart';

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, this.service});

  final WuhandkyService? service;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen>
    with AutomaticKeepAliveClientMixin {
  static const _categories = <(String, String)>[
    ('推荐', '/new.html'),
    ('电影', '/dianying/'),
    ('电视剧', '/dianshiju/'),
    ('动漫', '/dongman/'),
    ('综艺', '/zongyi/'),
  ];

  late final WuhandkyService _service;
  final TextEditingController _searchController = TextEditingController();
  List<WuhandkyVideoItem> _items = const [];
  WuhandkyVideoHome? _home;
  int _categoryIndex = 0;
  bool _loading = true;
  bool _searching = false;
  String _error = '';
  int _requestGeneration = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? WuhandkyService();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!mounted) return;
    final requestGeneration = ++_requestGeneration;
    final categoryPath = _categories[_categoryIndex].$2;
    setState(() {
      _loading = true;
      _searching = false;
      _error = '';
      if (refresh) _items = const [];
    });
    try {
      final home = _categoryIndex == 0 ? await _service.fetchHome() : null;
      final items =
          home?.featured ?? await _service.fetchCategory(categoryPath);
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() {
        _home = home ?? _home;
        _items = items;
      });
    } catch (error) {
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted && requestGeneration == _requestGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _search(String value) async {
    final query = value.trim();
    if (query.isEmpty) {
      await _load();
      return;
    }
    final requestGeneration = ++_requestGeneration;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _searching = true;
      _error = '';
      _items = const [];
    });
    try {
      final items = await _service.search(query);
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() => _items = items);
    } catch (error) {
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted && requestGeneration == _requestGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void _selectCategory(int index) {
    if (index == _categoryIndex && !_searching) return;
    _searchController.clear();
    setState(() => _categoryIndex = index);
    unawaited(_load(refresh: true));
  }

  void _open(WuhandkyVideoItem item) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => VideoDetailScreen(item: item)),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('影视'),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(108),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: SearchBar(
                  controller: _searchController,
                  hintText: '搜索电影、电视剧、动漫或综艺',
                  leading: const Icon(Icons.search_rounded),
                  trailing: [
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        onPressed: () {
                          _searchController.clear();
                          unawaited(_load(refresh: true));
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                  ],
                  onChanged: (_) => setState(() {}),
                  onSubmitted: _search,
                ),
              ),
              SizedBox(
                height: 46,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: _categories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => ChoiceChip(
                    label: Text(_categories[index].$1),
                    selected: !_searching && _categoryIndex == index,
                    onSelected: (_) => _selectCategory(index),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            _searching ? _search(_searchController.text) : _load(refresh: true),
        child: _loading && _items.isEmpty
            ? const _ScrollableStatus(child: CircularProgressIndicator())
            : _error.isNotEmpty && _items.isEmpty
            ? _ScrollableStatus(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 52,
                      color: colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(_error, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _load,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
            : _items.isEmpty
            ? const _ScrollableStatus(child: Text('没有找到相关影视'))
            : !_searching && _categoryIndex == 0 && _home != null
            ? _VideoHomeView(
                home: _home!,
                onOpen: _open,
                onSelectCategory: (path) {
                  final index = _categories.indexWhere(
                    (item) => item.$2 == path,
                  );
                  if (index >= 0) _selectCategory(index);
                },
                resolveCover: (item) => _service.resolveCoverUrl(
                  title: item.title,
                  itemKey: item.detailUrl,
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.53,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 14,
                ),
                itemCount: _items.length,
                itemBuilder: (context, index) => _VideoCard(
                  item: _items[index],
                  onTap: () => _open(_items[index]),
                  resolveCover: () => _service.resolveCoverUrl(
                    title: _items[index].title,
                    itemKey: _items[index].detailUrl,
                  ),
                ),
              ),
      ),
    );
  }

  String _friendlyError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    final lower = text.toLowerCase();
    if (lower.contains('handshake') ||
        lower.contains('certificate') ||
        lower.contains('tls')) {
      return '影视源连接异常，已尝试兼容线路，请切换网络后重试';
    }
    return text.isEmpty ? '影视源暂时不可用，请稍后重试' : text;
  }
}

class _VideoHomeView extends StatelessWidget {
  const _VideoHomeView({
    required this.home,
    required this.onOpen,
    required this.onSelectCategory,
    required this.resolveCover,
  });

  final WuhandkyVideoHome home;
  final ValueChanged<WuhandkyVideoItem> onOpen;
  final ValueChanged<String> onSelectCategory;
  final Future<String?> Function(WuhandkyVideoItem item) resolveCover;

  @override
  Widget build(BuildContext context) {
    final featured = home.featured.first;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          sliver: SliverToBoxAdapter(
            child: _VideoFeaturedCard(
              item: featured,
              onTap: () => onOpen(featured),
              resolveCover: () => resolveCover(featured),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 72,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              scrollDirection: Axis.horizontal,
              itemCount: home.sections.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final section = home.sections[index];
                const icons = [
                  Icons.movie_creation_outlined,
                  Icons.live_tv_outlined,
                  Icons.animation_outlined,
                  Icons.mic_external_on_outlined,
                ];
                return ActionChip(
                  avatar: Icon(icons[index % icons.length], size: 20),
                  label: Text(section.title),
                  onPressed: () => onSelectCategory(section.path),
                );
              },
            ),
          ),
        ),
        for (final section in home.sections) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      section.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => onSelectCategory(section.path),
                    child: const Text('更多'),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 238,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: section.items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final item = section.items[index];
                  return SizedBox(
                    width: 126,
                    child: _VideoCard(
                      item: item,
                      onTap: () => onOpen(item),
                      resolveCover: () => resolveCover(item),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 30)),
      ],
    );
  }
}

class _VideoFeaturedCard extends StatelessWidget {
  const _VideoFeaturedCard({
    required this.item,
    required this.onTap,
    required this.resolveCover,
  });

  final WuhandkyVideoItem item;
  final VoidCallback onTap;
  final Future<String?> Function() resolveCover;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 190,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _VideoPoster(
                url: item.coverUrl,
                title: item.title,
                resolveCover: resolveCover,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xE6000000)],
                  ),
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('今日推荐', style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 4),
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({
    required this.item,
    required this.onTap,
    required this.resolveCover,
  });

  final WuhandkyVideoItem item;
  final VoidCallback onTap;
  final Future<String?> Function() resolveCover;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _VideoPoster(
                    url: item.coverUrl,
                    title: item.title,
                    resolveCover: resolveCover,
                  ),
                  if (item.note.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 5,
                        ),
                        color: Colors.black54,
                        child: Text(
                          item.note,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  if (item.score.isNotEmpty)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.orange.shade700,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Text(
                            item.score,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 22,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoPoster extends StatelessWidget {
  const _VideoPoster({
    required this.url,
    required this.title,
    required this.resolveCover,
  });

  final String url;
  final String title;
  final Future<String?> Function() resolveCover;

  @override
  Widget build(BuildContext context) {
    return WuhandkyCoverImage(
      imageUrl: url,
      title: title,
      resolveFallback: resolveCover,
    );
  }
}

class _ScrollableStatus extends StatelessWidget {
  const _ScrollableStatus({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: constraints.maxHeight,
          child: Center(
            child: Padding(padding: const EdgeInsets.all(28), child: child),
          ),
        ),
      ),
    );
  }
}
