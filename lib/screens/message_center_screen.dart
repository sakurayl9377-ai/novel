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

class MessageCenterScreen extends StatefulWidget {
  const MessageCenterScreen({super.key});

  @override
  State<MessageCenterScreen> createState() => _MessageCenterScreenState();
}

class _MessageCenterScreenState extends State<MessageCenterScreen> {
  final InteractionService _service = InteractionService();
  late Future<_MessageCenterPayload> _future;
  _MessageCenterPayload _payload = const _MessageCenterPayload();

  @override
  void initState() {
    super.initState();
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
      _service.fetchSystemNotifications(token: auth.token),
    ]);
    return _MessageCenterPayload(
      rooms: (results[0] as ChatRoomListPayload).items,
      conversations: results[1] as List<PrivateConversation>,
      notifications: results[2] as List<SystemNotificationItem>,
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
      unawaited(
        _service.markSystemNotificationRead(token: auth.token, id: item.id),
      );
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title.isEmpty ? '系统通知' : item.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                item.content,
                style: const TextStyle(fontSize: 15, height: 1.45),
              ),
            ],
          ),
        ),
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
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _SectionHeader(title: '系统通知', subtitle: '赛马结算和账号提醒'),
                      const SizedBox(height: 8),
                      if (data.notifications.isEmpty)
                        const InteractionEmptyState(
                          icon: Icons.notifications_none_rounded,
                          title: '暂无通知',
                          subtitle: '新的系统消息会出现在这里',
                        )
                      else
                        ...data.notifications
                            .take(8)
                            .map(
                              (item) => _SystemNotificationTile(
                                item: item,
                                onTap: () =>
                                    unawaited(_openSystemNotification(item)),
                              ),
                            ),
                      const SizedBox(height: 18),
                      _SectionHeader(title: '群聊', subtitle: '加入过的聊天室和官方房间'),
                      const SizedBox(height: 8),
                      if (data.rooms.isEmpty)
                        const InteractionEmptyState(
                          icon: Icons.forum_outlined,
                          title: '还没有群聊',
                          subtitle: '去聊天室列表加入一个房间吧',
                        )
                      else
                        ...data.rooms
                            .take(8)
                            .map(
                              (room) => _RoomMessageTile(
                                room: room,
                                onTap: () => unawaited(_openRoom(room)),
                              ),
                            ),
                      const SizedBox(height: 18),
                      _SectionHeader(title: '私信', subtitle: '和用户的一对一聊天'),
                      const SizedBox(height: 8),
                      if (data.conversations.isEmpty)
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
  });

  final List<ChatRoomInfo> rooms;
  final List<PrivateConversation> conversations;
  final List<SystemNotificationItem> notifications;

  _MessageCenterPayload clearRoomUnread(String roomId) {
    var changed = false;
    final nextRooms = rooms
        .map((room) {
          if (room.roomId != roomId || room.recentMessageCount == 0) {
            return room;
          }
          changed = true;
          return room.copyWith(recentMessageCount: 0);
        })
        .toList(growable: false);
    if (!changed) return this;
    return _MessageCenterPayload(
      rooms: nextRooms,
      conversations: conversations,
      notifications: notifications,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

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
      ],
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
    return _MessageTileFrame(
      icon: Icons.notifications_active_outlined,
      color: const Color(0xFFF59E0B),
      title: item.title.isEmpty ? '系统通知' : item.title,
      subtitle: item.content,
      trailing: item.createdAt,
      unread: item.readAt.isEmpty ? 1 : 0,
      onTap: onTap,
    );
  }
}

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
