import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/book_source_provider.dart';
import '../services/local_import_service.dart';
import '../models/novel.dart';
import '../widgets/book_cover_widget.dart';
import 'book_detail_screen.dart';
import 'search_screen.dart';
import 'book_source_manage_screen.dart';

class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({super.key});

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  final LocalImportService _importService = LocalImportService();
  final TextEditingController _bookshelfSearchController =
      TextEditingController();
  bool _isSearchingBookshelf = false;
  String _bookshelfQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      context.read<BookshelfProvider>().loadBookshelf();
      final sourceProvider = context.read<BookSourceProvider>();
      await sourceProvider.loadSources();
      if (!mounted) return;
      if (sourceProvider.sources.isEmpty) {
        sourceProvider.addDefaultSources();
      }
    });
  }

  Future<void> _importLocalFile() async {
    final result = await _importService.importLocalFile();
    if (result != null && mounted) {
      await context.read<BookshelfProvider>().importLocalNovel(result);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导入成功'), duration: Duration(seconds: 2)),
        );
      }
    }
  }

  @override
  void dispose() {
    _bookshelfSearchController.dispose();
    super.dispose();
  }

  void _openBookshelfSearch() {
    setState(() {
      _isSearchingBookshelf = true;
    });
  }

  void _closeBookshelfSearch() {
    setState(() {
      _isSearchingBookshelf = false;
      _bookshelfQuery = '';
      _bookshelfSearchController.clear();
    });
  }

  void _clearBookshelfSearch() {
    setState(() {
      _bookshelfQuery = '';
      _bookshelfSearchController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isSearchingBookshelf
            ? TextField(
                controller: _bookshelfSearchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: '搜索书架',
                  border: InputBorder.none,
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 18),
                onChanged: (value) {
                  setState(() {
                    _bookshelfQuery = value;
                  });
                },
              )
            : const Text('我的书架'),
        actions: _isSearchingBookshelf
            ? [
                if (_bookshelfQuery.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: '清空',
                    onPressed: _clearBookshelfSearch,
                  ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭搜索',
                  onPressed: _closeBookshelfSearch,
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '搜索书架',
                  onPressed: _openBookshelfSearch,
                ),
                IconButton(
                  icon: const Icon(Icons.language),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BookSourceManageScreen(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.file_upload_outlined),
                  onPressed: _importLocalFile,
                ),
              ],
      ),
      body: Consumer<BookshelfProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (provider.books.isEmpty) {
            return _buildEmptyState();
          }

          return _buildBookshelfGrid(provider);
        },
      ),
    );
  }

  List<Novel> _filteredBooks(List<Novel> books) {
    final query = _bookshelfQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return books;
    }

    return books.where((book) {
      final shelfLabel = book.isLocal ? '本地书籍' : book.sourceName;
      return book.title.toLowerCase().contains(query) ||
          book.author.toLowerCase().contains(query) ||
          shelfLabel.toLowerCase().contains(query);
    }).toList();
  }

  Widget _buildEmptySearchResult() {
    final query = _bookshelfQuery.trim();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(Icons.search_off, size: 56, color: AppTheme.textHint),
        const SizedBox(height: 16),
        Text(
          '书架中没有找到“$query”',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(50),
            ),
            child: const Icon(
              Icons.menu_book,
              size: 48,
              color: AppTheme.primaryColor,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '书架空空如也',
            style: TextStyle(fontSize: 17, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          const Text(
            '点击右下角按钮导入本地小说',
            style: TextStyle(fontSize: 14, color: AppTheme.textHint),
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildActionButton(
                icon: Icons.file_upload_outlined,
                label: '本地导入',
                onTap: _importLocalFile,
              ),
              const SizedBox(width: 20),
              _buildActionButton(
                icon: Icons.language,
                label: '全网搜索',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: AppTheme.primaryColor, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildBookshelfGrid(BookshelfProvider provider) {
    final books = _filteredBooks(provider.books);
    final query = _bookshelfQuery.trim();

    return RefreshIndicator(
      onRefresh: () => provider.loadBookshelf(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Row(
                children: [
                  Text(
                    query.isEmpty
                        ? '共 ${provider.bookshelfCount} 本'
                        : '找到 ${books.length} 本',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.sort, size: 16, color: AppTheme.textHint),
                  const SizedBox(width: 4),
                  const Text(
                    '最近阅读',
                    style: TextStyle(fontSize: 13, color: AppTheme.textHint),
                  ),
                ],
              ),
            ),
            Expanded(
              child: books.isEmpty
                  ? _buildEmptySearchResult()
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 0.54,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                      itemCount: books.length,
                      itemBuilder: (context, index) {
                        final novel = books[index];
                        return _buildBookItem(novel);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookItem(Novel novel) {
    final provider = context.read<BookshelfProvider>();
    final progress = provider.progressFor(novel.id);
    final chapterIndex = progress?.chapterIndex ?? novel.currentChapterIndex;
    final hasProgress =
        progress != null &&
        (progress.chapterIndex > 0 || progress.charPosition > 0);
    final progressValue = novel.totalChapters > 0
        ? ((chapterIndex + 1) / novel.totalChapters).clamp(0.0, 1.0).toDouble()
        : null;
    final progressText = hasProgress ? '读至第 ${chapterIndex + 1} 章' : '未读';

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => BookDetailScreen(novel: novel)),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: BookCoverWidget(
                    novel: novel,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 7),
          if (progressValue != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progressValue,
                minHeight: 3,
                backgroundColor: AppTheme.dividerColor.withValues(alpha: 0.5),
                color: AppTheme.primaryColor,
              ),
            )
          else
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: AppTheme.dividerColor.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: Text(
              novel.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: double.infinity,
            child: Text(
              novel.author.isNotEmpty
                  ? novel.author
                  : novel.isLocal
                  ? '本地书籍'
                  : novel.sourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppTheme.textHint),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: double.infinity,
            child: Text(
              progressText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 10,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
