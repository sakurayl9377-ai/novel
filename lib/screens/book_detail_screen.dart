import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../models/novel.dart';
import '../models/chapter.dart';
import '../models/reading_progress.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/book_source_provider.dart';
import '../providers/reading_provider.dart';
import '../widgets/book_cover_widget.dart';
import '../widgets/chapter_list_widget.dart';
import 'reading_screen.dart';

class BookDetailScreen extends StatefulWidget {
  final Novel novel;

  const BookDetailScreen({super.key, required this.novel});

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
  ReadingProgress? _readingProgress;

  @override
  void initState() {
    super.initState();
    _novel = widget.novel;
    _tabController = TabController(length: 2, vsync: this);
    _loadChapters();
  }

  Future<void> _loadChapters() async {
    setState(() => _isLoadingChapters = true);
    final sourceProvider = context.read<BookSourceProvider>();
    final bookshelfProvider = context.read<BookshelfProvider>();
    final savedProgress = await context.read<ReadingProvider>().loadProgress(
      _novel.id,
    );
    final detailedNovel = _novel.isLocal
        ? _novel
        : await sourceProvider.getBookDetail(_novel);
    final chapters = await sourceProvider.getChapterList(detailedNovel);
    if (mounted) {
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
        bookshelfProvider.updateNovel(updatedNovel);
      }
    }
  }

  Future<void> _openReading() async {
    if (_isOpeningReading) return;
    setState(() => _isOpeningReading = true);
    if (_chapters.isEmpty && !_novel.isLocal) {
      await _loadChapters();
    }
    if (!mounted) return;
    if (_chapters.isEmpty) {
      setState(() => _isOpeningReading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('章节目录还没有加载成功，请稍后重试')));
      return;
    }

    final readingProvider = context.read<ReadingProvider>();
    final savedProgress = await readingProvider.loadProgress(_novel.id);
    if (!mounted) return;
    final startChapterIndex =
        savedProgress?.chapterIndex ?? _novel.currentChapterIndex;
    final startCharPosition = savedProgress?.charPosition ?? 0;
    final startScrollPosition = savedProgress?.scrollPosition ?? 0.0;

    readingProvider.setCurrentNovel(_novel);
    if (_chapters.isNotEmpty) {
      final safeChapterIndex = startChapterIndex
          .clamp(0, _chapters.length - 1)
          .toInt();
      readingProvider.setCurrentChapter(_chapters[safeChapterIndex]);
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: ReadingScreen.routeName),
        builder: (_) => ReadingScreen(
          novel: _novel,
          chapters: _chapters,
          startChapterIndex: startChapterIndex,
          startCharPosition: startCharPosition,
          startScrollPosition: startScrollPosition,
        ),
      ),
    );
    if (mounted) {
      setState(() => _isOpeningReading = false);
    }
    await _refreshReadingProgress();
  }

  Future<void> _refreshReadingProgress() async {
    final progress = await context.read<ReadingProvider>().loadProgress(
      _novel.id,
    );
    if (!mounted || progress == null) return;
    setState(() {
      _readingProgress = progress;
      _novel = _novel.copyWith(
        currentChapterIndex: progress.chapterIndex,
        lastReadAt: DateTime.now(),
      );
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
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverAppBar(
              expandedHeight: 260,
              pinned: true,
              flexibleSpace: FlexibleSpaceBar(
                background: _buildHeaderSection(),
              ),
              backgroundColor: Colors.white,
              foregroundColor: AppTheme.textPrimary,
              elevation: 0.5,
              actions: [
                IconButton(
                  icon: Icon(
                    isOnShelf ? Icons.bookmark : Icons.bookmark_border,
                    color: isOnShelf ? AppTheme.accentColor : null,
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

  Widget _buildHeaderSection() {
    return Container(
      padding: const EdgeInsets.only(top: 80, left: 16, right: 16, bottom: 16),
      color: Colors.white,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BookCoverWidget(novel: _novel, width: 100, height: 140),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  _novel.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '作者：${_novel.author.isNotEmpty ? _novel.author : "未知"}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _buildStatusChip(_novel.status),
                    const SizedBox(width: 8),
                    Text(
                      _novel.sourceName.isNotEmpty
                          ? '来源：${_novel.sourceName}'
                          : '本地书籍',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textHint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (_novel.rating > 0)
                  Row(
                    children: [
                      ...List.generate(5, (i) {
                        return Icon(
                          i < _novel.rating.floor()
                              ? Icons.star
                              : Icons.star_border,
                          size: 14,
                          color: Colors.amber,
                        );
                      }),
                      const SizedBox(width: 4),
                      Text(
                        _novel.rating.toString(),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.amber,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    final color = status == '已完结' ? Colors.green : AppTheme.accentColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(status, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Widget _buildDetailTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '简介',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () =>
                setState(() => _showFullDescription = !_showFullDescription),
            child: Text(
              _novel.description.isNotEmpty
                  ? (_showFullDescription
                        ? _novel.description
                        : '${_novel.description.characters.take(150)}...')
                  : '暂无简介',
              style: const TextStyle(
                fontSize: 15,
                color: AppTheme.textSecondary,
                height: 1.7,
              ),
            ),
          ),
          if (_novel.description.length > 150)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _showFullDescription ? '收起' : '展开全部',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.primaryColor,
                ),
              ),
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
        final savedProgress = await context
            .read<ReadingProvider>()
            .loadProgress(_novel.id);
        if (!mounted) return;
        final shouldResume =
            savedProgress != null &&
            savedProgress.chapterIndex == selectedChapterIndex;

        context.read<ReadingProvider>().setCurrentNovel(_novel);
        context.read<ReadingProvider>().setCurrentChapter(chapter);
        context.read<ReadingProvider>().setChapters(_chapters);
        await Navigator.push(
          context,
          MaterialPageRoute(
            settings: const RouteSettings(name: ReadingScreen.routeName),
            builder: (_) => ReadingScreen(
              novel: _novel,
              chapters: _chapters,
              startChapterIndex: selectedChapterIndex,
              startCharPosition: shouldResume ? savedProgress.charPosition : 0,
              startScrollPosition: shouldResume
                  ? savedProgress.scrollPosition
                  : 0,
            ),
          ),
        );
        await _refreshReadingProgress();
      },
    );
  }

  Widget _buildBottomBar() {
    final hasProgress =
        _readingProgress != null &&
        (_readingProgress!.chapterIndex > 0 ||
            _readingProgress!.charPosition > 0);
    final isBusy = _isLoadingChapters || _isOpeningReading;
    final actionLabel = isBusy ? '加载目录中' : (hasProgress ? '继续阅读' : '开始阅读');

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
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: isBusy ? null : _openReading,
                  icon: const Icon(Icons.menu_book, size: 20),
                  label: Text(actionLabel),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;

  _TabBarDelegate(this.tabBar);

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(color: Colors.white, child: tabBar);
  }

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  bool shouldRebuild(_TabBarDelegate oldDelegate) => false;
}
