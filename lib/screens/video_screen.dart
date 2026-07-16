import 'dart:async';

import 'package:flutter/material.dart';

import '../models/wuhandky_video.dart';
import '../services/wuhandky_service.dart';
import '../widgets/wuhandky_cover_image.dart';
import 'video_detail_screen.dart';

class _VideoCategory {
  const _VideoCategory(this.title, this.path, this.children);

  final String title;
  final String path;
  final List<(String, String)> children;
}

const _videoCategories = <_VideoCategory>[
  _VideoCategory('电影', '/dianying/', [
    ('全部', '/dianying/'),
    ('动作电影', '/dongzuopian/'),
    ('喜剧电影', '/xijupian/'),
    ('爱情电影', '/aiqingpian/'),
    ('科幻电影', '/kehuanpian/'),
    ('恐怖电影', '/kongbupian/'),
    ('战争电影', '/zhanzhengpian/'),
    ('剧情电影', '/juqingpian/'),
    ('纪录片', '/jilupian/'),
    ('动漫电影', '/dongmandianying/'),
  ]),
  _VideoCategory('电视剧', '/dianshiju/', [
    ('全部', '/dianshiju/'),
    ('国产剧', '/guochanju/'),
    ('香港剧', '/xianggangju/'),
    ('韩国剧', '/hanguoju/'),
    ('欧美剧', '/oumeiju/'),
    ('台湾剧', '/taiwanju/'),
    ('日本剧', '/ribenju/'),
    ('泰国剧', '/taiguoju/'),
    ('海外剧', '/haiwaiju/'),
  ]),
  _VideoCategory('动漫', '/dongman/', [
    ('全部', '/dongman/'),
    ('国产动漫', '/guochandongman/'),
    ('日韩动漫', '/rihandongman/'),
    ('欧美动漫', '/oumeidongman/'),
    ('港台动漫', '/gangtaidongman/'),
    ('海外动漫', '/haiwaidongman/'),
  ]),
  _VideoCategory('综艺', '/zongyi/', [
    ('全部', '/zongyi/'),
    ('内地综艺', '/neidizongyi/'),
    ('港台综艺', '/gangtaizongyi/'),
    ('日韩综艺', '/rihanzongyi/'),
    ('欧美综艺', '/oumeizongyi/'),
  ]),
];

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, this.service});

  final WuhandkyService? service;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen>
    with AutomaticKeepAliveClientMixin {
  late final WuhandkyService _service;
  final TextEditingController _searchController = TextEditingController();
  List<WuhandkyVideoItem> _items = const [];
  WuhandkyVideoHome? _home;
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
    setState(() {
      _loading = true;
      _searching = false;
      _error = '';
      if (refresh) _items = const [];
    });
    try {
      final home = await _service.fetchHome();
      final items = home.featured;
      if (!mounted || requestGeneration != _requestGeneration) return;
      setState(() {
        _home = home;
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
          preferredSize: const Size.fromHeight(62),
          child: Padding(
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
            : !_searching && _home != null
            ? _VideoHomeView(
                home: _home!,
                onOpen: _open,
                onSelectCategory: _openCategory,
                resolveCover: (item) => _service.resolveCoverUrl(
                  title: item.title,
                  itemKey: item.detailUrl,
                  candidateUrl: item.coverUrl,
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
                    candidateUrl: _items[index].coverUrl,
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

  void _openCategory(String path) {
    final category = _videoCategories.firstWhere(
      (item) => item.path == path,
      orElse: () => _videoCategories.first,
    );
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _VideoCategoryScreen(
          category: category,
          service: _service,
          onOpen: _open,
        ),
      ),
    );
  }
}

class _VideoHomeView extends StatefulWidget {
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
  State<_VideoHomeView> createState() => _VideoHomeViewState();
}

class _VideoHomeViewState extends State<_VideoHomeView> {
  late final PageController _controller;
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
    if (widget.home.featured.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted || !_controller.hasClients) return;
        final next = (_page + 1) % widget.home.featured.length;
        _controller.animateToPage(
          next,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = widget.home;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          sliver: SliverToBoxAdapter(
            child: SizedBox(
              height: 190,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  PageView.builder(
                    controller: _controller,
                    itemCount: home.featured.length,
                    onPageChanged: (value) => setState(() => _page = value),
                    itemBuilder: (context, index) {
                      final item = home.featured[index];
                      return _VideoFeaturedCard(
                        item: item,
                        onTap: () => widget.onOpen(item),
                        resolveCover: () => widget.resolveCover(item),
                      );
                    },
                  ),
                  Positioned(
                    bottom: 10,
                    child: Row(
                      children: List.generate(
                        home.featured.length,
                        (index) => AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: index == _page ? 18 : 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: index == _page
                                ? Colors.white
                                : Colors.white54,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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
                  onPressed: () => widget.onSelectCategory(section.path),
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
                    onPressed: () => widget.onSelectCategory(section.path),
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
                      onTap: () => widget.onOpen(item),
                      resolveCover: () => widget.resolveCover(item),
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

class _VideoCategoryScreen extends StatefulWidget {
  const _VideoCategoryScreen({
    required this.category,
    required this.service,
    required this.onOpen,
  });

  final _VideoCategory category;
  final WuhandkyService service;
  final ValueChanged<WuhandkyVideoItem> onOpen;

  @override
  State<_VideoCategoryScreen> createState() => _VideoCategoryScreenState();
}

class _VideoCategoryScreenState extends State<_VideoCategoryScreen> {
  int _selected = 0;
  int _generation = 0;
  bool _loading = true;
  String _error = '';
  List<WuhandkyVideoItem> _items = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final items = await widget.service.fetchCategory(
        widget.category.children[_selected].$2,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _items = items);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.category.title)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (
                      var index = 0;
                      index < widget.category.children.length;
                      index++
                    )
                      ChoiceChip(
                        label: Text(widget.category.children[index].$1),
                        selected: index == _selected,
                        onSelected: (_) {
                          if (index == _selected) return;
                          setState(() {
                            _selected = index;
                            _items = const [];
                          });
                          unawaited(_load());
                        },
                      ),
                  ],
                ),
              ),
            ),
            if (_loading && _items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error.isNotEmpty && _items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
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
                ),
              )
            else if (_items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('暂无内容')),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 0.53,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return _VideoCard(
                      item: item,
                      onTap: () => widget.onOpen(item),
                      resolveCover: () => widget.service.resolveCoverUrl(
                        title: item.title,
                        itemKey: item.detailUrl,
                        candidateUrl: item.coverUrl,
                      ),
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
