import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../models/interaction_models.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/interaction_service.dart';
import '../widgets/interaction_ui.dart';
import 'chat_room_screen.dart';
import 'interaction_auth_screen.dart';

const _notificationPreviewCount = 4;

class MessageCenterScreen extends StatefulWidget {
  const MessageCenterScreen({super.key, this.service});

  final InteractionService? service;

  @override
  State<MessageCenterScreen> createState() => _MessageCenterScreenState();
}

class _MessageCenterScreenState extends State<MessageCenterScreen> {
  static const _notificationFetchLimit = 12;

  late final InteractionService _service;
  late Future<_MessageCenterPayload> _future;
  _MessageCenterPayload _payload = const _MessageCenterPayload();
  _ConversationChannel _conversationChannel = _ConversationChannel.rooms;
  bool _markingAllNotificationsRead = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? InteractionService();
    _future = _refresh();
  }

  Future<_MessageCenterPayload> _load() async {
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) {
      return const _MessageCenterPayload();
    }
    final results = await Future.wait([
      _service.fetchChatRooms(token: auth.token),
      _service.fetchPrivateConversations(token: auth.token),
      _service.fetchSystemNotifications(
        token: auth.token,
        limit: _notificationFetchLimit,
      ),
      _service.fetchMessageUnreadSummary(token: auth.token),
    ]);
    return _MessageCenterPayload(
      rooms: (results[0] as ChatRoomListPayload).items,
      conversations: results[1] as List<PrivateConversation>,
      notifications: results[2] as List<SystemNotificationItem>,
      unread: results[3] as MessageUnreadSummary,
    );
  }

  Future<_MessageCenterPayload> _refresh() async {
    final payload = await _load();
    _payload = payload;
    return payload;
  }

  Future<void> _ensureLogin() async {
    final auth = context.read<InteractionAuthProvider>();
    if (auth.isLoggedIn) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
    );
    if (!mounted) return;
    setState(() => _future = _refresh());
  }

  Future<void> _openRoom(ChatRoomInfo room) async {
    final clearedPayload = _payload.clearRoomUnread(room.roomId);
    if (!identical(clearedPayload, _payload)) {
      setState(() {
        _payload = clearedPayload;
        _future = Future.value(clearedPayload);
      });
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatRoomScreen(roomId: room.roomId, title: room.displayName),
      ),
    );
    if (mounted) setState(() => _future = _refresh());
  }

  void _openPrivate(InteractionUserBrief peer) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PrivateChatScreen(peer: peer)),
    ).then((_) {
      if (mounted) setState(() => _future = _refresh());
    });
  }

  Future<void> _openSystemNotification(SystemNotificationItem item) async {
    final auth = context.read<InteractionAuthProvider>();
    if (item.readAt.isEmpty && auth.isLoggedIn) {
      final clearedPayload = _payload.clearNotificationUnread(item.id);
      if (!identical(clearedPayload, _payload)) {
        setState(() {
          _payload = clearedPayload;
          _future = Future.value(clearedPayload);
        });
      }
      unawaited(_markSystemNotificationRead(auth.token, item.id));
    }
    final detailItem = item.readAt.isEmpty
        ? SystemNotificationItem(
            id: item.id,
            title: item.title,
            content: item.content,
            category: item.category,
            readAt: DateTime.now().toIso8601String(),
            createdAt: item.createdAt,
          )
        : item;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SystemNotificationDetailScreen(item: detailItem),
      ),
    );
    if (mounted) setState(() => _future = _refresh());
  }

  Future<void> _markSystemNotificationRead(String token, int id) async {
    try {
      await _service.markSystemNotificationRead(token: token, id: id);
    } catch (_) {
      // Reading a notification is best-effort; the next refresh restores the server state.
    }
  }

  Future<void> _markAllSystemNotificationsRead() async {
    if (_markingAllNotificationsRead || _payload.unread.system == 0) return;
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) return;

    setState(() => _markingAllNotificationsRead = true);
    try {
      final unread = await _service.markAllSystemNotificationsRead(
        token: auth.token,
      );
      if (!mounted) return;
      final clearedPayload = _payload.clearAllNotificationUnread(unread);
      setState(() {
        _payload = clearedPayload;
        _future = Future.value(clearedPayload);
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('全部标为已读失败，请稍后重试')));
    } finally {
      if (mounted) setState(() => _markingAllNotificationsRead = false);
    }
  }

  Future<void> _openAllNotifications() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SystemNotificationInboxScreen(service: _service),
      ),
    );
    if (mounted) setState(() => _future = _refresh());
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('消息')),
      backgroundColor: const Color(0xFFF7F8FC),
      body: auth.isLoggedIn
          ? RefreshIndicator(
              onRefresh: () async => setState(() => _future = _refresh()),
              child: FutureBuilder<_MessageCenterPayload>(
                future: _future,
                builder: (context, snapshot) {
                  final data = snapshot.data ?? _payload;
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      snapshot.data == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final unreadNotifications = data.unread.system;
                  final notificationPreview = data.notifications
                      .take(_notificationPreviewCount)
                      .toList(growable: false);
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _MessageCenterSummary(
                        unreadNotifications: unreadNotifications,
                        conversationUnread: data.conversationUnread,
                      ),
                      const SizedBox(height: 22),
                      _SectionHeader(title: '聊天与私信', subtitle: '优先处理正在进行的会话'),
                      const SizedBox(height: 10),
                      _ConversationChannelSwitcher(
                        selected: _conversationChannel,
                        roomUnread: data.roomUnread,
                        privateUnread: data.privateUnread,
                        onSelected: (value) {
                          setState(() => _conversationChannel = value);
                        },
                      ),
                      const SizedBox(height: 12),
                      if (snapshot.hasError && data.isEmpty)
                        _MessageLoadFailure(
                          onRetry: () => setState(() => _future = _refresh()),
                        )
                      else if (_conversationChannel ==
                          _ConversationChannel.rooms)
                        if (data.rooms.isEmpty)
                          const InteractionEmptyState(
                            icon: Icons.forum_outlined,
                            title: '还没有群聊',
                            subtitle: '去聊天室列表加入一个房间吧',
                          )
                        else
                          ...data.rooms.map(
                            (room) => _RoomMessageTile(
                              room: room,
                              onTap: () => unawaited(_openRoom(room)),
                            ),
                          )
                      else if (data.conversations.isEmpty)
                        const InteractionEmptyState(
                          icon: Icons.mail_outline_rounded,
                          title: '还没有私信',
                          subtitle: '在用户主页点击私聊开始对话',
                        )
                      else
                        ...data.conversations.map(
                          (item) => _PrivateMessageTile(
                            conversation: item,
                            onTap: () => _openPrivate(item.peer),
                          ),
                        ),
                      const SizedBox(height: 24),
                      _SectionHeader(
                        title: '系统通知',
                        subtitle: data.notifications.isEmpty
                            ? '系统、活动、版本和审核消息会保存在这里'
                            : '仅展示最近 ${notificationPreview.length} 条',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (unreadNotifications > 0)
                              Tooltip(
                                message: '全部标为已读',
                                child: IconButton(
                                  key: const ValueKey(
                                    'message-center-mark-all-notifications',
                                  ),
                                  onPressed: _markingAllNotificationsRead
                                      ? null
                                      : () => unawaited(
                                          _markAllSystemNotificationsRead(),
                                        ),
                                  icon: _markingAllNotificationsRead
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.done_all_rounded),
                                ),
                              ),
                            if (data.notifications.isNotEmpty ||
                                unreadNotifications > 0)
                              Tooltip(
                                message: '查看全部通知',
                                child: IconButton(
                                  key: const ValueKey(
                                    'message-center-open-notification-inbox',
                                  ),
                                  onPressed: () =>
                                      unawaited(_openAllNotifications()),
                                  icon: const Icon(
                                    Icons.notifications_outlined,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (snapshot.hasError && data.isEmpty)
                        const SizedBox.shrink()
                      else if (data.notifications.isEmpty)
                        const InteractionEmptyState(
                          icon: Icons.notifications_none_rounded,
                          title: '暂无通知',
                          subtitle: '新的系统、活动和审核消息会出现在这里',
                        )
                      else ...[
                        ...notificationPreview.map(
                          (item) => _SystemNotificationTile(
                            item: item,
                            onTap: () =>
                                unawaited(_openSystemNotification(item)),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => unawaited(_openAllNotifications()),
                            icon: const Icon(Icons.list_alt_rounded),
                            label: const Text('查看全部通知'),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.mark_chat_unread_outlined,
                      size: 46,
                      color: AppTheme.primaryColor,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '登录后查看消息',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: () => unawaited(_ensureLogin()),
                      child: const Text('去登录'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class PrivateChatScreen extends StatefulWidget {
  const PrivateChatScreen({super.key, required this.peer});

  final InteractionUserBrief peer;

  @override
  State<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends State<PrivateChatScreen> {
  final InteractionService _service = InteractionService();
  final TextEditingController _controller = TextEditingController();
  late Future<List<PrivateMessage>> _future;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<List<PrivateMessage>> _load() {
    final token = context.read<InteractionAuthProvider>().token;
    return _service.fetchPrivateMessages(token: token, userId: widget.peer.id);
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;
    setState(() => _isSending = true);
    try {
      await _service.sendPrivateMessage(
        token: context.read<InteractionAuthProvider>().token,
        userId: widget.peer.id,
        content: text,
      );
      _controller.clear();
      if (mounted) setState(() => _future = _load());
    } catch (error) {
      if (!mounted) return;
      final message = error is InteractionServiceException
          ? error.message
          : '私信发送失败';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.peer.nickname)),
      backgroundColor: const Color(0xFFF4F6FB),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<PrivateMessage>>(
              future: _future,
              builder: (context, snapshot) {
                final items = snapshot.data ?? const <PrivateMessage>[];
                if (snapshot.connectionState == ConnectionState.waiting &&
                    snapshot.data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (items.isEmpty) {
                  return const InteractionEmptyState(
                    icon: Icons.mail_outline_rounded,
                    title: '还没有对话',
                    subtitle: '发一句话开始聊天',
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _PrivateBubble(message: items[index]),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              color: Colors.white,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: '输入私信',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _isSending ? null : () => unawaited(_send()),
                    icon: _isSending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageCenterPayload {
  const _MessageCenterPayload({
    this.rooms = const [],
    this.conversations = const [],
    this.notifications = const [],
    this.unread = const MessageUnreadSummary(),
  });

  final List<ChatRoomInfo> rooms;
  final List<PrivateConversation> conversations;
  final List<SystemNotificationItem> notifications;
  final MessageUnreadSummary unread;

  bool get isEmpty =>
      rooms.isEmpty && conversations.isEmpty && notifications.isEmpty;

  int get roomUnread => unread.chatMessages;

  int get privateUnread => unread.privateMessages;

  int get conversationUnread => roomUnread + privateUnread;

  _MessageCenterPayload clearRoomUnread(String roomId) {
    var changed = false;
    var clearedCount = 0;
    final nextRooms = rooms
        .map((room) {
          if (room.roomId != roomId || room.recentMessageCount == 0) {
            return room;
          }
          changed = true;
          clearedCount += room.recentMessageCount;
          return room.copyWith(recentMessageCount: 0);
        })
        .toList(growable: false);
    if (!changed) return this;
    final nextChatUnread = unread.chatMessages - clearedCount;
    final nextTotal = unread.total - clearedCount;
    return _MessageCenterPayload(
      rooms: nextRooms,
      conversations: conversations,
      notifications: notifications,
      unread: unread.copyWith(
        chatMessages: nextChatUnread < 0 ? 0 : nextChatUnread,
        total: nextTotal < 0 ? 0 : nextTotal,
      ),
    );
  }

  _MessageCenterPayload clearNotificationUnread(int id) {
    var changed = false;
    final nextNotifications = notifications
        .map((item) {
          if (item.id != id || item.readAt.isNotEmpty) return item;
          changed = true;
          return SystemNotificationItem(
            id: item.id,
            title: item.title,
            content: item.content,
            category: item.category,
            readAt: DateTime.now().toIso8601String(),
            createdAt: item.createdAt,
          );
        })
        .toList(growable: false);
    if (!changed) return this;
    final nextSystemUnread = unread.system - 1;
    final nextTotal = unread.total - 1;
    return _MessageCenterPayload(
      rooms: rooms,
      conversations: conversations,
      notifications: nextNotifications,
      unread: unread.copyWith(
        system: nextSystemUnread < 0 ? 0 : nextSystemUnread,
        total: nextTotal < 0 ? 0 : nextTotal,
      ),
    );
  }

  _MessageCenterPayload clearAllNotificationUnread(
    MessageUnreadSummary nextUnread,
  ) {
    final readAt = DateTime.now().toIso8601String();
    final nextNotifications = notifications
        .map(
          (item) => item.readAt.isEmpty
              ? SystemNotificationItem(
                  id: item.id,
                  title: item.title,
                  content: item.content,
                  category: item.category,
                  readAt: readAt,
                  createdAt: item.createdAt,
                )
              : item,
        )
        .toList(growable: false);
    return _MessageCenterPayload(
      rooms: rooms,
      conversations: conversations,
      notifications: nextNotifications,
      unread: nextUnread,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        if (trailing case final Widget value) value,
      ],
    );
  }
}

enum _NotificationFilter {
  all,
  unread,
  system,
  update,
  operation,
  security,
  growth,
  race,
  aiNovel,
}

enum _ConversationChannel { rooms, private }

List<_NotificationFilter> _availableNotificationFilters(
  List<SystemNotificationItem> items,
) {
  const categories = [
    _NotificationFilter.system,
    _NotificationFilter.update,
    _NotificationFilter.operation,
    _NotificationFilter.security,
    _NotificationFilter.growth,
    _NotificationFilter.race,
    _NotificationFilter.aiNovel,
  ];
  return [
    _NotificationFilter.all,
    if (items.any((item) => item.readAt.isEmpty)) _NotificationFilter.unread,
    ...categories.where(
      (filter) => items.any((item) => _matchesNotificationFilter(item, filter)),
    ),
  ];
}

class _MessageCenterSummary extends StatelessWidget {
  const _MessageCenterSummary({
    required this.unreadNotifications,
    required this.conversationUnread,
  });

  final int unreadNotifications;
  final int conversationUnread;

  @override
  Widget build(BuildContext context) {
    final total = unreadNotifications + conversationUnread;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFDCE6F5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFE9F2FF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.mark_email_unread_outlined,
              color: AppTheme.primaryColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  total == 0 ? '全部消息已读' : '有 $total 条未读消息',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  unreadNotifications == 0 && conversationUnread == 0
                      ? '通知和会话都会按最新状态显示'
                      : '通知 $unreadNotifications 条 · 会话 $conversationUnread 条',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
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

class _NotificationFilterBar extends StatelessWidget {
  const _NotificationFilterBar({
    required this.filters,
    required this.selected,
    required this.items,
    required this.onSelected,
  });

  final List<_NotificationFilter> filters;
  final _NotificationFilter selected;
  final List<SystemNotificationItem> items;
  final ValueChanged<_NotificationFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters
            .map((filter) {
              final count = items
                  .where((item) => _matchesNotificationFilter(item, filter))
                  .length;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text('${_notificationFilterLabel(filter)} $count'),
                  selected: selected == filter,
                  onSelected: (_) => onSelected(filter),
                  avatar: Icon(
                    _notificationFilterIcon(filter),
                    size: 16,
                    color: selected == filter
                        ? AppTheme.primaryColor
                        : AppTheme.textSecondary,
                  ),
                  side: BorderSide(
                    color: selected == filter
                        ? const Color(0xFF9EC2FF)
                        : const Color(0xFFE3E7EE),
                  ),
                  backgroundColor: Colors.white,
                  selectedColor: const Color(0xFFEAF2FF),
                  labelStyle: TextStyle(
                    color: selected == filter
                        ? AppTheme.primaryDark
                        : AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: selected == filter
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              );
            })
            .toList(growable: false),
      ),
    );
  }
}

class _ConversationChannelSwitcher extends StatelessWidget {
  const _ConversationChannelSwitcher({
    required this.selected,
    required this.roomUnread,
    required this.privateUnread,
    required this.onSelected,
  });

  final _ConversationChannel selected;
  final int roomUnread;
  final int privateUnread;
  final ValueChanged<_ConversationChannel> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_ConversationChannel>(
      segments: [
        ButtonSegment(
          value: _ConversationChannel.rooms,
          icon: const Icon(Icons.forum_outlined, size: 18),
          label: Text(roomUnread == 0 ? '群聊' : '群聊 $roomUnread'),
        ),
        ButtonSegment(
          value: _ConversationChannel.private,
          icon: const Icon(Icons.mail_outline_rounded, size: 18),
          label: Text(privateUnread == 0 ? '私信' : '私信 $privateUnread'),
        ),
      ],
      selected: {selected},
      onSelectionChanged: (value) => onSelected(value.first),
    );
  }
}

class _MessageLoadFailure extends StatelessWidget {
  const _MessageLoadFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFF0D7D7)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            color: AppTheme.textSecondary,
            size: 34,
          ),
          const SizedBox(height: 9),
          const Text('消息加载失败', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(
            '请检查网络后重新加载',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新加载'),
          ),
        ],
      ),
    );
  }
}

class _RoomMessageTile extends StatelessWidget {
  const _RoomMessageTile({required this.room, required this.onTap});

  final ChatRoomInfo room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _MessageTileFrame(
      icon: Icons.forum_outlined,
      color: AppTheme.primaryColor,
      title: room.displayName,
      subtitle: room.latestContent.isEmpty ? '暂无最近消息' : room.latestContent,
      trailing: room.isJoined ? '已加入' : room.displayCategoryLabel,
      unread: room.recentMessageCount,
      onTap: onTap,
    );
  }
}

class _PrivateMessageTile extends StatelessWidget {
  const _PrivateMessageTile({required this.conversation, required this.onTap});

  final PrivateConversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _MessageTileFrame(
      icon: Icons.person_outline_rounded,
      color: const Color(0xFF7C3AED),
      title: conversation.peer.nickname,
      subtitle: conversation.latestContent.isEmpty
          ? '打开私信'
          : conversation.latestContent,
      trailing: conversation.fromMe ? '我' : '',
      unread: conversation.unreadCount,
      onTap: onTap,
    );
  }
}

class _SystemNotificationTile extends StatelessWidget {
  const _SystemNotificationTile({required this.item, required this.onTap});

  final SystemNotificationItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final presentation = _notificationPresentation(item.category);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(13, 13, 12, 13),
          decoration: BoxDecoration(
            border: Border.all(
              color: item.readAt.isEmpty
                  ? presentation.color.withValues(alpha: 0.36)
                  : const Color(0xFFE8EBF0),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: presentation.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  presentation.icon,
                  color: presentation.color,
                  size: 21,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title.isEmpty ? '系统通知' : item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 15,
                              fontWeight: item.readAt.isEmpty
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (item.readAt.isEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppTheme.accentColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: presentation.background,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            presentation.label,
                            style: TextStyle(
                              color: presentation.color,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _relativeNotificationTime(item.createdAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textHint,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      item.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Padding(
                padding: EdgeInsets.only(top: 13),
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.textHint,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SystemNotificationInboxScreen extends StatefulWidget {
  const _SystemNotificationInboxScreen({required this.service});

  final InteractionService service;

  @override
  State<_SystemNotificationInboxScreen> createState() =>
      _SystemNotificationInboxScreenState();
}

class _SystemNotificationInboxScreenState
    extends State<_SystemNotificationInboxScreen> {
  static const _pageSize = 30;

  final List<SystemNotificationItem> _notifications = [];
  _NotificationFilter _filter = _NotificationFilter.all;
  int _nextBeforeId = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _markingAllRead = false;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPage(reset: true));
  }

  Future<void> _loadPage({required bool reset}) async {
    if (_loading) return;
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) return;

    final beforeId = reset ? 0 : _nextBeforeId;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final page = await widget.service.fetchSystemNotifications(
        token: auth.token,
        beforeId: beforeId,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _notifications
            ..clear()
            ..addAll(page);
        } else {
          final knownIds = _notifications.map((item) => item.id).toSet();
          _notifications.addAll(page.where((item) => knownIds.add(item.id)));
        }
        _nextBeforeId = _notifications.isEmpty ? 0 : _notifications.last.id;
        _hasMore = page.length == _pageSize;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markAllRead() async {
    if (_markingAllRead || _notifications.isEmpty) return;
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) return;

    setState(() => _markingAllRead = true);
    try {
      await widget.service.markAllSystemNotificationsRead(token: auth.token);
      if (!mounted) return;
      final readAt = DateTime.now().toIso8601String();
      setState(() {
        for (var index = 0; index < _notifications.length; index++) {
          final item = _notifications[index];
          if (item.readAt.isEmpty) {
            _notifications[index] = SystemNotificationItem(
              id: item.id,
              title: item.title,
              content: item.content,
              category: item.category,
              readAt: readAt,
              createdAt: item.createdAt,
            );
          }
        }
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('全部标为已读失败，请稍后重试')));
    } finally {
      if (mounted) setState(() => _markingAllRead = false);
    }
  }

  Future<void> _markNotificationRead(int id) async {
    try {
      await widget.service.markSystemNotificationRead(
        token: context.read<InteractionAuthProvider>().token,
        id: id,
      );
    } catch (_) {
      // The next refresh restores the server state if marking this item fails.
    }
  }

  Future<void> _openNotification(SystemNotificationItem item) async {
    var detailItem = item;
    if (item.readAt.isEmpty) {
      final readAt = DateTime.now().toIso8601String();
      detailItem = SystemNotificationItem(
        id: item.id,
        title: item.title,
        content: item.content,
        category: item.category,
        readAt: readAt,
        createdAt: item.createdAt,
      );
      setState(() {
        final index = _notifications.indexWhere((value) => value.id == item.id);
        if (index >= 0) _notifications[index] = detailItem;
      });
      unawaited(_markNotificationRead(item.id));
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SystemNotificationDetailScreen(item: detailItem),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filters = _availableNotificationFilters(_notifications);
    final selectedFilter = filters.contains(_filter)
        ? _filter
        : _NotificationFilter.all;
    final visibleNotifications = _notifications
        .where((item) => _matchesNotificationFilter(item, selectedFilter))
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('全部通知'),
        actions: [
          if (_notifications.isNotEmpty)
            IconButton(
              key: const ValueKey('notification-inbox-mark-all-read'),
              tooltip: '全部标为已读',
              onPressed: _markingAllRead
                  ? null
                  : () => unawaited(_markAllRead()),
              icon: _markingAllRead
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.done_all_rounded),
            ),
        ],
      ),
      backgroundColor: const Color(0xFFF7F8FC),
      body: _loading && _notifications.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _loadPage(reset: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                children: [
                  if (_loadError != null && _notifications.isEmpty)
                    _MessageLoadFailure(
                      onRetry: () => unawaited(_loadPage(reset: true)),
                    )
                  else if (_notifications.isEmpty)
                    const InteractionEmptyState(
                      icon: Icons.notifications_none_rounded,
                      title: '暂无通知',
                      subtitle: '新的系统、活动、版本和审核消息会出现在这里',
                    )
                  else ...[
                    _NotificationFilterBar(
                      filters: filters,
                      selected: selectedFilter,
                      items: _notifications,
                      onSelected: (value) => setState(() => _filter = value),
                    ),
                    const SizedBox(height: 12),
                    if (visibleNotifications.isEmpty)
                      const InteractionEmptyState(
                        icon: Icons.filter_alt_off_outlined,
                        title: '没有匹配的通知',
                        subtitle: '切换分类查看其他通知',
                      )
                    else
                      ...visibleNotifications.map(
                        (item) => _SystemNotificationTile(
                          item: item,
                          onTap: () => unawaited(_openNotification(item)),
                        ),
                      ),
                    if (_hasMore) ...[
                      const SizedBox(height: 4),
                      Center(
                        child: OutlinedButton.icon(
                          onPressed: _loading
                              ? null
                              : () => unawaited(_loadPage(reset: false)),
                          icon: _loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.expand_more_rounded),
                          label: Text(_loading ? '正在加载' : '加载更多通知'),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
    );
  }
}

class _SystemNotificationDetailScreen extends StatelessWidget {
  const _SystemNotificationDetailScreen({required this.item});

  final SystemNotificationItem item;

  @override
  Widget build(BuildContext context) {
    final presentation = _notificationPresentation(item.category);
    return Scaffold(
      appBar: AppBar(title: const Text('通知详情')),
      backgroundColor: const Color(0xFFF7F8FC),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE5E9F0)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: presentation.background,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        presentation.icon,
                        color: presentation.color,
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            presentation.label,
                            style: TextStyle(
                              color: presentation.color,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _fullNotificationTime(item.createdAt),
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  item.title.isEmpty ? '系统通知' : item.title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    height: 1.35,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Divider(height: 1),
                ),
                SelectableText(
                  item.content.isEmpty ? '暂无正文内容' : item.content,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    height: 1.72,
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

class _NotificationPresentation {
  const _NotificationPresentation({
    required this.filter,
    required this.label,
    required this.icon,
    required this.color,
    required this.background,
  });

  final _NotificationFilter filter;
  final String label;
  final IconData icon;
  final Color color;
  final Color background;
}

_NotificationPresentation _notificationPresentation(String category) {
  switch (category.trim().toLowerCase()) {
    case 'update':
      return const _NotificationPresentation(
        filter: _NotificationFilter.update,
        label: '版本更新',
        icon: Icons.system_update_alt_rounded,
        color: Color(0xFF5B63C8),
        background: Color(0xFFEEF0FF),
      );
    case 'operation':
      return const _NotificationPresentation(
        filter: _NotificationFilter.operation,
        label: '运营活动',
        icon: Icons.local_activity_outlined,
        color: Color(0xFFBD5A74),
        background: Color(0xFFFFEEF2),
      );
    case 'security':
      return const _NotificationPresentation(
        filter: _NotificationFilter.security,
        label: '安全提醒',
        icon: Icons.shield_outlined,
        color: Color(0xFFC35353),
        background: Color(0xFFFFEEEE),
      );
    case 'growth':
      return const _NotificationPresentation(
        filter: _NotificationFilter.growth,
        label: '成长运营',
        icon: Icons.trending_up_rounded,
        color: Color(0xFF2D8A68),
        background: Color(0xFFEAF8F1),
      );
    case 'race':
    case 'horse_race':
    case 'horse_race_responsible':
      return const _NotificationPresentation(
        filter: _NotificationFilter.race,
        label: '赛事与玩法',
        icon: Icons.emoji_events_outlined,
        color: Color(0xFFB87925),
        background: Color(0xFFFFF5E6),
      );
    case 'ai_novel':
    case 'ai_novel_review':
      return const _NotificationPresentation(
        filter: _NotificationFilter.aiNovel,
        label: 'AI 小说',
        icon: Icons.auto_awesome_outlined,
        color: Color(0xFF805AC6),
        background: Color(0xFFF4EEFF),
      );
    case 'system':
    default:
      return const _NotificationPresentation(
        filter: _NotificationFilter.system,
        label: '系统与账号',
        icon: Icons.settings_outlined,
        color: Color(0xFF3979B7),
        background: Color(0xFFEAF4FF),
      );
  }
}

bool _matchesNotificationFilter(
  SystemNotificationItem item,
  _NotificationFilter filter,
) {
  if (filter == _NotificationFilter.all) return true;
  if (filter == _NotificationFilter.unread) return item.readAt.isEmpty;
  return _notificationPresentation(item.category).filter == filter;
}

String _notificationFilterLabel(_NotificationFilter filter) {
  return switch (filter) {
    _NotificationFilter.all => '全部',
    _NotificationFilter.unread => '未读',
    _NotificationFilter.system => '系统与账号',
    _NotificationFilter.update => '版本更新',
    _NotificationFilter.operation => '运营活动',
    _NotificationFilter.security => '安全提醒',
    _NotificationFilter.growth => '成长运营',
    _NotificationFilter.race => '赛事与玩法',
    _NotificationFilter.aiNovel => 'AI 小说',
  };
}

IconData _notificationFilterIcon(_NotificationFilter filter) {
  return switch (filter) {
    _NotificationFilter.all => Icons.notifications_none_rounded,
    _NotificationFilter.unread => Icons.mark_email_unread_outlined,
    _NotificationFilter.system => Icons.settings_outlined,
    _NotificationFilter.update => Icons.system_update_alt_rounded,
    _NotificationFilter.operation => Icons.local_activity_outlined,
    _NotificationFilter.security => Icons.shield_outlined,
    _NotificationFilter.growth => Icons.trending_up_rounded,
    _NotificationFilter.race => Icons.emoji_events_outlined,
    _NotificationFilter.aiNovel => Icons.auto_awesome_outlined,
  };
}

String _relativeNotificationTime(String rawValue) {
  final value = _notificationDate(rawValue);
  if (value == null) return rawValue;
  final difference = DateTime.now().difference(value);
  if (difference.inMinutes <= 0) return '刚刚';
  if (difference.inHours == 0) return '${difference.inMinutes} 分钟前';
  if (difference.inDays == 0) return '${difference.inHours} 小时前';
  if (difference.inDays == 1) return '昨天';
  if (value.year == DateTime.now().year) {
    return '${_twoDigits(value.month)}-${_twoDigits(value.day)}';
  }
  return '${value.year}-${_twoDigits(value.month)}-${_twoDigits(value.day)}';
}

String _fullNotificationTime(String rawValue) {
  final value = _notificationDate(rawValue);
  if (value == null) return rawValue.isEmpty ? '时间未知' : rawValue;
  return '${value.year}-${_twoDigits(value.month)}-${_twoDigits(value.day)} '
      '${_twoDigits(value.hour)}:${_twoDigits(value.minute)}';
}

DateTime? _notificationDate(String rawValue) {
  final normalized = rawValue.trim().replaceFirst(' ', 'T');
  final value = DateTime.tryParse(normalized);
  if (value == null) return null;
  return value.isUtc ? value.toLocal() : value;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

class _MessageTileFrame extends StatelessWidget {
  const _MessageTileFrame({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.unread,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String trailing;
  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? '用户' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
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
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (trailing.isNotEmpty)
                  Text(
                    trailing,
                    style: const TextStyle(
                      color: AppTheme.textHint,
                      fontSize: 11,
                    ),
                  ),
                const SizedBox(height: 8),
                if (unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivateBubble extends StatelessWidget {
  const _PrivateBubble({required this.message});

  final PrivateMessage message;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: message.fromMe ? AppTheme.primaryColor : Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          message.content,
          style: TextStyle(
            color: message.fromMe ? Colors.white : AppTheme.textPrimary,
            height: 1.35,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
