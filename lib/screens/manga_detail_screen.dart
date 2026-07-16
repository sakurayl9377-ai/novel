import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../config/theme.dart';
import '../design/app_tokens.dart';
import '../design/widgets/app_surfaces.dart';
import '../design/widgets/immersive_detail.dart';
import '../models/local_library.dart';
import '../models/manga.dart';
import '../models/manga_read_history.dart';
import '../services/download_manager_service.dart';
import '../services/manga_service.dart';
import '../widgets/manga_cover.dart';
import '../services/storage_service.dart';
import '../utils/auth_gate.dart';
import '../utils/catalog_title_parts.dart';
import '../widgets/comment_preview_panel.dart';
import 'comment_thread_screen.dart';
import 'manga_reader_screen.dart';

class MangaDetailScreen extends StatefulWidget {
  const MangaDetailScreen({super.key, required this.mangaId, this.title});

  final String mangaId;
  final String? title;

  @override
  State<MangaDetailScreen> createState() => _MangaDetailScreenState();
}

class _MangaDetailScreenState extends State<MangaDetailScreen> {
  final MangaService _service = MangaService();
  final StorageService _storageService = StorageService();

  Manga? _manga;
  MangaReadHistory? _history;
  bool _isLoading = true;
  bool _isFavorite = false;
  bool _isDownloadingChapter = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDetail());
  }

  Future<void> _loadDetail() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final manga = await _service.fetchDetail(widget.mangaId);
      final history = await _loadHistory(widget.mangaId);
      if (!mounted) return;
      setState(() {
        _manga = manga;
        _history = history;
        _isLoading = false;
      });
      unawaited(_loadFavoriteState(manga));
      _warmInitialChapterImages(manga, history);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '详情加载失败，请稍后重试';
      });
    }
  }

  void _warmInitialChapterImages(Manga manga, MangaReadHistory? history) {
    MangaChapter? target;
    if (history != null) {
      final index = _chapterIndexForHistory(manga, history);
      target = index >= 0 ? manga.chapters[index] : history.chapter;
    } else if (manga.chapters.isNotEmpty) {
      target = manga.chapters.first;
    }

    if (target == null) return;
    unawaited(_service.warmChapterImages(target));
  }

  Future<MangaReadHistory?> _loadHistory(String mangaId) async {
    final histories = await _storageService.getMangaReadHistory();
    for (final history in histories) {
      if (history.mangaId == mangaId) return history;
    }
    return null;
  }

  Future<void> _loadFavoriteState(Manga manga) async {
    final favorite = await _storageService.isFavorite(
      LibraryItemType.manga,
      manga.id,
    );
    if (!mounted || _manga?.id != manga.id) return;
    setState(() => _isFavorite = favorite);
  }

  Future<void> _toggleFavorite(Manga manga) async {
    if (_isFavorite) {
      await _storageService.removeFavoriteItem(LibraryItemType.manga, manga.id);
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
        id: 'manga_${manga.id}',
        type: LibraryItemType.manga,
        itemId: manga.id,
        title: manga.title,
        coverUrl: manga.coverUrl,
        subtitle: [
          manga.author,
          manga.status,
          manga.latestChapter,
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

  Future<void> _downloadChapter(Manga manga) async {
    if (_isDownloadingChapter || manga.chapters.isEmpty) return;
    final chapter = await showModalBottomSheet<MangaChapter>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: manga.chapters.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return const Padding(
                padding: EdgeInsets.fromLTRB(0, 0, 0, 8),
                child: Text(
                  '选择下载章节',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              );
            }
            final chapter = manga.chapters[index - 1];
            return ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: Text(chapter.title),
              onTap: () => Navigator.pop(context, chapter),
            );
          },
        ),
      ),
    );
    if (chapter == null) return;

    setState(() => _isDownloadingChapter = true);
    _showMessage('已加入下载队列：${chapter.title}');
    try {
      final chapterIndex = manga.chapters.indexWhere(
        (item) => item.url == chapter.url,
      );
      await DownloadManagerService.instance.enqueueMangaChapter(
        manga: manga,
        chapter: chapter,
        chapterIndex: chapterIndex < 0 ? 0 : chapterIndex,
      );
      if (mounted) _showMessage('正在下载 ${chapter.title}，可在“我的下载”中管理');
    } catch (_) {
      if (mounted) _showMessage('下载失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _isDownloadingChapter = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _readChapter(
    Manga manga,
    MangaChapter chapter,
    int index, {
    double initialScrollOffset = 0,
    double? initialScrollProgress,
    int initialPageIndex = 0,
    double initialPageOffsetRatio = 0,
  }) async {
    final canOpen = await ensureLoggedInForContent(
      context,
      allowed: index == 0,
      title: '登录后继续阅读',
      message: '未登录可试看漫画第一章，登录后可继续阅读后续章节。',
    );
    if (!canOpen || !mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: MangaReaderScreen.routeName),
        builder: (_) => MangaReaderScreen(
          manga: manga,
          chapter: chapter,
          chapterIndex: index,
          initialScrollOffset: initialScrollOffset,
          initialScrollProgress: initialScrollProgress,
          initialPageIndex: initialPageIndex,
          initialPageOffsetRatio: initialPageOffsetRatio,
        ),
      ),
    );
    if (!mounted) return;
    final history = await _loadHistory(manga.id);
    if (!mounted) return;
    setState(() => _history = history);
  }

  void _readFirstOrResume(Manga manga) {
    final history = _history;
    if (history != null) {
      final index = _chapterIndexForHistory(manga, history);
      final chapter = index >= 0 ? manga.chapters[index] : history.chapter;
      unawaited(
        _readChapter(
          manga,
          chapter,
          index >= 0 ? index : history.chapterIndex,
          initialScrollOffset: history.scrollOffset,
          initialScrollProgress: history.progress,
          initialPageIndex: history.pageIndex,
          initialPageOffsetRatio: history.pageOffsetRatio,
        ),
      );
      return;
    }
    if (manga.chapters.isEmpty) return;
    unawaited(_readChapter(manga, manga.chapters.first, 0));
  }

  void _showChapterCatalog(Manga manga) {
    if (manga.chapters.isEmpty) return;
    final history = _history;
    final initialIndex = history == null
        ? 0
        : _chapterIndexForHistory(
            manga,
            history,
          ).clamp(0, manga.chapters.length - 1);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MangaChapterCatalogSheet(
        manga: manga,
        initialIndex: initialIndex.toInt(),
        currentChapterUrl: history?.chapterUrl ?? '',
        onSelected: (chapter, index) {
          Navigator.pop(context);
          unawaited(_readChapter(manga, chapter, index));
        },
      ),
    );
  }

  int _chapterIndexForHistory(Manga manga, MangaReadHistory history) {
    final index = manga.chapters.indexWhere(
      (chapter) => chapter.url == history.chapterUrl,
    );
    if (index >= 0) return index;
    if (history.chapterIndex >= 0 &&
        history.chapterIndex < manga.chapters.length) {
      return history.chapterIndex;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final manga = _manga;
    final isNight = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: AppTokens.canvasColor(context),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? _buildError()
          : manga == null
          ? _buildError()
          : _buildModernDetailV2(manga, isNight),
      bottomNavigationBar: !_isLoading && _errorMessage == null && manga != null
          ? _buildBottomBar(manga)
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

  Widget _buildModernDetailV2(Manga manga, bool isNight) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: ImmersiveDetailHeader.expandedHeight,
          pinned: true,
          backgroundColor: const Color(0xFF151827),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          flexibleSpace: FlexibleSpaceBar(
            background: _buildInfo(manga, isNight),
          ),
          actions: [
            IconButton(
              tooltip: _isFavorite ? '取消收藏' : '收藏',
              onPressed: () => _toggleFavorite(manga),
              icon: Icon(
                _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              ),
            ),
            IconButton(
              tooltip: '下载章节',
              onPressed: _isDownloadingChapter || manga.chapters.isEmpty
                  ? null
                  : () => _downloadChapter(manga),
              icon: _isDownloadingChapter
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_download_outlined),
            ),
          ],
        ),
        SliverToBoxAdapter(child: _buildIntro(manga)),
        SliverToBoxAdapter(child: _buildChapterSection(manga)),
        SliverToBoxAdapter(child: _buildComments(manga)),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildDetail(Manga manga, bool isNight) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: ImmersiveDetailHeader.expandedHeight,
          pinned: true,
          backgroundColor: const Color(0xFF151827),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          flexibleSpace: FlexibleSpaceBar(
            background: _buildInfo(manga, isNight),
          ),
          actions: [
            IconButton(
              tooltip: _isFavorite ? '取消收藏' : '收藏',
              onPressed: () => _toggleFavorite(manga),
              icon: Icon(
                _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              ),
            ),
            IconButton(
              tooltip: '下载章节',
              onPressed: _isDownloadingChapter || manga.chapters.isEmpty
                  ? null
                  : () => _downloadChapter(manga),
              icon: _isDownloadingChapter
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_download_outlined),
            ),
          ],
        ),
        SliverToBoxAdapter(child: _buildIntroAndComments(manga)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _ChapterHeaderDelegate(
            color: AppTokens.cardColor(context),
            child: _buildChapterHeader(manga, isNight),
          ),
        ),
        if (manga.chapters.isEmpty)
          const SliverFillRemaining(child: Center(child: Text('暂无章节')))
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 2.25,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final chapter = manga.chapters[index];
                final selected = chapter.url == _history?.chapterUrl;
                return OutlinedButton(
                  onPressed: () => _readChapter(manga, chapter, index),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    backgroundColor: selected
                        ? AppTokens.brand.withValues(alpha: 0.12)
                        : AppTokens.cardColor(context),
                    side: BorderSide(
                      color: selected
                          ? AppTokens.brand
                          : AppTokens.borderColor(context),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                    ),
                  ),
                  child: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected ? AppTokens.brand : null,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                );
              }, childCount: manga.chapters.length),
            ),
          ),
      ],
    );
  }

  Widget _buildIntro(Manga manga) {
    if (manga.description.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '简介',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            Text(
              manga.description,
              style: TextStyle(
                color: AppTokens.secondaryText(context),
                fontSize: 15,
                height: 1.62,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChapterSection(Manga manga) {
    final chapters = manga.chapters;
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
                    '章节目录 ${chapters.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (chapters.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _showChapterCatalog(manga),
                    icon: const Icon(Icons.format_list_bulleted_rounded),
                    label: const Text('完整目录'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (chapters.isEmpty)
              Text(
                '暂无章节',
                style: TextStyle(
                  color: AppTokens.secondaryText(context),
                  fontWeight: FontWeight.w700,
                ),
              )
            else
              SizedBox(
                height: 70,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(760),
                  itemCount: chapters.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) => SizedBox(
                    width: 164,
                    child: _buildChapterButton(manga, chapters[index], index),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChapterButton(Manga manga, MangaChapter chapter, int index) {
    final selected = chapter.url == _history?.chapterUrl;
    final title = CatalogTitleParts.from(
      chapter.title,
      fallbackIndex: index + 1,
      unit: '话',
    );
    return _MangaChapterTile(
      indexLabel: title.indexLabel,
      title: title.title,
      selected: selected,
      onTap: () => _readChapter(manga, chapter, index),
    );
  }

  Widget _buildComments(Manga manga) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
      child: CommentPreviewPanel(
        title: '独立漫评',
        targetType: 'manga',
        targetId: manga.id,
        enableRating: true,
        moreText: '更多漫评',
        emptyText: '聊聊这一部漫画的剧情和画风',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CommentThreadScreen(
                title: '${manga.title} 漫评',
                targetType: 'manga',
                targetId: manga.id,
                targetTitle: manga.title,
                enableRating: true,
              ),
            ),
          );
        },
      ),
    );
  }

  // ignore: unused_element
  Widget _buildIntroAndComments(Manga manga) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (manga.description.isNotEmpty) ...[
            AppSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '简介',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    manga.description,
                    style: TextStyle(
                      color: AppTokens.secondaryText(context),
                      fontSize: 15,
                      height: 1.62,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          CommentPreviewPanel(
            title: '独立漫评',
            targetType: 'manga',
            targetId: manga.id,
            enableRating: true,
            moreText: '更多漫评',
            emptyText: '聊聊这一部漫画的剧情和画风',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CommentThreadScreen(
                    title: '${manga.title} 漫评',
                    targetType: 'manga',
                    targetId: manga.id,
                    targetTitle: manga.title,
                    enableRating: true,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInfo(Manga manga, bool isNight) {
    final history = _history;
    final author = manga.author.isNotEmpty ? manga.author : '未知作者';
    final progressValue = history == null
        ? '未读'
        : '第${history.chapterIndex + 1}话';
    final status = manga.status.isEmpty ? '未知' : manga.status;
    final latest = manga.latestChapter.isNotEmpty
        ? manga.latestChapter
        : (manga.chapters.isNotEmpty ? manga.chapters.last.title : '暂无章节');

    return ImmersiveDetailHeader(
      title: manga.title,
      subtitle: author,
      meta: latest,
      cover: MangaCover(imageUrl: manga.coverUrl),
      backdrop: MangaCover(imageUrl: manga.coverUrl),
      gradientColors: const [Color(0xFF151827), Color(0xFF4B2B74)],
      badges: [
        ImmersiveDetailBadge(
          icon: Icons.bolt_rounded,
          label: status,
          color: AppTokens.reward,
        ),
        ImmersiveDetailBadge(
          icon: Icons.update_rounded,
          label: latest,
          color: Colors.white,
        ),
        ImmersiveDetailBadge(
          icon: _isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
          label: _isFavorite ? '已收藏' : '可收藏',
          color: _isFavorite ? AppTokens.reward : Colors.white,
        ),
      ],
      metrics: [
        ImmersiveDetailMetric(value: '${manga.chapters.length}', label: '章节'),
        ImmersiveDetailMetric(value: progressValue, label: '进度'),
        ImmersiveDetailMetric(value: status, label: '状态'),
      ],
    );
  }

  Widget _buildChapterHeader(Manga manga, bool isNight) {
    return Material(
      color: AppTokens.cardColor(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '章节目录 ${manga.chapters.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isNight ? Colors.white : AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, color: AppTheme.textHint),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(Manga manga) {
    final history = _history;
    final disabled = manga.chapters.isEmpty;
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
                onPressed: () => _toggleFavorite(manga),
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
                  onPressed: disabled ? null : () => _readFirstOrResume(manga),
                  icon: Icon(
                    history == null
                        ? Icons.menu_book_outlined
                        : Icons.history_rounded,
                    size: 20,
                  ),
                  label: Text(history == null ? '开始阅读' : '继续阅读'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MangaChapterCatalogSheet extends StatefulWidget {
  const _MangaChapterCatalogSheet({
    required this.manga,
    required this.initialIndex,
    required this.currentChapterUrl,
    required this.onSelected,
  });

  final Manga manga;
  final int initialIndex;
  final String currentChapterUrl;
  final void Function(MangaChapter chapter, int index) onSelected;

  @override
  State<_MangaChapterCatalogSheet> createState() =>
      _MangaChapterCatalogSheetState();
}

class _MangaChapterCatalogSheetState extends State<_MangaChapterCatalogSheet> {
  static const double _itemExtent = 64;

  late final ScrollController _scrollController;
  late double _sliderValue;
  bool _draggingSlider = false;

  @override
  void initState() {
    super.initState();
    _sliderValue = widget.initialIndex.toDouble();
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialIndex * _itemExtent,
    )..addListener(_syncSliderFromScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_syncSliderFromScroll)
      ..dispose();
    super.dispose();
  }

  void _syncSliderFromScroll() {
    if (_draggingSlider ||
        !_scrollController.hasClients ||
        widget.manga.chapters.isEmpty) {
      return;
    }
    final index = (_scrollController.offset / _itemExtent)
        .round()
        .clamp(0, widget.manga.chapters.length - 1)
        .toInt();
    if (index != _sliderValue.round()) {
      setState(() => _sliderValue = index.toDouble());
    }
  }

  void _jumpTo(double value) {
    if (!_scrollController.hasClients || widget.manga.chapters.isEmpty) return;
    final target = (value.round() * _itemExtent).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.manga.chapters;
    final max = chapters.isEmpty ? 0.0 : (chapters.length - 1).toDouble();
    final sliderIndex = _sliderValue
        .round()
        .clamp(0, chapters.isEmpty ? 0 : chapters.length - 1)
        .toInt();
    final currentTitle = chapters.isEmpty
        ? null
        : CatalogTitleParts.from(
            chapters[sliderIndex].title,
            fallbackIndex: sliderIndex + 1,
            unit: '话',
          );

    return SafeArea(
      top: false,
      child: Container(
        height: MediaQuery.sizeOf(context).height * 0.88,
        decoration: BoxDecoration(
          color: AppTokens.cardColor(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 28,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppTokens.borderColor(context),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '章节目录 ${chapters.length}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTokens.primaryText(context),
                        fontSize: 20,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (chapters.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.swipe_vertical_rounded,
                          size: 17,
                          color: AppTokens.brand,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            currentTitle == null
                                ? ''
                                : '${currentTitle.indexLabel} ${currentTitle.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTokens.secondaryText(context),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _sliderValue.clamp(0, max),
                      min: 0,
                      max: max == 0 ? 1 : max,
                      divisions: chapters.length <= 500 && max > 0
                          ? max.toInt()
                          : null,
                      label: currentTitle?.indexLabel,
                      onChanged: max == 0
                          ? null
                          : (value) {
                              setState(() {
                                _draggingSlider = true;
                                _sliderValue = value;
                              });
                              _jumpTo(value);
                            },
                      onChangeEnd: (_) => _draggingSlider = false,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                itemExtent: _itemExtent,
                scrollCacheExtent: const ScrollCacheExtent.pixels(
                  _itemExtent * 12,
                ),
                itemCount: chapters.length,
                itemBuilder: (context, index) {
                  final chapter = chapters[index];
                  final title = CatalogTitleParts.from(
                    chapter.title,
                    fallbackIndex: index + 1,
                    unit: '话',
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _MangaChapterTile(
                      indexLabel: title.indexLabel,
                      title: title.title,
                      selected: chapter.url == widget.currentChapterUrl,
                      dense: false,
                      onTap: () => widget.onSelected(chapter, index),
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

class _MangaChapterTile extends StatelessWidget {
  const _MangaChapterTile({
    required this.indexLabel,
    required this.title,
    required this.selected,
    required this.onTap,
    this.dense = true,
  });

  final String indexLabel;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppTokens.radiusSm);
    final borderColor = selected
        ? AppTokens.brand
        : AppTokens.borderColor(context);
    final backgroundColor = selected
        ? AppTokens.brand.withValues(alpha: 0.11)
        : AppTokens.cardColor(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Ink(
          padding: dense
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: radius,
            border: Border.all(color: borderColor),
          ),
          child: dense ? _buildDense(context) : _buildListRow(context),
        ),
      ),
    );
  }

  Widget _buildDense(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: title.isEmpty
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Text(
          indexLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? AppTokens.brand : AppTokens.primaryText(context),
            fontSize: 13,
            height: 1.05,
            fontWeight: FontWeight.w900,
          ),
        ),
        if (title.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected
                  ? AppTokens.brandDark
                  : AppTokens.secondaryText(context),
              fontSize: 11.5,
              height: 1.22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildListRow(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 74,
          child: Text(
            indexLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected
                  ? AppTokens.brand
                  : AppTokens.primaryText(context),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title.isEmpty ? indexLabel : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected
                  ? AppTokens.brandDark
                  : AppTokens.primaryText(context),
              fontSize: 14,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
        if (selected) ...[
          const SizedBox(width: 8),
          const Icon(
            Icons.play_circle_fill_rounded,
            size: 18,
            color: AppTokens.brand,
          ),
        ],
      ],
    );
  }
}

class _ChapterHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _ChapterHeaderDelegate({required this.child, required this.color});

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
  bool shouldRebuild(covariant _ChapterHeaderDelegate oldDelegate) {
    return oldDelegate.child != child || oldDelegate.color != color;
  }
}

// ignore: unused_element
class _MangaHeaderChip extends StatelessWidget {
  const _MangaHeaderChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 176),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _MangaHeaderMetric extends StatelessWidget {
  const _MangaHeaderMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 56,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
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
                fontSize: 16,
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
