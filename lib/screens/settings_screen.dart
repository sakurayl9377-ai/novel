import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../config/theme.dart';
import '../models/anime_watch_history.dart';
import '../models/manga_read_history.dart';
import '../models/tts_settings.dart';
import '../providers/reading_provider.dart';
import '../providers/tts_provider.dart';
import '../services/app_update_service.dart';
import '../services/storage_service.dart';
import 'anime_player_screen.dart';
import 'anime_screen.dart';
import 'bookshelf_screen.dart';
import 'manga_reader_screen.dart';
import 'manga_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AppUpdateService _updateService = AppUpdateService();

  bool _isCheckingUpdate = false;
  bool _isDownloadingUpdate = false;
  double? _downloadProgress;
  String _appVersionName = '2.0.4';

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _appVersionName = packageInfo.version);
    } catch (_) {
      // Keep the bundled fallback if package metadata is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.primaryColor, AppTheme.primaryDark],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white24,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Text(
                    '凡王之血，必以剑终！',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _buildSection('功能'),
          _buildMenuItem(
            icon: Icons.menu_book_outlined,
            title: '我的书架',
            subtitle: '管理已加入和本地导入的小说',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BookshelfScreen()),
              );
            },
          ),
          _buildMenuItem(
            icon: Icons.history,
            title: '动漫播放历史',
            subtitle: '本地保存最近一个月',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AnimeHistoryScreen()),
              );
            },
          ),
          _buildMenuItem(
            icon: Icons.auto_stories_outlined,
            title: '漫画阅读历史',
            subtitle: '本地保存最近一个月',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MangaHistoryScreen()),
              );
            },
          ),
          Consumer<TtsProvider>(
            builder: (context, ttsProvider, _) => _buildMenuItem(
              icon: Icons.record_voice_over_outlined,
              title: '语音朗读',
              subtitle: ttsProvider.settings.useIflytek
                  ? '科大讯飞 · ${ttsProvider.settings.iflytekVoiceLabel}'
                  : '系统 TTS',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TtsSettingsScreen()),
                );
              },
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          _buildSection('阅读设置'),
          _buildMenuItem(
            icon: Icons.text_fields,
            title: '默认字体',
            subtitle: '系统默认',
            onTap: () {},
          ),
          Consumer<ReadingProvider>(
            builder: (context, readingProvider, _) => _buildMenuItem(
              icon: Icons.brightness_6,
              title: '深色模式',
              trailing: IgnorePointer(
                child: Switch(
                  value: readingProvider.settings.nightMode,
                  onChanged: readingProvider.setNightMode,
                  activeTrackColor: AppTheme.primaryColor.withValues(
                    alpha: 0.5,
                  ),
                ),
              ),
              onTap: () => readingProvider.setNightMode(
                !readingProvider.settings.nightMode,
              ),
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          _buildSection('缓存与存储'),
          _buildMenuItem(
            icon: Icons.delete_outline,
            title: '清除缓存',
            subtitle: '清除已缓存章节内容',
            onTap: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('清除缓存'),
                  content: const Text('将清除所有缓存的章节内容，阅读进度不受影响。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('确认清除'),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(indent: 16, endIndent: 16),
          _buildSection('关于'),
          _buildMenuItem(
            icon: Icons.info_outline,
            title: '关于应用',
            subtitle: 'Sakura v$_appVersionName',
            onTap: () {},
          ),
          _buildMenuItem(
            icon: Icons.history_edu_outlined,
            title: '更新日志',
            subtitle: '查看每个版本更新内容',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UpdateLogScreen()),
              );
            },
          ),
          _buildMenuItem(
            icon: Icons.system_update_alt_outlined,
            title: _isDownloadingUpdate ? '正在下载更新' : '检查更新',
            subtitle: _updateSubtitle,
            trailing: _isCheckingUpdate || _isDownloadingUpdate
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      value: _downloadProgress,
                    ),
                  )
                : null,
            onTap: _isCheckingUpdate || _isDownloadingUpdate
                ? null
                : _checkForUpdate,
          ),
          const SizedBox(height: 32),
          Center(
            child: Text(
              'Sakura v$_appVersionName',
              style: const TextStyle(fontSize: 12, color: AppTheme.textHint),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildSection(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, size: 22, color: AppTheme.textSecondary),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: const TextStyle(fontSize: 12, color: AppTheme.textHint),
            )
          : null,
      trailing:
          trailing ??
          const Icon(Icons.chevron_right, size: 20, color: AppTheme.textHint),
      onTap: onTap,
    );
  }

  String get _updateSubtitle {
    if (_isDownloadingUpdate) {
      final progress = _downloadProgress;
      if (progress != null) {
        return '已下载 ${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
      }
      return '正在下载 APK';
    }
    if (_isCheckingUpdate) return '正在检查服务器版本';
    return '检查是否有新版本';
  }

  Future<void> _checkForUpdate() async {
    if (_isCheckingUpdate || _isDownloadingUpdate) return;
    setState(() => _isCheckingUpdate = true);

    AppUpdateCheckResult result;
    try {
      result = await _updateService.checkForUpdate();
    } catch (error) {
      if (mounted) {
        _showMessage('检查更新失败：${_friendlyUpdateError(error)}');
      }
      return;
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }

    if (!mounted) return;
    final update = result.update;
    if (!result.hasUpdate || update == null) {
      _showMessage('已是最新版本 v${result.currentVersionName}');
      return;
    }

    final confirmed = await _confirmUpdate(update);
    if (confirmed == true && mounted) {
      await _downloadAndInstall(update);
    }
  }

  Future<bool?> _confirmUpdate(AppUpdateInfo update) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: !update.force,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 ${update.versionName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本号：${update.versionCode}'),
            if (update.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final note in update.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• $note'),
                ),
            ],
          ],
        ),
        actions: [
          if (!update.force)
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(AppUpdateInfo update) async {
    setState(() {
      _isDownloadingUpdate = true;
      _downloadProgress = null;
    });

    var wakelockWasEnabled = false;
    var wakelockChanged = false;
    try {
      try {
        wakelockWasEnabled = await WakelockPlus.enabled;
        await WakelockPlus.enable();
        wakelockChanged = !wakelockWasEnabled;
      } catch (_) {
        // Keep updating even if the device refuses the screen wakelock.
      }

      final apk = await _updateService.downloadApk(
        update,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _downloadProgress = received / total);
        },
      );
      if (!mounted) return;
      setState(() => _downloadProgress = 1);
      await _updateService.installApk(apk);
    } catch (error) {
      if (mounted) {
        _showMessage('更新失败：${_friendlyUpdateError(error)}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingUpdate = false;
          _downloadProgress = null;
        });
      }
      if (wakelockChanged) {
        try {
          await WakelockPlus.disable();
        } catch (_) {
          // Nothing else to do if wakelock cleanup fails.
        }
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyUpdateError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    if (text.contains('checksum')) return '安装包校验失败';
    if (text.contains('Invalid update config')) return '服务器版本配置不正确';
    if (text.contains('Update check failed')) return '服务器版本文件无法访问';
    if (text.contains('APK download failed')) return '安装包下载失败';
    if (text.contains('INSTALL_FAILED') || text.contains('installApk')) {
      return '安装包已下载，调起安装失败，请重新点击立即更新';
    }
    if (text.contains('SocketException') ||
        text.contains('TimeoutException') ||
        text.contains('ClientException') ||
        text.contains('HttpException') ||
        text.contains('HandshakeException')) {
      return '网络连接失败，请稍后再试';
    }
    return '更新失败，请稍后再试';
  }
}

class UpdateLogScreen extends StatelessWidget {
  const UpdateLogScreen({super.key});

  static const List<_UpdateLogEntry> _entries = [
    _UpdateLogEntry(
      versionName: '2.0.4',
      versionCode: 6,
      dateLabel: '2026-06-30',
      notes: [
        '小说阅读页右下角新增当前章节阅读百分比',
        '动漫视频播放默认音量调整为 50%',
        '设置页新增更新日志，集中查看历史版本内容',
      ],
    ),
    _UpdateLogEntry(
      versionName: '2.0.3',
      versionCode: 5,
      dateLabel: '2026-06-30',
      notes: [
        '更新下载期间保持屏幕常亮，降低息屏导致失败的概率',
        '已下载并校验通过的安装包会直接复用，不再重复下载',
        '支持断点续传，网络中断后再次更新可继续下载',
      ],
    ),
    _UpdateLogEntry(
      versionName: '2.0.2',
      versionCode: 4,
      dateLabel: '2026-06-30',
      notes: [
        '隐藏科大讯飞 AppID、API Key、API Secret 输入内容',
        '检查更新界面不再显示服务器地址',
        '修复小说、动漫、漫画域名自动适配',
      ],
    ),
    _UpdateLogEntry(
      versionName: '2.0.1',
      versionCode: 3,
      dateLabel: '2026-06-30',
      notes: ['新增 App 内检查更新', '支持下载 APK 并调用系统安装', '修复小说首页域名问题'],
    ),
    _UpdateLogEntry(
      versionName: '2.0.0',
      versionCode: 2,
      dateLabel: '2026-06-29',
      notes: ['整理小说阅读、漫画阅读、动漫播放等主要功能', '完善书架、历史记录和阅读设置体验'],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('更新日志')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _entries.length,
        separatorBuilder: (_, _) => const Divider(height: 28),
        itemBuilder: (context, index) => _UpdateLogItem(entry: _entries[index]),
      ),
    );
  }
}

class _UpdateLogEntry {
  const _UpdateLogEntry({
    required this.versionName,
    required this.versionCode,
    required this.dateLabel,
    required this.notes,
  });

  final String versionName;
  final int versionCode;
  final String dateLabel;
  final List<String> notes;
}

class _UpdateLogItem extends StatelessWidget {
  const _UpdateLogItem({required this.entry});

  final _UpdateLogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Sakura v${entry.versionName}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            Text(
              entry.dateLabel,
              style: const TextStyle(fontSize: 12, color: AppTheme.textHint),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '版本号：${entry.versionCode}',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 10),
        for (final note in entry.notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 7),
                  child: SizedBox(
                    width: 4,
                    height: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    note,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class AnimeHistoryScreen extends StatefulWidget {
  const AnimeHistoryScreen({super.key});

  @override
  State<AnimeHistoryScreen> createState() => _AnimeHistoryScreenState();
}

class _AnimeHistoryScreenState extends State<AnimeHistoryScreen> {
  final StorageService _storageService = StorageService();

  late Future<List<AnimeWatchHistory>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = _loadHistory();
  }

  Future<List<AnimeWatchHistory>> _loadHistory() {
    return _storageService.getAnimeWatchHistory();
  }

  Future<void> _refresh() async {
    setState(() => _historyFuture = _loadHistory());
    await _historyFuture;
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空动漫播放历史'),
        content: const Text('只会清空本地动漫播放历史，不影响书架和缓存。'),
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
    await _storageService.clearAnimeWatchHistory();
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _deleteHistory(AnimeWatchHistory history) async {
    await _storageService.deleteAnimeWatchHistory(history.animeId);
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _openHistory(AnimeWatchHistory history) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnimePlayerScreen(
          anime: history.anime,
          source: history.source,
          episode: history.episode,
          resumeFromHistory: true,
        ),
      ),
    );
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('动漫播放历史'),
        actions: [
          IconButton(
            tooltip: '清空',
            onPressed: _clearHistory,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: FutureBuilder<List<AnimeWatchHistory>>(
        future: _historyFuture,
        builder: (context, snapshot) {
          final isNight = Theme.of(context).brightness == Brightness.dark;
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final histories = snapshot.data ?? const [];
          if (histories.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.22),
                  Icon(
                    Icons.history_toggle_off,
                    size: 64,
                    color: isNight ? AppTheme.nightText : AppTheme.textHint,
                  ),
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                      '暂无动漫播放历史',
                      style: TextStyle(
                        color: isNight
                            ? AppTheme.nightText
                            : AppTheme.textSecondary,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              itemCount: histories.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final history = histories[index];
                return _AnimeHistoryTile(
                  history: history,
                  isNight: isNight,
                  onTap: () => _openHistory(history),
                  onDelete: () => _deleteHistory(history),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _AnimeHistoryTile extends StatelessWidget {
  const _AnimeHistoryTile({
    required this.history,
    required this.isNight,
    required this.onTap,
    required this.onDelete,
  });

  final AnimeWatchHistory history;
  final bool isNight;
  final VoidCallback onTap;
  final VoidCallback onDelete;

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
                width: 72,
                height: 102,
                child: AnimeCover(imageUrl: history.coverUrl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    history.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isNight ? Colors.white : AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${history.sourceName} · ${history.episodeTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: history.progress,
                      minHeight: 4,
                      backgroundColor: isNight
                          ? const Color(0xFF3A3A3A)
                          : AppTheme.dividerColor,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '播放至 ${_formatDuration(history.position)} / ${_formatDuration(history.duration)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isNight
                          ? AppTheme.nightText
                          : AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatUpdatedAt(history.updatedAtMs),
                    style: TextStyle(
                      color: isNight ? AppTheme.nightText : AppTheme.textHint,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '删除记录',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _formatUpdatedAt(int value) {
    final date = DateTime.fromMillisecondsSinceEpoch(value);
    final now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return '今天 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class MangaHistoryScreen extends StatefulWidget {
  const MangaHistoryScreen({super.key});

  @override
  State<MangaHistoryScreen> createState() => _MangaHistoryScreenState();
}

class _MangaHistoryScreenState extends State<MangaHistoryScreen> {
  final StorageService _storageService = StorageService();

  late Future<List<MangaReadHistory>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = _loadHistory();
  }

  Future<List<MangaReadHistory>> _loadHistory() {
    return _storageService.getMangaReadHistory();
  }

  Future<void> _refresh() async {
    setState(() => _historyFuture = _loadHistory());
    await _historyFuture;
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空阅读历史'),
        content: const Text('只会清空本地漫画阅读历史，不影响书架和缓存。'),
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
    await _storageService.clearMangaReadHistory();
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _deleteHistory(MangaReadHistory history) async {
    await _storageService.deleteMangaReadHistory(history.mangaId);
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _openHistory(MangaReadHistory history) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MangaReaderScreen(
          manga: history.manga,
          chapter: history.chapter,
          chapterIndex: history.chapterIndex,
          initialScrollOffset: history.scrollOffset,
          initialScrollProgress: history.progress,
          initialPageIndex: history.pageIndex,
          initialPageOffsetRatio: history.pageOffsetRatio,
        ),
      ),
    );
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('漫画阅读历史'),
        actions: [
          IconButton(
            tooltip: '清空',
            onPressed: _clearHistory,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: FutureBuilder<List<MangaReadHistory>>(
        future: _historyFuture,
        builder: (context, snapshot) {
          final isNight = Theme.of(context).brightness == Brightness.dark;
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final histories = snapshot.data ?? const [];
          if (histories.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.22),
                  Icon(
                    Icons.history_toggle_off,
                    size: 64,
                    color: isNight ? AppTheme.nightText : AppTheme.textHint,
                  ),
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                      '暂无漫画阅读历史',
                      style: TextStyle(
                        color: isNight
                            ? AppTheme.nightText
                            : AppTheme.textSecondary,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              itemCount: histories.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final history = histories[index];
                return _MangaHistoryTile(
                  history: history,
                  isNight: isNight,
                  onTap: () => _openHistory(history),
                  onDelete: () => _deleteHistory(history),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _MangaHistoryTile extends StatelessWidget {
  const _MangaHistoryTile({
    required this.history,
    required this.isNight,
    required this.onTap,
    required this.onDelete,
  });

  final MangaReadHistory history;
  final bool isNight;
  final VoidCallback onTap;
  final VoidCallback onDelete;

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
                width: 72,
                height: 102,
                child: MangaCover(imageUrl: history.coverUrl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    history.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isNight ? Colors.white : AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '读至 ${history.chapterTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: history.progress,
                      minHeight: 4,
                      backgroundColor: isNight
                          ? const Color(0xFF3A3A3A)
                          : AppTheme.dividerColor,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '阅读进度 ${_formatProgress(history.progress)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isNight
                          ? AppTheme.nightText
                          : AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatUpdatedAt(history.updatedAtMs),
                    style: TextStyle(
                      color: isNight ? AppTheme.nightText : AppTheme.textHint,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '删除记录',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              color: isNight ? AppTheme.nightText : AppTheme.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  String _formatProgress(double value) {
    return '${(value * 100).clamp(0, 100).round()}%';
  }

  String _formatUpdatedAt(int value) {
    final date = DateTime.fromMillisecondsSinceEpoch(value);
    final now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return '今天 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class TtsSettingsScreen extends StatefulWidget {
  const TtsSettingsScreen({super.key});

  @override
  State<TtsSettingsScreen> createState() => _TtsSettingsScreenState();
}

class _TtsSettingsScreenState extends State<TtsSettingsScreen> {
  late TextEditingController _appIdController;
  late TextEditingController _apiKeyController;
  late TextEditingController _apiSecretController;
  late TtsSettings _draft;

  @override
  void initState() {
    super.initState();
    _draft = context.read<TtsProvider>().settings;
    _appIdController = TextEditingController(text: _draft.iflytekAppId);
    _apiKeyController = TextEditingController(text: _draft.iflytekApiKey);
    _apiSecretController = TextEditingController(text: _draft.iflytekApiSecret);
  }

  @override
  void dispose() {
    _appIdController.dispose();
    _apiKeyController.dispose();
    _apiSecretController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final next = _draft.copyWith(
      iflytekAppId: _appIdController.text.trim(),
      iflytekApiKey: _apiKeyController.text.trim(),
      iflytekApiSecret: _apiSecretController.text.trim(),
    );
    await context.read<TtsProvider>().updateSettings(next);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('语音朗读配置已保存')));
    Navigator.pop(context);
  }

  Widget _buildCredentialField({
    required TextEditingController controller,
    required String label,
  }) {
    return TextField(
      controller: controller,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.visiblePassword,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('语音朗读'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '朗读引擎',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: TtsSettings.engineSystem,
                label: Text('系统 TTS'),
                icon: Icon(Icons.volume_up_outlined),
              ),
              ButtonSegment(
                value: TtsSettings.engineIflytek,
                label: Text('科大讯飞'),
                icon: Icon(Icons.cloud_outlined),
              ),
            ],
            selected: {_draft.engine},
            onSelectionChanged: (value) {
              setState(() => _draft = _draft.copyWith(engine: value.first));
            },
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('使用科大讯飞在线语音'),
            subtitle: const Text('需要在讯飞开放平台开通在线语音合成并填写密钥'),
            value: _draft.useIflytek,
            onChanged: (value) {
              setState(() {
                _draft = _draft.copyWith(
                  engine: value
                      ? TtsSettings.engineIflytek
                      : TtsSettings.engineSystem,
                );
              });
            },
          ),
          const SizedBox(height: 12),
          _buildCredentialField(controller: _appIdController, label: 'AppID'),
          const SizedBox(height: 12),
          _buildCredentialField(
            controller: _apiKeyController,
            label: 'API Key',
          ),
          const SizedBox(height: 12),
          _buildCredentialField(
            controller: _apiSecretController,
            label: 'API Secret',
          ),
          const SizedBox(height: 24),
          const Text(
            '发音人',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          RadioGroup<String>(
            groupValue: _draft.iflytekVoiceName,
            onChanged: (value) {
              if (value == null) return;
              final selectedVoice = iflytekBasicVoices.firstWhere(
                (voice) => voice.name == value,
              );
              setState(() {
                _draft = _draft.copyWith(
                  iflytekVoiceName: selectedVoice.name,
                  iflytekVoiceLabel: selectedVoice.label,
                );
              });
            },
            child: Column(
              children: iflytekBasicVoices.map((voice) {
                return RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: Text(voice.label),
                  subtitle: Text('${voice.language} · ${voice.name}'),
                  value: voice.name,
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
