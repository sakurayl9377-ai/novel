import 'dart:async';

import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/manga.dart';
import '../models/manga_read_history.dart';
import '../services/manga_service.dart';
import '../services/storage_service.dart';
import 'manga_reader_screen.dart';
import 'manga_screen.dart';

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

  Future<void> _readChapter(
    Manga manga,
    MangaChapter chapter,
    int index, {
    double initialScrollOffset = 0,
    double? initialScrollProgress,
    int initialPageIndex = 0,
    double initialPageOffsetRatio = 0,
  }) async {
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
      appBar: AppBar(title: Text(manga?.title ?? widget.title ?? '漫画详情')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? _buildError()
          : manga == null
          ? _buildError()
          : _buildDetail(manga, isNight),
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

  Widget _buildDetail(Manga manga, bool isNight) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildInfo(manga, isNight)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _ChapterHeaderDelegate(
            color: isNight ? AppTheme.nightBackground : Colors.white,
            child: _buildChapterHeader(manga, isNight),
          ),
        ),
        if (manga.chapters.isEmpty)
          const SliverFillRemaining(child: Center(child: Text('暂无章节')))
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 2.35,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final chapter = manga.chapters[index];
                final selected = chapter.url == _history?.chapterUrl;
                return OutlinedButton(
                  onPressed: () => _readChapter(manga, chapter, index),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    backgroundColor: selected
                        ? AppTheme.primaryColor.withValues(alpha: 0.12)
                        : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected ? AppTheme.primaryColor : null,
                    ),
                  ),
                );
              }, childCount: manga.chapters.length),
            ),
          ),
      ],
    );
  }

  Widget _buildInfo(Manga manga, bool isNight) {
    final meta = [
      manga.status,
      manga.author.isNotEmpty ? '作者：${manga.author}' : '',
      manga.latestChapter,
    ].where((value) => value.isNotEmpty).join(' / ');
    final history = _history;

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
                  child: MangaCover(imageUrl: manga.coverUrl),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manga.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isNight ? Colors.white : AppTheme.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
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
                    ],
                    if (history != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        '读至 ${history.chapterTitle}',
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
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: manga.chapters.isEmpty
                          ? null
                          : () => _readFirstOrResume(manga),
                      icon: Icon(
                        history == null
                            ? Icons.menu_book_outlined
                            : Icons.history,
                      ),
                      label: Text(history == null ? '开始阅读' : '继续阅读'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (manga.description.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              manga.description,
              style: TextStyle(
                color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
                fontSize: 13,
                height: 1.55,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChapterHeader(Manga manga, bool isNight) {
    return Material(
      color: isNight ? AppTheme.nightBackground : Colors.white,
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
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, color: AppTheme.textHint),
          ],
        ),
      ),
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
