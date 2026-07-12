import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/anime.dart';
import '../models/anime_watch_history.dart';
import '../models/local_library.dart';
import '../models/manga_read_history.dart';
import '../services/storage_service.dart';
import '../services/download_manager_service.dart';
import 'anime_detail_screen.dart';
import 'anime_player_screen.dart';
import 'anime_screen.dart';
import 'manga_detail_screen.dart';
import 'manga_screen.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final StorageService _storage = StorageService();

  List<FavoriteFolder> _folders = const [];
  List<FavoriteItem> _items = const [];
  Map<String, _LibraryProgress> _progressByItemKey = const {};
  String _folderId = defaultFavoriteFolderId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final results = await Future.wait([
      _storage.getFavoriteFolders(),
      _storage.getFavoriteItems(),
      _storage.getAnimeWatchHistory(),
      _storage.getMangaReadHistory(),
    ]);
    final folders = results[0] as List<FavoriteFolder>;
    final items = results[1] as List<FavoriteItem>;
    final animeHistories = results[2] as List<AnimeWatchHistory>;
    final mangaHistories = results[3] as List<MangaReadHistory>;
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _items = items;
      _progressByItemKey = _buildProgressMap(
        animeHistories: animeHistories,
        mangaHistories: mangaHistories,
      );
      if (_folders.every((item) => item.id != _folderId)) {
        _folderId = defaultFavoriteFolderId;
      }
      _isLoading = false;
    });
  }

  Map<String, _LibraryProgress> _buildProgressMap({
    required List<AnimeWatchHistory> animeHistories,
    required List<MangaReadHistory> mangaHistories,
  }) {
    return {
      for (final history in animeHistories)
        _libraryProgressKey(
          LibraryItemType.anime,
          history.animeId.toString(),
        ): _LibraryProgress(
          label: _formatAnimeProgress(history),
          value: history.durationMs > 0 ? history.progress : null,
        ),
      for (final history in mangaHistories)
        _libraryProgressKey(
          LibraryItemType.manga,
          history.mangaId,
        ): _LibraryProgress(
          label: _formatMangaProgress(history),
          value: history.progress,
        ),
    };
  }

  Future<void> _createFolder() async {
    final name = await _promptName(title: '新建收藏夹', hintText: '收藏夹名称');
    if (name == null) return;
    final folder = await _storage.createFavoriteFolder(name);
    if (!mounted) return;
    setState(() => _folderId = folder.id);
    await _reload();
  }

  Future<void> _renameFolder(FavoriteFolder folder) async {
    final name = await _promptName(
      title: '重命名收藏夹',
      hintText: '收藏夹名称',
      initialValue: folder.name,
    );
    if (name == null) return;
    await _storage.renameFavoriteFolder(folder.id, name);
    if (mounted) await _reload();
  }

  Future<void> _deleteFolder(FavoriteFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除收藏夹'),
        content: Text('收藏夹内条目会移动到默认收藏，确定删除「${folder.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _storage.deleteFavoriteFolder(folder.id);
    if (!mounted) return;
    setState(() => _folderId = defaultFavoriteFolderId);
    await _reload();
  }

  Future<String?> _promptName({
    required String title,
    required String hintText,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hintText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) return null;
    return result.trim();
  }

  Future<void> _removeItem(FavoriteItem item) async {
    await _storage.removeFavoriteItem(item.type, item.itemId);
    if (mounted) await _reload();
  }

  void _openItem(FavoriteItem item) {
    if (item.type == LibraryItemType.anime) {
      final id = int.tryParse(item.itemId) ?? 0;
      if (id <= 0) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AnimeDetailScreen(animeId: id, title: item.title),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            MangaDetailScreen(mangaId: item.itemId, title: item.title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleItems = _items
        .where((item) => item.folderId == _folderId)
        .toList();
    final currentFolder = _folders.firstWhere(
      (item) => item.id == _folderId,
      orElse: () => const FavoriteFolder(
        id: defaultFavoriteFolderId,
        name: '默认收藏',
        createdAtMs: 0,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
        actions: [
          IconButton(
            tooltip: '新建收藏夹',
            onPressed: _createFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          if (_folderId != defaultFavoriteFolderId)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'rename') _renameFolder(currentFolder);
                if (value == 'delete') _deleteFolder(currentFolder);
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'delete', child: Text('删除收藏夹')),
              ],
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                SizedBox(
                  height: 52,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    scrollDirection: Axis.horizontal,
                    itemCount: _folders.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final folder = _folders[index];
                      return ChoiceChip(
                        label: Text(folder.name),
                        selected: folder.id == _folderId,
                        onSelected: (_) =>
                            setState(() => _folderId = folder.id),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _reload,
                    child: visibleItems.isEmpty
                        ? _EmptyLibraryState(
                            icon: Icons.star_border_rounded,
                            text: '这个收藏夹还没有内容',
                          )
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            itemCount: visibleItems.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = visibleItems[index];
                              final progress =
                                  _progressByItemKey[_libraryProgressKey(
                                    item.type,
                                    item.itemId,
                                  )];
                              return _LibraryItemTile(
                                title: item.title,
                                subtitle: item.subtitle,
                                progressLabel: progress?.label,
                                progressValue: progress?.value,
                                coverUrl: item.coverUrl,
                                type: item.type,
                                onTap: () => _openItem(item),
                                trailing: IconButton(
                                  tooltip: '取消收藏',
                                  onPressed: () => _removeItem(item),
                                  icon: const Icon(Icons.star_rounded),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final DownloadManagerService _manager = DownloadManagerService.instance;

  @override
  void initState() {
    super.initState();
    _manager.init();
  }

  Future<void> _reload() async {
    await _manager.init();
    if (mounted) setState(() {});
  }

  Future<void> _deleteItem(DownloadItem item) async {
    await _manager.delete(item.id);
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空下载记录'),
        content: const Text('会删除下载记录和已缓存的离线视频文件，确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _manager.clearAll();
  }

  Future<void> _openItem(DownloadItem item) async {
    if (item.type == LibraryItemType.anime) {
      final id = int.tryParse(item.itemId) ?? 0;
      if (id <= 0) return;
      if (!item.isPlayable) {
        if (item.status == 'paused' || item.status == 'failed') {
          _manager.resume(item.id);
          _showMessage(item.status == 'failed' ? '已重新开始下载' : '已继续下载');
        } else {
          _showMessage(_statusLabel(item));
        }
        return;
      }
      if (!await _manager.validatePlayable(item)) {
        await _manager.resume(item.id);
        if (mounted) _showMessage('离线文件不完整，已重新加入下载队列');
        return;
      }
      if (!mounted) return;
      final episode = AnimeEpisode(
        title: item.episodeTitle,
        url: Uri.file(item.localPath).toString(),
      );
      final source = AnimePlaySource(
        name: item.sourceName.isEmpty ? '离线缓存' : '离线 · ${item.sourceName}',
        episodes: [episode],
      );
      final anime = Anime(
        id: id,
        title: item.title,
        coverUrl: item.coverUrl,
        category: item.subtitle,
        playSources: [source],
      );
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AnimePlayerScreen(
            anime: anime,
            source: source,
            episode: episode,
            resumeFromHistory: true,
            offlineOriginalUrl: item.episodeUrl,
          ),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            MangaDetailScreen(mangaId: item.itemId, title: item.title),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleDownload(DownloadItem item) {
    if (item.status == 'downloading' || item.status == 'queued') {
      return _manager.pause(item.id);
    }
    return _manager.resume(item.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的下载'),
        actions: [
          IconButton(
            tooltip: '清空记录',
            onPressed: _clearAll,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _manager,
        builder: (context, _) {
          final items = _manager.items;
          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: _reload,
              child: _EmptyLibraryState(
                icon: Icons.file_download_outlined,
                text: '暂无下载内容',
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                final detail = item.type == LibraryItemType.anime
                    ? '${item.sourceName} · ${item.episodeTitle}'
                    : '${item.chapterTitle} · ${item.cachedCount}/${item.totalCount} 张';
                return _LibraryItemTile(
                  title: item.title,
                  subtitle: detail,
                  progressLabel: _downloadProgressLabel(item),
                  progressValue: item.progress,
                  coverUrl: item.coverUrl,
                  type: item.type,
                  onTap: () => _openItem(item),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.type == LibraryItemType.anime &&
                          item.status != 'done')
                        IconButton(
                          tooltip:
                              item.status == 'downloading' ||
                                  item.status == 'queued'
                              ? '暂停'
                              : '继续',
                          onPressed: () => _toggleDownload(item),
                          icon: Icon(
                            item.status == 'downloading' ||
                                    item.status == 'queued'
                                ? Icons.pause_circle_outline
                                : Icons.play_circle_outline,
                          ),
                        ),
                      IconButton(
                        tooltip: '删除下载',
                        onPressed: () => _deleteItem(item),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  String _downloadProgressLabel(DownloadItem item) {
    final status = _statusLabel(item);
    final count = item.totalCount > 1
        ? ' · ${item.cachedCount}/${item.totalCount} 分片'
        : '';
    final bytes = item.downloadedBytes > 0
        ? ' · ${_formatBytes(item.downloadedBytes)}${item.totalBytes > 0 ? ' / ${_formatBytes(item.totalBytes)}' : ''}'
        : '';
    final error = item.errorMessage.isEmpty ? '' : ' · ${item.errorMessage}';
    return '$status$count$bytes$error';
  }

  String _statusLabel(DownloadItem item) {
    switch (item.status) {
      case 'queued':
        return '排队中';
      case 'downloading':
        return '下载中';
      case 'paused':
        return '已暂停';
      case 'failed':
        return '下载失败';
      case 'done':
        return '已完成，可离线播放';
      default:
        return item.status.isEmpty ? '等待下载' : item.status;
    }
  }

  String _formatBytes(int value) {
    var bytes = value.toDouble();
    const units = ['B', 'KB', 'MB', 'GB'];
    var index = 0;
    while (bytes >= 1024 && index < units.length - 1) {
      bytes /= 1024;
      index += 1;
    }
    return '${bytes >= 10 || index == 0 ? bytes.toStringAsFixed(0) : bytes.toStringAsFixed(1)} ${units[index]}';
  }
}

class _LibraryItemTile extends StatelessWidget {
  const _LibraryItemTile({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.type,
    required this.onTap,
    required this.trailing,
    this.progressLabel,
    this.progressValue,
  });

  final String title;
  final String subtitle;
  final String? progressLabel;
  final double? progressValue;
  final String coverUrl;
  final LibraryItemType type;
  final VoidCallback onTap;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 68,
                height: 96,
                child: type == LibraryItemType.anime
                    ? AnimeCover(imageUrl: coverUrl)
                    : MangaCover(imageUrl: coverUrl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle.isEmpty
                        ? (type == LibraryItemType.anime ? '动漫' : '漫画')
                        : subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (progressLabel?.isNotEmpty == true) ...[
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(
                          type == LibraryItemType.anime
                              ? Icons.play_circle_outline_rounded
                              : Icons.history_rounded,
                          size: 14,
                          color: AppTheme.primaryColor,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            progressLabel!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.primaryColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (progressValue != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progressValue!.clamp(0, 1).toDouble(),
                          minHeight: 4,
                          color: AppTheme.primaryColor,
                          backgroundColor: AppTheme.primaryColor.withValues(
                            alpha: 0.12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _LibraryProgress {
  const _LibraryProgress({required this.label, required this.value});

  final String label;
  final double? value;
}

String _libraryProgressKey(LibraryItemType type, String itemId) {
  return '${type.value}:$itemId';
}

String _formatAnimeProgress(AnimeWatchHistory history) {
  final episode = history.episodeTitle.isEmpty ? '当前剧集' : history.episodeTitle;
  if (history.durationMs <= 0) return '看到 $episode';
  return '看到 $episode · ${_formatClock(history.position)} / ${_formatClock(history.duration)}';
}

String _formatMangaProgress(MangaReadHistory history) {
  final chapter = history.chapterTitle.isEmpty ? '当前章节' : history.chapterTitle;
  final percent = (history.progress * 100).clamp(0, 100).round();
  return '读到 $chapter · $percent%';
}

String _formatClock(Duration value) {
  final totalSeconds = value.inSeconds;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  final hours = totalSeconds ~/ 3600;
  if (hours <= 0) return '$minutes:$seconds';
  final hourText = hours.toString().padLeft(2, '0');
  final minuteText = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
  return '$hourText:$minuteText:$seconds';
}

class _EmptyLibraryState extends StatelessWidget {
  const _EmptyLibraryState({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.24),
        Icon(icon, size: 64, color: AppTheme.textHint),
        const SizedBox(height: 14),
        Center(
          child: Text(
            text,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 15),
          ),
        ),
      ],
    );
  }
}
