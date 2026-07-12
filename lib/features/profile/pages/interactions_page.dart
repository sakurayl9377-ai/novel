part of '../profile_screen.dart';

class _MyInteractionsPage extends StatefulWidget {
  const _MyInteractionsPage({
    required this.token,
    required this.service,
    required this.initialTab,
  });

  final String token;
  final InteractionService service;
  final int initialTab;

  @override
  State<_MyInteractionsPage> createState() => _MyInteractionsPageState();
}

class _MyInteractionsPageState extends State<_MyInteractionsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late Future<List<InteractionComment>> _commentsFuture;
  late Future<List<InteractionDanmaku>> _danmakuFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1).toInt(),
    );
    _commentsFuture = _loadComments();
    _danmakuFuture = _loadDanmaku();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<List<InteractionComment>> _loadComments() {
    return widget.service.fetchMyComments(token: widget.token);
  }

  Future<List<InteractionDanmaku>> _loadDanmaku() {
    return widget.service.fetchMyDanmaku(token: widget.token);
  }

  Future<void> _refreshComments() async {
    final future = _loadComments();
    setState(() => _commentsFuture = future);
    await future;
  }

  Future<void> _refreshDanmaku() async {
    final future = _loadDanmaku();
    setState(() => _danmakuFuture = future);
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _profileBottomBackground,
      appBar: AppBar(
        toolbarHeight: 50,
        centerTitle: false,
        titleSpacing: _profileHorizontalPadding,
        title: const Text(
          '我的互动',
          style: TextStyle(
            fontSize: 18,
            height: 1,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
            fontFamilyFallback: _profileFontFallback,
          ),
        ),
        backgroundColor: _profileTopBackground,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(42),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: _profileAccentBlue,
              unselectedLabelColor: AppTheme.textSecondary,
              dividerColor: Colors.transparent,
              indicatorColor: _profileAccentBlue,
              indicatorSize: TabBarIndicatorSize.label,
              labelStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFamilyFallback: _profileFontFallback,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                fontFamilyFallback: _profileFontFallback,
              ),
              tabs: const [
                Tab(text: '评论'),
                Tab(text: '弹幕'),
              ],
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _profileTopBackground,
              _profileMidBackground,
              _profileBottomBackground,
            ],
            stops: [0, 0.28, 1],
          ),
        ),
        child: TabBarView(
          controller: _tabController,
          children: [_buildCommentsTab(), _buildDanmakuTab()],
        ),
      ),
    );
  }

  Widget _buildCommentsTab() {
    return FutureBuilder<List<InteractionComment>>(
      future: _commentsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _InteractionLoadingList();
        }
        if (snapshot.hasError) {
          return _InteractionMessageList(
            icon: Icons.chat_bubble_outline,
            title: '评论加载失败',
            subtitle: '下拉刷新再试一次',
            onRefresh: _refreshComments,
          );
        }
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return _InteractionMessageList(
            icon: Icons.chat_bubble_outline,
            title: '还没有评论',
            subtitle: '在作品详情页写下第一条想法后，这里会同步展示',
            onRefresh: _refreshComments,
          );
        }
        return RefreshIndicator(
          onRefresh: _refreshComments,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              _profileHorizontalPadding,
              14,
              _profileHorizontalPadding,
              28,
            ),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) =>
                _MyCommentTile(comment: items[index]),
          ),
        );
      },
    );
  }

  Widget _buildDanmakuTab() {
    return FutureBuilder<List<InteractionDanmaku>>(
      future: _danmakuFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _InteractionLoadingList();
        }
        if (snapshot.hasError) {
          return _InteractionMessageList(
            icon: Icons.subtitles_outlined,
            title: '弹幕加载失败',
            subtitle: '下拉刷新再试一次',
            onRefresh: _refreshDanmaku,
          );
        }
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return _InteractionMessageList(
            icon: Icons.subtitles_outlined,
            title: '还没有弹幕',
            subtitle: '在动漫播放器里发送弹幕后，这里会同步展示',
            onRefresh: _refreshDanmaku,
          );
        }
        return RefreshIndicator(
          onRefresh: _refreshDanmaku,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              _profileHorizontalPadding,
              14,
              _profileHorizontalPadding,
              28,
            ),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) =>
                _MyDanmakuTile(danmaku: items[index]),
          ),
        );
      },
    );
  }
}

class _MyCommentTile extends StatelessWidget {
  const _MyCommentTile({required this.comment});

  final InteractionComment comment;

  @override
  Widget build(BuildContext context) {
    final contextText = _commentContextText(comment);
    final meta = [
      _interactionRelativeTime(comment.createdAt),
      if (comment.likeCount > 0) '赞 ${comment.likeCount}',
      if (comment.replyCount > 0) '回复 ${comment.replyCount}',
    ].where((item) => item.isNotEmpty).join(' · ');
    return _SurfaceCard(
      padding: const EdgeInsets.fromLTRB(13, 13, 13, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SoftLineIcon(
            icon: comment.parentId == null
                ? Icons.chat_bubble_outline
                : Icons.reply_rounded,
            color: const Color(0xFFFF8A3D),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: FontWeight.w400,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  contextText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w400,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textHint,
                      fontSize: 11.5,
                      height: 1.2,
                      fontWeight: FontWeight.w400,
                      fontFamilyFallback: _profileFontFallback,
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

class _MyDanmakuTile extends StatelessWidget {
  const _MyDanmakuTile({required this.danmaku});

  final InteractionDanmaku danmaku;

  @override
  Widget build(BuildContext context) {
    final contextText = _danmakuContextText(danmaku);
    final timeText = _formatDanmakuTime(danmaku.timeMs);
    final meta = [
      if (timeText.isNotEmpty) '视频 $timeText',
      _interactionRelativeTime(danmaku.createdAt),
    ].where((item) => item.isNotEmpty).join(' · ');
    return _SurfaceCard(
      padding: const EdgeInsets.fromLTRB(13, 13, 13, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SoftLineIcon(
            icon: Icons.subtitles_outlined,
            color: Color(0xFF7C6BFF),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  danmaku.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: FontWeight.w400,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  contextText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w400,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textHint,
                      fontSize: 11.5,
                      height: 1.2,
                      fontWeight: FontWeight.w400,
                      fontFamilyFallback: _profileFontFallback,
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

class _SoftLineIcon extends StatelessWidget {
  const _SoftLineIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(_profileCardRadius),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}

class _InteractionLoadingList extends StatelessWidget {
  const _InteractionLoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        _profileHorizontalPadding,
        14,
        _profileHorizontalPadding,
        28,
      ),
      itemCount: 4,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, _) => const _SurfaceCard(
        padding: EdgeInsets.fromLTRB(13, 13, 13, 12),
        child: _InteractionSkeleton(),
      ),
    );
  }
}

class _InteractionSkeleton extends StatelessWidget {
  const _InteractionSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFFEFF3F8),
            borderRadius: BorderRadius.circular(_profileCardRadius),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _SkeletonLine(widthFactor: 0.92),
              SizedBox(height: 9),
              _SkeletonLine(widthFactor: 0.68),
              SizedBox(height: 9),
              _SkeletonLine(widthFactor: 0.42),
            ],
          ),
        ),
      ],
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.widthFactor});

  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 10,
        decoration: BoxDecoration(
          color: const Color(0xFFEFF3F8),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class _InteractionMessageList extends StatelessWidget {
  const _InteractionMessageList({
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
          78,
          _profileHorizontalPadding,
          28,
        ),
        children: [
          _SurfaceCard(
            padding: const EdgeInsets.fromLTRB(18, 26, 18, 25),
            child: Column(
              children: [
                _SoftLineIcon(icon: icon, color: _profileAccentBlue),
                const SizedBox(height: 13),
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    fontFamilyFallback: _profileFontFallback,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12.5,
                    height: 1.4,
                    fontWeight: FontWeight.w400,
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
