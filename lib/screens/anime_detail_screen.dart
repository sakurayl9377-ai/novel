import 'dart:async';

import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../design/app_tokens.dart';
import '../design/widgets/app_surfaces.dart';
import '../design/widgets/immersive_detail.dart';
import '../models/anime.dart';
import '../models/local_library.dart';
import '../services/anime_playback_source_selector.dart';
import '../services/anime_service.dart';
import '../services/download_manager_service.dart';
import '../services/storage_service.dart';
import '../utils/auth_gate.dart';
import '../utils/catalog_title_parts.dart';
import '../widgets/comment_preview_panel.dart';
import 'anime_player_screen.dart';
import 'anime_screen.dart';
import 'comment_thread_screen.dart';

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
  final StorageService _storageService = StorageService();

  Anime? _anime;
  bool _isLoading = true;
  bool _isFavorite = false;
  bool _episodeListExpanded = false;
  int _selectedSourceIndex = 0;
  String? _errorMessage;
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    _anime = widget.initialAnime;
    if (_anime != null && _anime!.playSources.isNotEmpty) {
      _isLoading = false;
      _syncTabs();
      unawaited(_loadFavoriteState(_anime!));
    } else {
      unawaited(_loadDetail());
    }
  }

  @override
  void dispose() {
    _tabController?.removeListener(_handleSourceTabChanged);
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
      unawaited(_loadFavoriteState(anime));
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
    _tabController?.removeListener(_handleSourceTabChanged);
    _tabController?.dispose();
    _episodeListExpanded = false;
    _selectedSourceIndex = AnimePlaybackSourceSelector.preferredIndex(_anime);
    _tabController = sourceCount > 0
        ? TabController(
            length: sourceCount,
            initialIndex: _selectedSourceIndex,
            vsync: this,
          )
        : null;
    _tabController?.addListener(_handleSourceTabChanged);
  }

  void _handleSourceTabChanged() {
    final controller = _tabController;
    final sourceCount = _anime?.playSources.length ?? 0;
    if (!mounted || controller == null || sourceCount == 0) return;
    final nextIndex = controller.index.clamp(0, sourceCount - 1).toInt();
    if (_selectedSourceIndex == nextIndex) return;
    setState(() {
      _selectedSourceIndex = nextIndex;
      _episodeListExpanded = false;
    });
  }

  Future<void> _loadFavoriteState(Anime anime) async {
    final favorite = await _storageService.isFavorite(
      LibraryItemType.anime,
      anime.id.toString(),
    );
    if (!mounted || _anime?.id != anime.id) return;
    setState(() => _isFavorite = favorite);
  }

  Future<void> _toggleFavorite(Anime anime) async {
    if (_isFavorite) {
      await _storageService.removeFavoriteItem(
        LibraryItemType.anime,
        anime.id.toString(),
      );
      if (!mounted) return;
      setState(() => _isFavorite = false);
      _showMessage('已取消收藏');
      return;
    }
    final folder = await _pickFavoriteFolder();
    if (folder == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _storageService.saveFavoriteItem(
      FavoriteItem(
        id: 'anime_${anime.id}',
        type: LibraryItemType.anime,
        itemId: anime.id.toString(),
        title: anime.title,
        coverUrl: anime.coverUrl,
        subtitle: [
          anime.year,
          anime.category,
          anime.status,
        ].where((item) => item.isNotEmpty).join(' · '),
        folderId: folder.id,
        createdAtMs: now,
      ),
    );
    if (!mounted) return;
    setState(() => _isFavorite = true);
    _showMessage('已收藏到 ${folder.name}');
  }

  Future<FavoriteFolder?> _pickFavoriteFolder() async {
    final folders = await _storageService.getFavoriteFolders();
    if (!mounted) return null;
    return showModalBottomSheet<FavoriteFolder>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            const Text(
              '选择收藏夹',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            for (final folder in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.name),
                onTap: () => Navigator.pop(context, folder),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建收藏夹'),
              onTap: () async {
                final folder = await _createFavoriteFolder(context);
                if (context.mounted && folder != null) {
                  Navigator.pop(context, folder);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<FavoriteFolder?> _createFavoriteFolder(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建收藏夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '收藏夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return null;
    return _storageService.createFavoriteFolder(name);
  }

  Future<void> _addEpisodeDownload(Anime anime) async {
    final selection =
        await showModalBottomSheet<
          ({AnimePlaySource source, AnimeEpisode episode})
        >(
          context: context,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                const Text(
                  '选择下载分集',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                for (final source in anime.playSources) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      source.name,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  for (final episode in source.episodes)
                    ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(episode.title),
                      onTap: () => Navigator.pop(context, (
                        source: source,
                        episode: episode,
                      )),
                    ),
                ],
              ],
            ),
          ),
        );
    if (selection == null) return;
    final item = await DownloadManagerService.instance.enqueueAnime(
      anime: anime,
      source: selection.source,
      episode: selection.episode,
    );
    if (mounted) {
      _showMessage(item.status == 'done' ? '该分集已下载' : '已加入真实下载队列');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _playEpisode(
    AnimePlaySource source,
    AnimeEpisode episode,
  ) async {
    final anime = _anime;
    if (anime == null) return;
    final episodeIndex = source.episodes.indexWhere(
      (item) => item.url == episode.url,
    );
    final canOpen = await ensureLoggedInForContent(
      context,
      allowed: episodeIndex == 0,
      title: '登录后继续观看',
      message: '未登录可试看动漫第一集，登录后可继续观看后续剧集。',
    );
    if (!canOpen || !mounted) return;

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
      backgroundColor: AppTokens.canvasColor(context),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? _buildError()
          : anime == null
          ? _buildError()
          : _buildDetail(anime, isNight),
      bottomNavigationBar: !_isLoading && _errorMessage == null && anime != null
          ? _buildBottomBar(anime)
          : null,
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
    return _buildModernDetailV2(anime);
  }

  Widget _buildModernDetailV2(Anime anime) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: ImmersiveDetailHeader.expandedHeight,
          pinned: true,
          backgroundColor: const Color(0xFF101827),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(anime.title),
          flexibleSpace: FlexibleSpaceBar(
            background: _buildReferenceInfo(anime),
          ),
          actions: [
            IconButton(
              tooltip: _isFavorite ? '取消收藏' : '收藏',
              onPressed: () => _toggleFavorite(anime),
              icon: Icon(
                _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              ),
            ),
            IconButton(
              tooltip: '下载',
              onPressed: anime.playSources.isEmpty
                  ? null
                  : () => _addEpisodeDownload(anime),
              icon: const Icon(Icons.file_download_outlined),
            ),
          ],
        ),
        SliverToBoxAdapter(child: _buildModernIntro(anime)),
        SliverToBoxAdapter(child: _buildModernEpisodeSection(anime)),
        SliverToBoxAdapter(child: _buildModernComments(anime)),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildModernDetail(Anime anime) {
    final sources = anime.playSources;

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: ImmersiveDetailHeader.expandedHeight,
          pinned: true,
          backgroundColor: const Color(0xFF101827),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(anime.title),
          flexibleSpace: FlexibleSpaceBar(
            background: _buildReferenceInfo(anime),
          ),
          actions: [
            IconButton(
              tooltip: _isFavorite ? '取消收藏' : '收藏',
              onPressed: () => _toggleFavorite(anime),
              icon: Icon(
                _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              ),
            ),
            IconButton(
              tooltip: '下载',
              onPressed: anime.playSources.isEmpty
                  ? null
                  : () => _addEpisodeDownload(anime),
              icon: const Icon(Icons.file_download_outlined),
            ),
          ],
        ),
        SliverToBoxAdapter(child: _buildModernIntroAndComments(anime)),
        if (sources.isEmpty)
          const SliverFillRemaining(child: Center(child: Text('暂无可播放剧集')))
        else ...[
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabHeaderDelegate(
              color: AppTokens.cardColor(context),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: [
                  for (final source in sources)
                    Tab(text: '${source.name} · ${source.episodes.length}'),
                ],
              ),
            ),
          ),
          SliverFillRemaining(
            child: TabBarView(
              controller: _tabController,
              children: [
                for (final source in sources) _buildModernEpisodeGrid(source),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildReferenceInfo(Anime anime) {
    final meta = [
      anime.year,
      anime.area,
      anime.category,
    ].where((value) => value.isNotEmpty).join(' | ');
    final status = anime.status.isEmpty ? '连载中' : anime.status;
    final backdropUrl = anime.slideUrl.isNotEmpty
        ? anime.slideUrl
        : anime.coverUrl;

    return ImmersiveDetailHeader(
      title: anime.title,
      subtitle: anime.subtitle,
      meta: meta.isEmpty ? '热血 | 奇幻 | 都市' : meta,
      cover: AnimeCover(imageUrl: anime.coverUrl),
      backdrop: AnimeCover(imageUrl: backdropUrl),
      gradientColors: const [Color(0xFF101827), Color(0xFF17355F)],
      badges: [
        const ImmersiveDetailBadge(
          icon: Icons.shield_rounded,
          label: 'TOP 2 热血榜',
          color: AppTokens.reward,
        ),
        ImmersiveDetailBadge(
          icon: Icons.bolt_rounded,
          label: status,
          color: AppTokens.reward,
        ),
        ImmersiveDetailBadge(
          icon: _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
          label: _isFavorite ? '已收藏' : '可收藏',
          color: _isFavorite ? AppTokens.reward : Colors.white,
        ),
      ],
      metrics: _detailMetrics(anime),
    );
  }

  List<ImmersiveDetailMetric> _detailMetrics(Anime anime) {
    final totalEpisodes = anime.playSources.fold<int>(
      0,
      (sum, source) => sum + source.episodes.length,
    );
    return [
      const ImmersiveDetailMetric(value: '9.5', label: '评分'),
      ImmersiveDetailMetric(value: '${anime.playSources.length}', label: '播放源'),
      ImmersiveDetailMetric(
        value: totalEpisodes > 0 ? '$totalEpisodes话' : '-',
        label: '剧集',
      ),
    ];
  }

  AnimePlaySource? _firstPlayableSource(Anime anime) {
    final index = AnimePlaybackSourceSelector.preferredIndex(anime);
    if (index < 0 || index >= anime.playSources.length) return null;
    return anime.playSources[index];
  }

  Widget _buildBottomBar(Anime anime) {
    final source = _firstPlayableSource(anime);
    final episode = source?.episodes.first;
    final disabled = source == null || episode == null;

    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: AppTokens.cardColor(context),
        border: Border(top: BorderSide(color: AppTokens.borderColor(context))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            SizedBox(
              width: 112,
              height: 46,
              child: TextButton.icon(
                onPressed: () => _toggleFavorite(anime),
                icon: Icon(
                  _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 19,
                ),
                label: Text(_isFavorite ? '已收藏' : '收藏'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 46,
                child: FilledButton.icon(
                  onPressed: disabled
                      ? null
                      : () => _playEpisode(source, episode),
                  icon: const Icon(Icons.play_arrow_rounded, size: 22),
                  label: Text(disabled ? '暂无播放' : '立即播放'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildModernInfo(Anime anime) {
    final meta = [
      anime.status,
      anime.year,
      anime.area,
      anime.category,
    ].where((value) => value.isNotEmpty).join(' · ');

    AnimePlaySource? firstPlayableSource;
    for (final source in anime.playSources) {
      if (source.episodes.isNotEmpty) {
        firstPlayableSource = source;
        break;
      }
    }
    final firstEpisode = anime.firstEpisode;
    final VoidCallback? playAction =
        firstEpisode == null || firstPlayableSource == null
        ? null
        : () => _playEpisode(firstPlayableSource!, firstEpisode);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101927), Color(0xFF1F6FEB)],
        ),
        boxShadow: AppTokens.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                width: 108,
                height: 150,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x55000000),
                      blurRadius: 18,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: AnimeCover(imageUrl: anime.coverUrl),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      anime.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        height: 1.12,
                      ),
                    ),
                    if (anime.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        anime.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFFFD166),
                          fontSize: 12,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: playAction,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('立即播放'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _AnimeHeaderMetric(
                value: '${anime.playSources.length}',
                label: '播放源',
              ),
              _AnimeHeaderMetric(
                value: anime.status.isEmpty ? '-' : anime.status,
                label: '状态',
              ),
              _AnimeHeaderMetric(
                value: anime.year.isEmpty ? '-' : anime.year,
                label: '年份',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModernIntro(Anime anime) {
    final hasIntro =
        anime.description.isNotEmpty ||
        anime.director.isNotEmpty ||
        anime.actors.isNotEmpty;
    if (!hasIntro) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (anime.description.isNotEmpty) ...[
              const Text(
                '简介',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              Text(
                anime.description,
                style: TextStyle(
                  color: AppTokens.secondaryText(context),
                  fontSize: 14,
                  height: 1.6,
                ),
              ),
            ],
            if (anime.director.isNotEmpty || anime.actors.isNotEmpty) ...[
              if (anime.description.isNotEmpty) const SizedBox(height: 12),
              _ModernMetaLine(label: '导演', value: anime.director),
              _ModernMetaLine(label: '主演', value: anime.actors),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModernEpisodeSection(Anime anime) {
    final sources = anime.playSources;
    if (sources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: AppSurface(
          child: Text(
            '暂无可播放剧集',
            style: TextStyle(
              color: AppTokens.secondaryText(context),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    final selectedIndex = _selectedSourceIndex
        .clamp(0, sources.length - 1)
        .toInt();
    final source = sources[selectedIndex];
    final episodes = source.episodes;
    final visibleEpisodeCount = _episodeListExpanded
        ? episodes.length
        : episodes.length.clamp(0, 6).toInt();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '选集 ${episodes.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (episodes.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => setState(
                      () => _episodeListExpanded = !_episodeListExpanded,
                    ),
                    icon: Icon(
                      _episodeListExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                    ),
                    label: Text(_episodeListExpanded ? '收起' : '展开全部'),
                  ),
              ],
            ),
            if (sources.length > 1) ...[
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var index = 0; index < sources.length; index++) ...[
                      ChoiceChip(
                        selected: index == selectedIndex,
                        label: Text(
                          '${sources[index].name} · ${sources[index].episodes.length}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onSelected: (_) {
                          if (_selectedSourceIndex == index) return;
                          setState(() {
                            _selectedSourceIndex = index;
                            _episodeListExpanded = false;
                          });
                          _tabController?.animateTo(index);
                        },
                      ),
                      if (index != sources.length - 1) const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (episodes.isEmpty)
              Text(
                '暂无可播放剧集',
                style: TextStyle(
                  color: AppTokens.secondaryText(context),
                  fontWeight: FontWeight.w700,
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (
                      var index = 0;
                      index < visibleEpisodeCount;
                      index++
                    ) ...[
                      SizedBox(
                        width: 168,
                        height: 70,
                        child: _buildModernEpisodeButton(
                          source,
                          episodes[index],
                          index: index,
                        ),
                      ),
                      if (index != visibleEpisodeCount - 1)
                        const SizedBox(width: 10),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildModernEpisodeButton(
    AnimePlaySource source,
    AnimeEpisode episode, {
    required int index,
  }) {
    final title = CatalogTitleParts.from(
      episode.title,
      fallbackIndex: index + 1,
      unit: '集',
    );
    final radius = BorderRadius.circular(AppTokens.radiusSm);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _playEpisode(source, episode),
        borderRadius: radius,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppTokens.cardColor(context),
            borderRadius: radius,
            border: Border.all(color: AppTokens.borderColor(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: title.title.isEmpty
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              Text(
                title.indexLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTokens.brand,
                  fontSize: 13,
                  height: 1.05,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (title.title.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  title.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTokens.secondaryText(context),
                    fontSize: 11.5,
                    height: 1.22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModernComments(Anime anime) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
      child: CommentPreviewPanel(
        title: '独立漫评',
        targetType: 'anime',
        targetId: anime.id.toString(),
        moreText: '更多漫评',
        emptyText: '聊聊这部动漫的剧情、演出和观感',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CommentThreadScreen(
                title: '${anime.title} 漫评',
                targetType: 'anime',
                targetId: anime.id.toString(),
                targetTitle: anime.title,
              ),
            ),
          );
        },
      ),
    );
  }

  // ignore: unused_element
  Widget _buildModernIntroAndComments(Anime anime) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (anime.description.isNotEmpty)
            AppSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '简介',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    anime.description,
                    style: TextStyle(
                      color: AppTokens.secondaryText(context),
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
                  if (anime.director.isNotEmpty || anime.actors.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _ModernMetaLine(label: '导演', value: anime.director),
                    _ModernMetaLine(label: '主演', value: anime.actors),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 12),
          CommentPreviewPanel(
            title: '独立漫评',
            targetType: 'anime',
            targetId: anime.id.toString(),
            moreText: '更多漫评',
            emptyText: '聊聊这部动漫的剧情、演出和观感',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CommentThreadScreen(
                    title: '${anime.title} 漫评',
                    targetType: 'anime',
                    targetId: anime.id.toString(),
                    targetTitle: anime.title,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildModernEpisodeGrid(AnimePlaySource source) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 110),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 2.35,
      ),
      itemCount: source.episodes.length,
      itemBuilder: (context, index) {
        final episode = source.episodes[index];
        return OutlinedButton(
          onPressed: () => _playEpisode(source, episode),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            backgroundColor: AppTokens.cardColor(context),
            side: BorderSide(color: AppTokens.borderColor(context)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
          ),
          child: Text(
            episode.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTokens.primaryText(context),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }

  // ignore: unused_element
  Widget _buildLegacyDetail(Anime anime, bool isNight) {
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
          const SizedBox(height: 16),
          CommentPreviewPanel(
            title: '评论',
            targetType: 'anime',
            targetId: anime.id.toString(),
            moreText: '更多评论',
            emptyText: '来发一条友善的评论',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CommentThreadScreen(
                    title: '${anime.title} 评论',
                    targetType: 'anime',
                    targetId: anime.id.toString(),
                    targetTitle: anime.title,
                  ),
                ),
              );
            },
          ),
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

// ignore: unused_element
class _ReferenceAnimeMetric extends StatelessWidget {
  const _ReferenceAnimeMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimeHeaderMetric extends StatelessWidget {
  const _AnimeHeaderMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 52,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModernMetaLine extends StatelessWidget {
  const _ModernMetaLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        '$label：$value',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppTokens.secondaryText(context),
          fontSize: 12,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
      ),
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
