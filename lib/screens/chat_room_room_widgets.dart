part of 'chat_room_screen.dart';

class _ChatRoomInfoSheet extends StatelessWidget {
  const _ChatRoomInfoSheet({
    required this.room,
    required this.isLoading,
    required this.canLeave,
    required this.currentUserId,
    required this.scrollController,
    required this.onLeave,
    required this.onSearch,
    required this.onMention,
    required this.onOpenMember,
  });

  final ChatRoomInfo room;
  final bool isLoading;
  final bool canLeave;
  final int currentUserId;
  final ScrollController scrollController;
  final VoidCallback onLeave;
  final VoidCallback onSearch;
  final ValueChanged<ChatRoomMember> onMention;
  final ValueChanged<ChatRoomMember> onOpenMember;

  @override
  Widget build(BuildContext context) {
    final latest = room.latestContent.isEmpty ? '暂无最近消息' : room.latestContent;
    final totalMemberCount = room.members.length;
    final onlineMemberCount = room.members
        .where((member) => _chatMemberIsOnline(member, currentUserId))
        .length;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Material(
        color: const Color(0xFFFAFAFF),
        child: SafeArea(
          top: false,
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 44,
                          height: 5,
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF1F2937,
                            ).withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          _RoomSnapshotAvatar(room: room),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        room.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                    if (isLoading)
                                      const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  room.displayCategoryLabel,
                                  style: const TextStyle(
                                    color: AppTheme.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          _RoomInfoMetric(
                            icon: Icons.people_outline,
                            label: '在线/总人数',
                            value: totalMemberCount > 0
                                ? '$onlineMemberCount/$totalMemberCount'
                                : '${room.activeUserCount}',
                          ),
                          const SizedBox(width: 8),
                          _RoomInfoMetric(
                            icon: Icons.workspace_premium_outlined,
                            label: '入场等级',
                            value: room.minLevel > 0
                                ? 'Lv${room.minLevel}'
                                : '不限',
                          ),
                          const SizedBox(width: 8),
                          _RoomInfoMetric(
                            icon: Icons.chat_bubble_outline,
                            label: '最近消息',
                            value: '${room.recentMessageCount}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F6FB),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          latest,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _ChatRoomMemberList(
                        members: room.members,
                        currentUserId: currentUserId,
                        onMention: onMention,
                        onOpenMember: onOpenMember,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 42,
                              child: OutlinedButton.icon(
                                onPressed: onSearch,
                                icon: const Icon(Icons.search_rounded),
                                label: const Text('搜索历史聊天'),
                              ),
                            ),
                          ),
                          if (canLeave) ...[
                            const SizedBox(width: 10),
                            SizedBox(
                              height: 42,
                              child: OutlinedButton.icon(
                                onPressed: onLeave,
                                icon: const Icon(Icons.logout_rounded),
                                label: const Text('退出'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.accentColor,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomSnapshotAvatar extends StatelessWidget {
  const _RoomSnapshotAvatar({required this.room});

  final ChatRoomInfo room;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 50,
        height: 50,
        color: AppTheme.primaryColor.withValues(alpha: 0.1),
        child: room.avatarUrl.isEmpty
            ? const Icon(Icons.forum_outlined, color: AppTheme.primaryColor)
            : Image.network(
                room.avatarUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.forum_outlined,
                  color: AppTheme.primaryColor,
                ),
              ),
      ),
    );
  }
}

class _RoomInfoMetric extends StatelessWidget {
  const _RoomInfoMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.primaryColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppTheme.primaryColor, size: 18),
            const SizedBox(height: 5),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatRoomMemberList extends StatelessWidget {
  const _ChatRoomMemberList({
    required this.members,
    required this.currentUserId,
    required this.onMention,
    required this.onOpenMember,
  });

  final List<ChatRoomMember> members;
  final int currentUserId;
  final ValueChanged<ChatRoomMember> onMention;
  final ValueChanged<ChatRoomMember> onOpenMember;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return const SizedBox.shrink();
    }
    final visibleMembers = members.take(12).toList();
    final onlineCount = members
        .where((member) => _chatMemberIsOnline(member, currentUserId))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '当前成员',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppTheme.primaryColor.withValues(alpha: 0.18),
                ),
              ),
              child: Text(
                '在线 $onlineCount / 共 ${members.length}',
                style: const TextStyle(
                  color: AppTheme.primaryColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFE),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: visibleMembers.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 54),
            itemBuilder: (context, index) {
              return _ChatRoomMemberTile(
                member: visibleMembers[index],
                currentUserId: currentUserId,
                onMention: onMention,
                onOpenMember: onOpenMember,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ChatRoomMemberTile extends StatelessWidget {
  const _ChatRoomMemberTile({
    required this.member,
    required this.currentUserId,
    required this.onMention,
    required this.onOpenMember,
  });

  final ChatRoomMember member;
  final int currentUserId;
  final ValueChanged<ChatRoomMember> onMention;
  final ValueChanged<ChatRoomMember> onOpenMember;

  @override
  Widget build(BuildContext context) {
    final isOnline = _chatMemberIsOnline(member, currentUserId);
    final subtitle = member.isBot
        ? '24h 在线'
        : isOnline
        ? '在线'
        : member.lastSeenAt.isEmpty
        ? '离线'
        : '最后下线 ${_formatChatMessageTime(_parseChatServerTime(member.lastSeenAt))}';
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      onTap: () => onOpenMember(member),
      onLongPress: () => onMention(member),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          _TinyAvatar(
            name: member.nickname,
            imageUrl: member.avatarUrl,
            assetPath: member.avatarAsset,
          ),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: isOnline
                    ? const Color(0xFF22C55E)
                    : const Color(0xFFCBD5E1),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              member.nickname.isEmpty ? '用户' : member.nickname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          if (member.isAdmin) ...[
            const SizedBox(width: 6),
            const _RainbowAdminBadge(),
          ],
        ],
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: member.isBot
          ? const Icon(Icons.smart_toy_outlined, size: 18)
          : member.role == 'manager'
          ? const Icon(Icons.shield_outlined, size: 18)
          : null,
    );
  }
}

class _TinyAvatar extends StatelessWidget {
  const _TinyAvatar({
    required this.name,
    required this.imageUrl,
    this.assetPath = '',
  });

  final String name;
  final String imageUrl;
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: SizedBox(
        width: 36,
        height: 36,
        child: assetPath.isNotEmpty
            ? Image.asset(
                assetPath,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Image.asset(
                  defaultInteractionAvatarAsset,
                  fit: BoxFit.cover,
                ),
              )
            : imageUrl.isEmpty
            ? Image.asset(defaultInteractionAvatarAsset, fit: BoxFit.cover)
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Image.asset(
                  defaultInteractionAvatarAsset,
                  fit: BoxFit.cover,
                ),
              ),
      ),
    );
  }
}

class _RainbowAdminBadge extends StatefulWidget {
  const _RainbowAdminBadge();

  @override
  State<_RainbowAdminBadge> createState() => _RainbowAdminBadgeState();
}

class _RainbowAdminBadgeState extends State<_RainbowAdminBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shineController;

  @override
  void initState() {
    super.initState();
    _shineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _shineController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _shineController,
        builder: (context, child) {
          final shineX = -1.45 + _shineController.value * 2.9;
          return Container(
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFFFE7A6),
                  Color(0xFFB6A2FF),
                  Color(0xFF38BDF8),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1D4ED8).withValues(alpha: 0.16),
                  blurRadius: 7,
                  spreadRadius: -3,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: const Color(0xFFFFD67A).withValues(alpha: 0.16),
                  blurRadius: 5,
                  spreadRadius: -4,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(
                children: [
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Color(0xFF111827),
                          Color(0xFF211A3E),
                          Color(0xFF14345A),
                          Color(0xFF101827),
                        ],
                        stops: [0, 0.42, 0.72, 1],
                      ),
                    ),
                    child: child,
                  ),
                  Positioned.fill(
                    child: FractionalTranslation(
                      translation: Offset(shineX, 0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Colors.white.withValues(alpha: 0),
                              Colors.white.withValues(alpha: 0.32),
                              Colors.white.withValues(alpha: 0),
                            ],
                            stops: const [0.38, 0.5, 0.62],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2.2),
          child: Text(
            'ADMIN',
            style: TextStyle(
              color: Color(0xFFFFF7D6),
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.45,
              shadows: [
                Shadow(
                  color: Color(0x99000000),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatHistorySearchSheet extends StatefulWidget {
  const _ChatHistorySearchSheet({
    required this.service,
    required this.roomId,
    required this.token,
  });

  final InteractionService service;
  final String roomId;
  final String token;

  @override
  State<_ChatHistorySearchSheet> createState() =>
      _ChatHistorySearchSheetState();
}

class _ChatHistorySearchSheetState extends State<_ChatHistorySearchSheet> {
  final TextEditingController _queryController = TextEditingController();
  Future<List<ChatMessage>>? _future;
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _search() {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请输入搜索关键词')));
      return;
    }
    setState(() {
      _query = query;
      _future = widget.service.fetchChatRoomMessages(
        roomId: widget.roomId,
        query: query,
        token: widget.token,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.72,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '搜索历史聊天',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _queryController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: '输入关键词',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: _search,
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    final future = _future;
    if (future == null) {
      return const InteractionEmptyState(
        icon: Icons.manage_search_outlined,
        title: '搜索历史消息',
        subtitle: '输入关键词后，会查询当前聊天室的历史聊天记录。',
      );
    }
    return FutureBuilder<List<ChatMessage>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const InteractionEmptyState(
            icon: Icons.error_outline,
            title: '搜索失败',
            subtitle: '历史消息接口暂时不可用，请稍后再试。',
          );
        }
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return InteractionEmptyState(
            icon: Icons.search_off_outlined,
            title: '没有找到消息',
            subtitle: '没有匹配“$_query”的历史聊天。',
          );
        }
        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (context, index) =>
              const Divider(height: 1, color: AppTheme.dividerColor),
          itemBuilder: (context, index) {
            final message = items[index];
            final time = _parseChatServerTime(message.createdAt);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: InteractionAvatar(
                label: message.user.nickname,
                imageUrl: message.user.avatarUrl,
                size: 34,
              ),
              title: Text(
                message.user.nickname.isEmpty ? '用户' : message.user.nickname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                _messageSearchPreview(message),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                _formatChatMessageTime(time),
                style: const TextStyle(color: AppTheme.textHint, fontSize: 11),
              ),
            );
          },
        );
      },
    );
  }
}
