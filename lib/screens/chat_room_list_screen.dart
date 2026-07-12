import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/theme.dart';
import '../models/interaction_models.dart';
import '../providers/interaction_auth_provider.dart';
import '../services/interaction_service.dart';
import '../widgets/interaction_ui.dart';
import 'chat_room_screen.dart';
import 'interaction_auth_screen.dart';

class ChatRoomListScreen extends StatefulWidget {
  const ChatRoomListScreen({super.key});

  @override
  State<ChatRoomListScreen> createState() => _ChatRoomListScreenState();
}

class _ChatRoomListScreenState extends State<ChatRoomListScreen> {
  final InteractionService _service = InteractionService();
  final Set<String> _expandedKeys = {};

  late Future<ChatRoomListPayload> _roomsFuture;

  @override
  void initState() {
    super.initState();
    _roomsFuture = _loadRooms();
  }

  Future<ChatRoomListPayload> _loadRooms() {
    final auth = context.read<InteractionAuthProvider>();
    return _service.fetchChatRooms(token: auth.token);
  }

  Future<void> _refresh() async {
    setState(() => _roomsFuture = _loadRooms());
    await _roomsFuture;
  }

  bool _isAdmin(InteractionAuthProvider auth) {
    final role = auth.user?.role.trim().toLowerCase() ?? '';
    return role == 'admin' ||
        role == 'super_admin' ||
        role == 'owner' ||
        role == 'moderator' ||
        role.endsWith('_admin');
  }

  void _toggleCategory(String key) {
    setState(() {
      if (_expandedKeys.contains(key)) {
        _expandedKeys.remove(key);
      } else {
        _expandedKeys.add(key);
      }
    });
  }

  void _openRoom(ChatRoomInfo room) {
    if (!room.canEnter) {
      final levelText = room.minLevel > 0 ? 'Lv${room.minLevel}' : '当前等级';
      _showMessage('需要 $levelText 才能进入这个聊天室');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatRoomScreen(roomId: room.roomId, title: room.displayName),
      ),
    );
  }

  Future<bool> _ensureAdminSession() async {
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
      );
      if (!mounted) return false;
    }
    final latest = context.read<InteractionAuthProvider>();
    if (_isAdmin(latest)) return true;
    _showMessage('当前账号没有聊天室管理权限');
    return false;
  }

  Future<void> _openRoomEditor({
    ChatRoomInfo? room,
    String? categoryKey,
  }) async {
    if (!await _ensureAdminSession()) return;
    if (!mounted) return;
    final draft = await showModalBottomSheet<_ChatRoomDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) =>
          _ChatRoomEditorSheet(room: room, initialCategory: categoryKey),
    );
    if (draft == null || !mounted) return;

    final auth = context.read<InteractionAuthProvider>();
    try {
      if (room == null) {
        await _service.createChatRoom(
          token: auth.token,
          name: draft.name,
          category: draft.category,
          avatarUrl: draft.avatarUrl,
          minLevel: draft.minLevel,
          botEnabled: draft.botEnabled,
        );
        _showMessage('聊天室已创建');
      } else {
        await _service.updateChatRoom(
          token: auth.token,
          roomId: room.roomId,
          name: draft.name,
          category: draft.category,
          avatarUrl: draft.avatarUrl,
          minLevel: draft.minLevel,
          botEnabled: draft.botEnabled,
        );
        _showMessage('聊天室已更新');
      }
      await _refresh();
    } catch (error) {
      _showMessage('聊天室管理接口暂不可用：$error');
    }
  }

  Future<void> _dissolveRoom(ChatRoomInfo room) async {
    if (!await _ensureAdminSession()) return;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解散聊天室'),
        content: Text('确定要解散「${room.displayName}」吗？解散后成员关系会清空，历史消息会被隐藏。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accentColor,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('解散'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final auth = context.read<InteractionAuthProvider>();
    try {
      await _service.dissolveChatRoom(token: auth.token, roomId: room.roomId);
      _showMessage('聊天室已解散');
      await _refresh();
    } catch (error) {
      _showMessage('解散失败：$error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<InteractionAuthProvider>();
    final isAdmin = _isAdmin(auth);
    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天室'),
        actions: [
          if (isAdmin)
            IconButton(
              tooltip: '创建聊天室',
              onPressed: () => _openRoomEditor(),
              icon: const Icon(Icons.add_comment_outlined),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => setState(() => _roomsFuture = _loadRooms()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: FutureBuilder<ChatRoomListPayload>(
        future: _roomsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  InteractionEmptyState(
                    icon: Icons.wifi_off_outlined,
                    title: '聊天室加载失败',
                    subtitle: '下拉刷新后重试，或稍后再回来看看。',
                  ),
                ],
              ),
            );
          }
          final payload = snapshot.data ?? const ChatRoomListPayload();
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _ChatRoomListIntro(isAdmin: isAdmin),
                const SizedBox(height: 12),
                for (final category in payload.categories) ...[
                  _ChatCategorySection(
                    category: category,
                    expanded: _expandedKeys.contains(category.key),
                    isAdmin: isAdmin,
                    onToggle: () => _toggleCategory(category.key),
                    onCreate: () => _openRoomEditor(categoryKey: category.key),
                    onEdit: (room) => _openRoomEditor(room: room),
                    onDissolve: _dissolveRoom,
                    onOpenRoom: _openRoom,
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ChatRoomListIntro extends StatelessWidget {
  const _ChatRoomListIntro({required this.isAdmin});

  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.dividerColor),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.forum_outlined,
              color: AppTheme.primaryColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '选择聊天室',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isAdmin ? '分类默认收起，管理员可创建或编辑房间。' : '展开分类后选择房间进入实时聊天。',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    height: 1.35,
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

class _ChatCategorySection extends StatelessWidget {
  const _ChatCategorySection({
    required this.category,
    required this.expanded,
    required this.isAdmin,
    required this.onToggle,
    required this.onCreate,
    required this.onEdit,
    required this.onDissolve,
    required this.onOpenRoom,
  });

  final ChatRoomCategory category;
  final bool expanded;
  final bool isAdmin;
  final VoidCallback onToggle;
  final VoidCallback onCreate;
  final ValueChanged<ChatRoomInfo> onEdit;
  final ValueChanged<ChatRoomInfo> onDissolve;
  final ValueChanged<ChatRoomInfo> onOpenRoom;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: category.hot
                ? AppTheme.accentColor.withValues(alpha: 0.35)
                : AppTheme.dividerColor,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Row(
                  children: [
                    _CategoryIcon(keyName: category.key),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              category.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          if (category.hot) ...[
                            const SizedBox(width: 8),
                            const _HotBadge(),
                          ],
                        ],
                      ),
                    ),
                    Text(
                      '${category.rooms.length} 个',
                      style: const TextStyle(
                        color: AppTheme.textHint,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: AppTheme.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded) ...[
              const Divider(height: 1, color: AppTheme.dividerColor),
              if (category.rooms.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '这个分类还没有聊天室',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (isAdmin)
                        TextButton.icon(
                          onPressed: onCreate,
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('创建'),
                        ),
                    ],
                  ),
                )
              else
                for (final room in category.rooms)
                  _ChatRoomTile(
                    room: room,
                    isAdmin: isAdmin,
                    onTap: () => onOpenRoom(room),
                    onEdit: () => onEdit(room),
                    onDissolve: () => onDissolve(room),
                  ),
              if (isAdmin && category.rooms.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: TextButton.icon(
                      onPressed: onCreate,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('新建这个分类的聊天室'),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChatRoomTile extends StatelessWidget {
  const _ChatRoomTile({
    required this.room,
    required this.isAdmin,
    required this.onTap,
    required this.onEdit,
    required this.onDissolve,
  });

  final ChatRoomInfo room;
  final bool isAdmin;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDissolve;

  @override
  Widget build(BuildContext context) {
    final latest = room.latestContent.isEmpty ? '暂无最近消息' : room.latestContent;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            _RoomAvatar(room: room),
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
                          style: TextStyle(
                            color: room.canEnter
                                ? AppTheme.textPrimary
                                : AppTheme.textHint,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      if (room.isOfficial)
                        const _MiniBadge(
                          label: '官方',
                          color: AppTheme.primaryColor,
                        ),
                      if (room.botEnabled) ...[
                        const SizedBox(width: 5),
                        const _MiniBadge(
                          label: '机器人',
                          color: Color(0xFF13A884),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    latest,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _RoomMeta(
                        icon: Icons.people_outline,
                        text: '${room.activeUserCount} 人在线',
                      ),
                      _RoomMeta(
                        icon: Icons.chat_bubble_outline,
                        text: '${room.recentMessageCount} 条新消息',
                      ),
                      _RoomMeta(
                        icon: room.canEnter
                            ? Icons.lock_open_outlined
                            : Icons.lock_outline,
                        text: room.minLevel > 0
                            ? 'Lv${room.minLevel}+'
                            : '不限等级',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isAdmin)
              PopupMenuButton<String>(
                tooltip: '聊天室管理',
                onSelected: (value) {
                  if (value == 'edit') onEdit();
                  if (value == 'dissolve') onDissolve();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('编辑'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'dissolve',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_forever_outlined),
                      title: Text('解散聊天室'),
                    ),
                  ),
                ],
                icon: const Icon(Icons.more_vert_rounded, size: 22),
              )
            else
              Icon(
                room.canEnter
                    ? Icons.chevron_right_rounded
                    : Icons.lock_outline_rounded,
                color: AppTheme.textHint,
              ),
          ],
        ),
      ),
    );
  }
}

class _RoomAvatar extends StatelessWidget {
  const _RoomAvatar({required this.room});

  final ChatRoomInfo room;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 48,
        height: 48,
        color: _categoryColor(room.category).withValues(alpha: 0.12),
        child: room.avatarUrl.isEmpty
            ? Icon(
                _categoryIcon(room.category),
                color: _categoryColor(room.category),
              )
            : Image.network(
                room.avatarUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  _categoryIcon(room.category),
                  color: _categoryColor(room.category),
                ),
              ),
      ),
    );
  }
}

class _CategoryIcon extends StatelessWidget {
  const _CategoryIcon({required this.keyName});

  final String keyName;

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(keyName);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(_categoryIcon(keyName), color: color, size: 20),
    );
  }
}

class _HotBadge extends StatelessWidget {
  const _HotBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        '聊得火热',
        style: TextStyle(
          color: AppTheme.accentColor,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _RoomMeta extends StatelessWidget {
  const _RoomMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppTheme.textHint),
        const SizedBox(width: 3),
        Text(
          text,
          style: const TextStyle(
            color: AppTheme.textHint,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ChatRoomEditorSheet extends StatefulWidget {
  const _ChatRoomEditorSheet({this.room, this.initialCategory});

  final ChatRoomInfo? room;
  final String? initialCategory;

  @override
  State<_ChatRoomEditorSheet> createState() => _ChatRoomEditorSheetState();
}

class _ChatRoomEditorSheetState extends State<_ChatRoomEditorSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _avatarController;
  late final TextEditingController _minLevelController;
  late String _category;
  late bool _botEnabled;

  @override
  void initState() {
    super.initState();
    final room = widget.room;
    _nameController = TextEditingController(text: room?.name ?? '');
    _avatarController = TextEditingController(text: room?.avatarUrl ?? '');
    _minLevelController = TextEditingController(
      text: (room?.minLevel ?? 0) <= 0 ? '' : room!.minLevel.toString(),
    );
    _category = room?.category ?? widget.initialCategory ?? 'novel';
    _botEnabled = room?.botEnabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _avatarController.dispose();
    _minLevelController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请输入聊天室名称')));
      return;
    }
    Navigator.pop(
      context,
      _ChatRoomDraft(
        name: name,
        category: _category,
        avatarUrl: _avatarController.text.trim(),
        minLevel: int.tryParse(_minLevelController.text.trim()) ?? 0,
        botEnabled: _botEnabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.room != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isEditing ? '编辑聊天室' : '创建聊天室',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _nameController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '名称',
              prefixIcon: Icon(Icons.forum_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(
              labelText: '分类',
              prefixIcon: Icon(Icons.category_outlined),
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'novel', child: Text('小说')),
              DropdownMenuItem(value: 'anime', child: Text('动漫')),
              DropdownMenuItem(value: 'manga', child: Text('漫画')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _category = value);
            },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _minLevelController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '入场等级',
              hintText: '0 表示不限等级',
              prefixIcon: Icon(Icons.workspace_premium_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _avatarController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '头像 URL',
              prefixIcon: Icon(Icons.image_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _botEnabled,
            onChanged: (value) => setState(() => _botEnabled = value),
            title: const Text('启用小机器人'),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.check_rounded),
              label: Text(isEditing ? '保存' : '创建'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatRoomDraft {
  const _ChatRoomDraft({
    required this.name,
    required this.category,
    required this.avatarUrl,
    required this.minLevel,
    required this.botEnabled,
  });

  final String name;
  final String category;
  final String avatarUrl;
  final int minLevel;
  final bool botEnabled;
}

IconData _categoryIcon(String category) {
  return switch (category) {
    'anime' => Icons.movie_filter_outlined,
    'manga' => Icons.auto_stories_outlined,
    _ => Icons.menu_book_outlined,
  };
}

Color _categoryColor(String category) {
  return switch (category) {
    'anime' => const Color(0xFF13A884),
    'manga' => const Color(0xFFE16B3A),
    _ => AppTheme.primaryColor,
  };
}
