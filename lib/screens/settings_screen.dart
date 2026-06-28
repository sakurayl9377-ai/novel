import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/theme.dart';
import '../models/anime_watch_history.dart';
import '../models/manga_read_history.dart';
import '../models/tts_settings.dart';
import '../providers/reading_provider.dart';
import '../providers/tts_provider.dart';
import '../services/storage_service.dart';
import 'anime_player_screen.dart';
import 'anime_screen.dart';
import 'bookshelf_screen.dart';
import 'manga_reader_screen.dart';
import 'manga_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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
            subtitle: 'v1.0.0',
            onTap: () {},
          ),
          _buildMenuItem(
            icon: Icons.favorite_border,
            title: '评个分吧',
            onTap: () {},
          ),
          const SizedBox(height: 32),
          const Center(
            child: Text(
              'Sakura v2.0.0',
              style: TextStyle(fontSize: 12, color: AppTheme.textHint),
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
          TextField(
            controller: _appIdController,
            decoration: const InputDecoration(
              labelText: 'AppID',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyController,
            decoration: const InputDecoration(
              labelText: 'API Key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiSecretController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Secret',
              border: OutlineInputBorder(),
            ),
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
