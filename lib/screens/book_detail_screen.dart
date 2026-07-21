import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../design/app_tokens.dart';
import '../design/widgets/app_surfaces.dart';
import '../design/widgets/immersive_detail.dart';
import '../models/interaction_models.dart';
import '../models/novel.dart';
import '../models/chapter.dart';
import '../models/reading_progress.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/book_source_provider.dart';
import '../providers/reading_provider.dart';
import '../services/novel_offline_cache_service.dart';
import '../utils/auth_gate.dart';
import '../widgets/book_cover_widget.dart';
import '../widgets/chapter_list_widget.dart';
import '../widgets/comment_preview_panel.dart';
import '../widgets/novel_cache_sheet.dart';
import 'comment_thread_screen.dart';
import 'reading_screen.dart';

class BookDetailScreen extends StatefulWidget {
  final Novel novel;
  final ReadingProgress? initialProgress;

  const BookDetailScreen({
    super.key,
    required this.novel,
    this.initialProgress,
  });

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late Novel _novel;
  List<Chapter> _chapters = [];
  bool _isLoadingChapters = false;
  bool _isOpeningReading = false;
  bool _showFullDescription = false;
  double? _commentRatingAvg;
  int _commentPreviewVersion = 0;
  ReadingProgress? _readingProgress;
  static const int _guestChapterLimit = 10;

  @override
  void initState() {
    super.initState();
    _novel = widget.novel;
    _readingProgress = resolveNovelEntryProgress([
      widget.initialProgress,
      context.read<BookshelfProvider>().progressForNovel(_novel),
    ]);
    _tabController = TabController(length: 2, vsync: this);
    _loadChapters();
  }

  Future<void> _loadChapters() async {
    setState(() => _isLoadingChapters = true);
    final sourceProvider = context.read<BookSourceProvider>();
    final bookshelfProvider = context.read<BookshelfProvider>();
    final readingProvider = context.read<ReadingProvider>();
    try {
      final progressFuture = readingProvider.loadProgress(_novel);
      var detailedNovel = _novel;
      if (!_novel.isLocal) {
        try {
          detailedNovel = await sourceProvider.getBookDetail(_novel);
        } catch (_) {
          // Cached chapters remain usable when the detail endpoint is offline.
        }
      }
      final chaptersFuture = sourceProvider.getChapterList(detailedNovel);
      final storedProgress = await progressFuture;
      final savedProgress = resolveNovelEntryProgress([
        storedProgress,
        _readingProgress,
      ]);
      final chapters = await chaptersFuture;
      if (!mounted) return;
      final updatedNovel = detailedNovel.copyWith(
        totalChapters: chapters.length,
        currentChapterIndex:
            savedProgress?.chapterIndex ?? detailedNovel.currentChapterIndex,
      );
      setState(() {
        _chapters = chapters;
        _novel = updatedNovel;
        _readingProgress = savedProgress;
        _isLoadingChapters = false;
      });
      if (chapters.isNotEmpty) {
        await bookshelfProvider.updateNovel(updatedNovel);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingChapters = false);
    }
  }

  Future<void> _openReading() async {
    if (_isOpeningReading) return;
    setState(() => _isOpeningReading = true);
    try {
      final readingProvider = context.read<ReadingProvider>();
      final sourceProvider = context.read<BookSourceProvider>();
      final savedProgress =
          _readingProgress ?? await readingProvider.loadProgress(_novel);
      if (!mounted) return;
      final requestedChapterIndex =
          savedProgress?.chapterIndex ?? _novel.currentChapterIndex;
      var chaptersForReading = _chapters;
      var chaptersAreProvisional = false;
      if (chaptersForReading.isEmpty && !_novel.isLocal) {
        chaptersForReading = sourceProvider.buildProvisionalChapterList(
          _novel,
          throughIndex: requestedChapterIndex,
        );
        chaptersAreProvisional = chaptersForReading.isNotEmpty;
      }
      if (chaptersForReading.isEmpty && !_novel.isLocal) {
        await _loadChapters();
        chaptersForReading = _chapters;
      }
      if (!mounted) return;
      if (chaptersForReading.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('章节目录还没有加载成功，请稍后重试')));
        return;
      }

      final safeStartChapterIndex = requestedChapterIndex
          .clamp(0, chaptersForReading.length - 1)
          .toInt();
      final canOpen = await _ensureNovelChapterUnlocked(safeStartChapterIndex);
      if (!mounted || !canOpen) return;
      final startCharPosition = savedProgress?.charPosition ?? 0;
      final startScrollPosition = savedProgress?.scrollPosition ?? 0.0;

      readingProvider.setCurrentNovel(_novel);
      readingProvider.setCurrentChapter(
        chaptersForReading[safeStartChapterIndex],
      );

      await Navigator.push(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: ReadingScreen.routeName),
          builder: (_) => ReadingScreen(
            novel: _novel,
            chapters: chaptersForReading,
            chaptersAreProvisional: chaptersAreProvisional,
            startChapterIndex: safeStartChapterIndex,
            startCharPosition: startCharPosition,
            startScrollPosition: startScrollPosition,
          ),
        ),
      );
      if (mounted) await _refreshReadingProgress();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('打开阅读失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _isOpeningReading = false);
    }
  }

  Future<void> _refreshReadingProgress() async {
    final progress = await context.read<ReadingProvider>().loadProgress(_novel);
    if (!mounted || progress == null) return;
    setState(() {
      _readingProgress = progress;
      _novel = _novel.copyWith(
        currentChapterIndex: progress.chapterIndex,
        lastReadAt: DateTime.now(),
      );
    });
  }

  void _handleCommentSummaryLoaded(InteractionCommentSummary summary) {
    final rating = summary.ratingAvg;
    if (!mounted || _commentRatingAvg == rating) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _commentRatingAvg == rating) return;
      setState(() => _commentRatingAvg = rating);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bookshelfProvider = context.watch<BookshelfProvider>();
    final isOnShelf = bookshelfProvider.isOnShelf(_novel.id);

    return Scaffold(
      backgroundColor: AppTokens.canvasColor(context),
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverAppBar(
              expandedHeight: ImmersiveDetailHeader.expandedHeight,
              pinned: true,
              flexibleSpace: FlexibleSpaceBar(
                background: _buildReferenceHeaderSection(),
              ),
              backgroundColor: const Color(0xFF101827),
              foregroundColor: Colors.white,
              elevation: 0,
              scrolledUnderElevation: 0,
              actions: [
                IconButton(
                  icon: Icon(
                    isOnShelf ? Icons.bookmark : Icons.bookmark_border,
                    color: isOnShelf ? AppTokens.reward : null,
                  ),
                  onPressed: _toggleBookshelf,
                ),
              ],
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabBarDelegate(
                TabBar(
                  controller: _tabController,
                  tabs: const [
                    Tab(text: '详情'),
                    Tab(text: '目录'),
                  ],
                ),
              ),
            ),
          ];
        },
        body: TabBarView(
          controller: _tabController,
          children: [_buildDetailTab(), _buildChapterTab()],
        ),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildReferenceHeaderSection() {
    final chapterCount = _chapters.isNotEmpty
        ? _chapters.length
        : (_novel.totalChapters > 0
              ? _novel.totalChapters
              : _novel.chapterCount);
    final displayRating =
        _commentRatingAvg ?? (_novel.rating > 0 ? _novel.rating : null);
    final rating = displayRating == null
        ? '暂无'
        : displayRating.toStringAsFixed(
            displayRating.truncateToDouble() == displayRating ? 0 : 1,
          );
    final author = _novel.author.isNotEmpty ? _novel.author : '未知作者';
    final source = _novel.sourceName.isNotEmpty
        ? _novel.sourceName
        : (_novel.isLocal ? '本地书籍' : '在线书源');
    final progressValue = _readingProgress == null
        ? '未读'
        : '第${_readingProgress!.chapterIndex + 1}章';

    return ImmersiveDetailHeader(
      title: _novel.title,
      subtitle: author,
      meta: source,
      cover: BookCoverWidget.fill(novel: _novel),
      backdrop: BookCoverWidget.fill(novel: _novel),
      gradientColors: const [Color(0xFF101827), Color(0xFF18243A)],
      badges: [
        const ImmersiveDetailBadge(
          icon: Icons.local_fire_department_rounded,
          label: '荣誉榜 NO.1',
          color: AppTokens.reward,
        ),
        ImmersiveDetailBadge(
          icon: _novel.status == '已完结'
              ? Icons.verified_rounded
              : Icons.auto_awesome_rounded,
          label: _novel.status.isEmpty ? '连载中' : _novel.status,
          color: _novel.status == '已完结' ? AppTokens.success : AppTokens.reward,
        ),
        ImmersiveDetailBadge(
          icon: Icons.source_outlined,
          label: source,
          color: Colors.white,
        ),
      ],
      metrics: [
        ImmersiveDetailMetric(value: rating, label: '评分'),
        ImmersiveDetailMetric(
          value: chapterCount > 0 ? '$chapterCount' : '-',
          label: '章节',
        ),
        ImmersiveDetailMetric(value: progressValue, label: '阅读进度'),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildHeaderSection() {
    final chapterCount = _chapters.isNotEmpty
        ? _chapters.length
        : (_novel.totalChapters > 0
              ? _novel.totalChapters
              : _novel.chapterCount);
    final rating = _novel.rating > 0 ? _novel.rating.toStringAsFixed(1) : '暂无';
    final author = _novel.author.isNotEmpty ? _novel.author : '未知作者';
    final source = _novel.sourceName.isNotEmpty
        ? _novel.sourceName
        : (_novel.isLocal ? '本地书籍' : '在线书源');
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF172033), Color(0xFF0E5ED7)],
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 72, 16, 94),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: 104,
                  height: 146,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 20,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: BookCoverWidget.fill(novel: _novel),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _novel.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          height: 1.12,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Text(
                        '$author · $source',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _ReferencePill(
                            icon: Icons.local_fire_department_rounded,
                            label: '荣耀榜 NO.1',
                            color: AppTokens.reward,
                          ),
                          _ReferencePill(
                            icon: Icons.auto_awesome_rounded,
                            label: _novel.status.isEmpty
                                ? '连载中'
                                : _novel.status,
                            color: AppTokens.brand,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: -36,
          top: 70,
          bottom: 18,
          child: Opacity(
            opacity: 0.18,
            child: SizedBox(
              width: 150,
              child: BookCoverWidget.fill(novel: _novel),
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 72, 16, 18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      width: 110,
                      height: 154,
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
                      child: BookCoverWidget(
                        novel: _novel,
                        width: 110,
                        height: 154,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            _novel.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              height: 1.12,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            _novel.author.isNotEmpty ? _novel.author : '未知作者',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _buildStatusChip(_novel.status),
                              _HeaderChip(
                                icon: Icons.source_outlined,
                                label: _novel.sourceName.isNotEmpty
                                    ? _novel.sourceName
                                    : '本地书籍',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    _HeaderMetric(value: rating, label: '评分'),
                    _HeaderMetric(
                      value: chapterCount > 0 ? '$chapterCount' : '-',
                      label: '章节',
                    ),
                    _HeaderMetric(
                      value: _readingProgress == null
                          ? '未读'
                          : '第${_readingProgress!.chapterIndex + 1}章',
                      label: '进度',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusChip(String status) {
    final color = status == '已完结' ? AppTokens.success : AppTokens.reward;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildDetailTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_readingProgress != null) ...[
            _ReadingProgressCard(
              progress: _readingProgress!,
              chapters: _chapters,
            ),
            const SizedBox(height: 12),
          ],
          AppSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '简介',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () => setState(
                    () => _showFullDescription = !_showFullDescription,
                  ),
                  child: Text(
                    _novel.description.isNotEmpty
                        ? (_showFullDescription
                              ? _novel.description
                              : '${_novel.description.characters.take(150)}...')
                        : '暂无简介',
                    style: TextStyle(
                      fontSize: 15,
                      color: AppTokens.secondaryText(context),
                      height: 1.68,
                    ),
                  ),
                ),
                if (_novel.description.length > 150)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _showFullDescription ? '收起' : '展开全部',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.primaryColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          CommentPreviewPanel(
            key: ValueKey(_commentPreviewVersion),
            title: '独立书评',
            targetType: 'novel',
            targetId: _novel.id,
            enableRating: true,
            onSummaryLoaded: _handleCommentSummaryLoaded,
            moreText: '更多书评',
            emptyText: '成为第一位留下书评的人',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CommentThreadScreen(
                    title: '${_novel.title} 点评',
                    targetType: 'novel',
                    targetId: _novel.id,
                    targetTitle: _novel.title,
                    enableRating: true,
                  ),
                ),
              );
              if (!mounted) return;
              setState(() => _commentPreviewVersion++);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChapterTab() {
    if (_isLoadingChapters) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_chapters.isEmpty && _novel.isLocal) {
      return const Center(
        child: Text(
          '本地书籍暂无目录',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    if (_chapters.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: AppTheme.textHint),
            const SizedBox(height: 12),
            const Text(
              '无法获取章节列表',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadChapters,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return ChapterListWidget(
      novel: _novel,
      chapters: _chapters,
      currentChapter: _novel.currentChapterIndex,
      onTap: (chapter) async {
        final selectedChapterIndex = _chapters.indexOf(chapter);
        if (selectedChapterIndex < 0) return;
        final canOpen = await _ensureNovelChapterUnlocked(selectedChapterIndex);
        if (!canOpen || !mounted) return;

        context.read<ReadingProvider>().setCurrentNovel(_novel);
        context.read<ReadingProvider>().setCurrentChapter(chapter);
        context.read<ReadingProvider>().setChapters(_chapters);
        final savedProgress = _readingProgress;
        final restoresSavedChapter =
            savedProgress != null &&
            savedProgress.chapterIndex == selectedChapterIndex;
        await Navigator.push(
          context,
          MaterialPageRoute(
            settings: const RouteSettings(name: ReadingScreen.routeName),
            builder: (_) => ReadingScreen(
              novel: _novel,
              chapters: _chapters,
              startChapterIndex: selectedChapterIndex,
              startCharPosition: restoresSavedChapter
                  ? savedProgress.charPosition
                  : 0,
              startScrollPosition: restoresSavedChapter
                  ? savedProgress.scrollPosition
                  : 0,
            ),
          ),
        );
        await _refreshReadingProgress();
      },
    );
  }

  Future<bool> _ensureNovelChapterUnlocked(int chapterIndex) {
    return ensureLoggedInForContent(
      context,
      allowed: chapterIndex < _guestChapterLimit,
      title: '登录后继续阅读',
      message: '未登录可试看小说前 10 章，登录后可继续阅读后续章节。',
    );
  }

  Future<void> _showFullBookDownload() async {
    if (_chapters.isEmpty && !_isLoadingChapters) await _loadChapters();
    if (!mounted) return;
    if (_chapters.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('章节目录还没有加载成功，请稍后重试')));
      return;
    }
    final provider = context.read<BookSourceProvider>();
    final currentIndex =
        (_readingProgress?.chapterIndex ?? _novel.currentChapterIndex)
            .clamp(0, _chapters.length - 1)
            .toInt();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: false,
      builder: (_) => NovelCacheSheet(
        novel: _novel,
        chapters: _chapters,
        currentChapterIndex: currentIndex,
        provider: provider,
        initialRange: NovelCacheBatchRange.full,
        canStart: (range) {
          final requiresLogin = range
              .chapterIndices(
                chapterCount: _chapters.length,
                startIndex: currentIndex,
              )
              .any((index) => index >= _guestChapterLimit);
          return ensureLoggedInForContent(
            context,
            allowed: !requiresLogin,
            title: '登录后下载整书',
            message: '登录后可下载试看范围之外的章节。',
          );
        },
      ),
    );
  }

  Widget _buildBottomBar() {
    final isOnShelf = context.watch<BookshelfProvider>().isOnShelf(_novel.id);
    final hasProgress =
        _readingProgress != null &&
        (_readingProgress!.chapterIndex > 0 ||
            _readingProgress!.charPosition > 0);
    final isBusy = _isLoadingChapters || _isOpeningReading;
    final actionLabel = isBusy ? '加载目录中' : (hasProgress ? '继续阅读' : '开始阅读');
    return BookDetailBottomBar(
      isOnShelf: isOnShelf,
      isBusy: isBusy,
      canDownload: !_novel.isLocal,
      actionLabel: actionLabel,
      onDownload: _showFullBookDownload,
      onToggleShelf: _toggleBookshelf,
      onOpenReading: _openReading,
    );
  }

  void _toggleBookshelf() async {
    if (context.read<BookshelfProvider>().isOnShelf(_novel.id)) {
      await context.read<BookshelfProvider>().removeFromBookshelf(_novel.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已移出书架')));
    } else {
      await context.read<BookshelfProvider>().addToBookshelf(_novel);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已加入书架')));
    }
  }
}

@visibleForTesting
class BookDetailBottomBar extends StatelessWidget {
  const BookDetailBottomBar({
    super.key,
    required this.isOnShelf,
    required this.isBusy,
    required this.canDownload,
    required this.actionLabel,
    required this.onDownload,
    required this.onToggleShelf,
    required this.onOpenReading,
  });

  final bool isOnShelf;
  final bool isBusy;
  final bool canDownload;
  final String actionLabel;
  final VoidCallback onDownload;
  final VoidCallback onToggleShelf;
  final VoidCallback onOpenReading;

  @override
  Widget build(BuildContext context) {
    final compactForLargeText =
        MediaQuery.textScalerOf(context).scale(1) >= 1.5;
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            SizedBox(
              width: compactForLargeText ? 48 : 82,
              height: 48,
              child: compactForLargeText
                  ? IconButton(
                      tooltip: '下载整书',
                      onPressed: isBusy || !canDownload ? null : onDownload,
                      icon: const Icon(Icons.download_for_offline_outlined),
                    )
                  : TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: isBusy || !canDownload ? null : onDownload,
                      icon: const Icon(
                        Icons.download_for_offline_outlined,
                        size: 18,
                      ),
                      label: const Text(
                        '下载整书',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: compactForLargeText ? 48 : 82,
              height: 48,
              child: compactForLargeText
                  ? IconButton(
                      tooltip: isOnShelf ? '移出书架' : '加入书架',
                      onPressed: onToggleShelf,
                      icon: Icon(
                        isOnShelf
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border,
                      ),
                    )
                  : TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: onToggleShelf,
                      icon: Icon(
                        isOnShelf
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border,
                        size: 18,
                      ),
                      label: Text(
                        isOnShelf ? '已在书架' : '加入书架',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 48,
                child: compactForLargeText
                    ? FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTokens.brand,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: isBusy ? null : onOpenReading,
                        child: Text(
                          actionLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      )
                    : FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTokens.brand,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: isBusy ? null : onOpenReading,
                        icon: const Icon(Icons.menu_book, size: 20),
                        label: Text(actionLabel),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferencePill extends StatelessWidget {
  const _ReferencePill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _ReferenceMetric extends StatelessWidget {
  const _ReferenceMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 19,
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

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 13),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 58,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
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
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadingProgressCard extends StatelessWidget {
  const _ReadingProgressCard({required this.progress, required this.chapters});

  final ReadingProgress progress;
  final List<Chapter> chapters;

  @override
  Widget build(BuildContext context) {
    final chapterTitle =
        chapters.elementAtOrNull(progress.chapterIndex)?.title ??
        '第${progress.chapterIndex + 1}章';
    final total = chapters.isEmpty ? 0 : chapters.length;
    final percent = total <= 0
        ? 0.0
        : ((progress.chapterIndex + 1) / total).clamp(0.0, 1.0).toDouble();

    return AppSurface(
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTokens.brandSoft,
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
            child: const Icon(
              Icons.history_rounded,
              color: AppTokens.brand,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '上次读到',
                  style: TextStyle(
                    color: AppTokens.secondaryText(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTokens.primaryText(context),
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (total > 0) ...[
                  const SizedBox(height: 9),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: percent,
                      minHeight: 5,
                      color: AppTokens.brand,
                      backgroundColor: AppTokens.brandSoft,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;

  _TabBarDelegate(this.tabBar);

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: AppTokens.cardColor(context),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppTokens.borderColor(context)),
          ),
        ),
        child: tabBar,
      ),
    );
  }

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  bool shouldRebuild(_TabBarDelegate oldDelegate) => false;
}
