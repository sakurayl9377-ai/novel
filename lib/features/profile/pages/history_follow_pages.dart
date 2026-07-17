part of '../profile_screen.dart';

class _HistoryRecordsPage extends StatelessWidget {
  const _HistoryRecordsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('历史记录')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        children: [
          _SurfaceCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _HistoryRecordTile(
                  icon: Icons.movie_filter_outlined,
                  color: const Color(0xFF4D8DF7),
                  title: '动漫播放历史',
                  subtitle: '继续观看最近播放的动漫',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AnimeHistoryScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, color: AppTheme.dividerColor),
                _HistoryRecordTile(
                  icon: Icons.auto_stories_outlined,
                  color: const Color(0xFF8D72E8),
                  title: '漫画阅读历史',
                  subtitle: '继续阅读最近打开的漫画',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const MangaHistoryScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, color: AppTheme.dividerColor),
                _HistoryRecordTile(
                  icon: Icons.menu_book_outlined,
                  color: const Color(0xFF3D9B72),
                  title: '小说阅读历史',
                  subtitle: '继续阅读最近打开的小说',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NovelHistoryScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NovelHistoryScreen extends StatefulWidget {
  const NovelHistoryScreen({super.key});

  @override
  State<NovelHistoryScreen> createState() => _NovelHistoryScreenState();
}

class _NovelHistoryScreenState extends State<NovelHistoryScreen> {
  final StorageService _storage = StorageService();
  late Future<List<NovelReadingHistory>> _future = _storage
      .getNovelReadingHistory();

  Future<void> _refresh() async {
    final next = _storage.getNovelReadingHistory();
    setState(() => _future = next);
    await next;
  }

  Future<void> _open(NovelReadingHistory history) async {
    final novel = Novel(
      id: history.novelId,
      title: history.title,
      author: history.author,
      coverUrl: history.coverUrl,
      sourceId: history.sourceId,
      sourceName: history.sourceName,
      chapterUrl: history.chapterUrl,
      currentChapterIndex: history.chapterIndex,
      lastReadAt: history.lastReadAt,
    );
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailScreen(
          novel: novel,
          initialProgress: ReadingProgress(
            novelId: history.novelId,
            chapterIndex: history.chapterIndex,
            chapterTitle: history.chapterTitle,
            chapterUrl: history.chapterUrl,
            charPosition: history.charPosition,
            scrollPosition: history.scrollPosition,
            lastReadAt: history.lastReadAt,
          ),
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('小说阅读历史')),
      body: FutureBuilder<List<NovelReadingHistory>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ProfileHistoryMessage(
              title: '历史记录加载失败',
              onRefresh: _refresh,
            );
          }
          final histories = snapshot.data ?? const <NovelReadingHistory>[];
          if (histories.isEmpty) {
            return _ProfileHistoryMessage(
              title: '暂无小说阅读历史',
              onRefresh: _refresh,
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              itemCount: histories.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final history = histories[index];
                final chapter = history.chapterTitle.isEmpty
                    ? '第${history.chapterIndex + 1}章'
                    : history.chapterTitle;
                return _SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    onTap: () => _open(history),
                    contentPadding: const EdgeInsets.all(12),
                    leading: SizedBox(
                      width: 52,
                      height: 70,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: history.coverUrl.isEmpty
                            ? const ColoredBox(
                                color: Color(0xFFE7E7E7),
                                child: Icon(Icons.menu_book_outlined),
                              )
                            : Image.network(
                                history.coverUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const ColoredBox(
                                  color: Color(0xFFE7E7E7),
                                  child: Icon(Icons.menu_book_outlined),
                                ),
                              ),
                      ),
                    ),
                    title: Text(
                      history.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '$chapter · ${history.sourceName.isEmpty ? '小说书源' : history.sourceName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ProfileHistoryMessage extends StatelessWidget {
  const _ProfileHistoryMessage({required this.title, required this.onRefresh});

  final String title;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 100, 18, 28),
        children: [
          _SurfaceCard(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                const Icon(
                  Icons.menu_book_outlined,
                  size: 46,
                  color: AppTheme.textHint,
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text('阅读小说后会自动记录进度'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRecordTile extends StatelessWidget {
  const _HistoryRecordTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_profileCardRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              _ColoredIcon(icon: icon, color: color, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        fontFamilyFallback: _profileFontFallback,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        height: 1.15,
                        fontFamilyFallback: _profileFontFallback,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppTheme.textHint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _FollowListKind { followers, following }

class _FollowListPage extends StatefulWidget {
  const _FollowListPage({
    required this.kind,
    required this.userId,
    required this.selfUserId,
    required this.token,
    required this.service,
  });

  final _FollowListKind kind;
  final int userId;
  final int selfUserId;
  final String token;
  final InteractionService service;

  @override
  State<_FollowListPage> createState() => _FollowListPageState();
}

class _FollowListPageState extends State<_FollowListPage> {
  late Future<List<InteractionUser>> _future = _load();

  String get _title => switch (widget.kind) {
    _FollowListKind.followers => '粉丝',
    _FollowListKind.following => '关注',
  };

  Future<List<InteractionUser>> _load() {
    return switch (widget.kind) {
      _FollowListKind.followers => widget.service.fetchUserFollowers(
        userId: widget.userId,
        token: widget.token,
      ),
      _FollowListKind.following => widget.service.fetchUserFollowing(
        userId: widget.userId,
        token: widget.token,
      ),
    };
  }

  Future<void> _refresh() async {
    final future = _load();
    setState(() => _future = future);
    await future;
  }

  Future<void> _openUser(InteractionUser user) async {
    try {
      final profile = await widget.service.fetchUserProfile(
        userId: user.id,
        token: widget.token,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => InteractionUserProfileSheet(
          profile: profile,
          isSelf: widget.selfUserId == profile.user.id,
          onFollowChanged: (follow) => widget.service.followUser(
            token: widget.token,
            userId: profile.user.id,
            follow: follow,
          ),
          onPrivateChat: widget.selfUserId == profile.user.id
              ? null
              : () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PrivateChatScreen(
                        peer: InteractionUserBrief(
                          id: profile.user.id,
                          nickname: profile.user.nickname,
                          avatarUrl: profile.user.avatarUrl,
                        ),
                      ),
                    ),
                  );
                },
        ),
      );
      if (mounted) await _refresh();
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        error is InteractionServiceException ? error.message : '用户资料加载失败',
      );
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _profileBottomBackground,
      appBar: AppBar(
        title: Text(_title),
        backgroundColor: _profileTopBackground,
        surfaceTintColor: Colors.transparent,
      ),
      body: FutureBuilder<List<InteractionUser>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _InteractionLoadingList();
          }
          if (snapshot.hasError) {
            return _FollowListMessage(
              icon: Icons.cloud_off_outlined,
              title: '$_title加载失败',
              subtitle: '下拉刷新后再试一次',
              onRefresh: _refresh,
            );
          }
          final users = snapshot.data ?? const <InteractionUser>[];
          if (users.isEmpty) {
            return _FollowListMessage(
              icon: widget.kind == _FollowListKind.followers
                  ? Icons.groups_2_outlined
                  : Icons.favorite_border_rounded,
              title: widget.kind == _FollowListKind.followers
                  ? '还没有粉丝'
                  : '还没有关注的人',
              subtitle: '下拉刷新列表',
              onRefresh: _refresh,
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                _profileHorizontalPadding,
                14,
                _profileHorizontalPadding,
                28,
              ),
              itemCount: users.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _FollowUserTile(
                user: users[index],
                onTap: () => _openUser(users[index]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FollowUserTile extends StatelessWidget {
  const _FollowUserTile({required this.user, required this.onTap});

  final InteractionUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = user.signature.trim().isNotEmpty
        ? user.signature.trim()
        : 'Lv${user.growth.level} ${user.growth.levelName}';
    return _SurfaceCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        leading: _LevelAvatar(user: user, size: 48),
        title: Text(
          user.nickname,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFamilyFallback: _profileFontFallback,
          ),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            fontFamilyFallback: _profileFontFallback,
          ),
        ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: AppTheme.textHint,
        ),
      ),
    );
  }
}

class _FollowListMessage extends StatelessWidget {
  const _FollowListMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onRefresh,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          _profileHorizontalPadding,
          70,
          _profileHorizontalPadding,
          28,
        ),
        children: [
          _SurfaceCard(
            padding: const EdgeInsets.fromLTRB(18, 28, 18, 27),
            child: Column(
              children: [
                Icon(icon, size: 42, color: _profileAccentBlue),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
