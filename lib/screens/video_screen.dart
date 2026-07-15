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
      final items = await _service.fetchCategory(categoryPath);
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
