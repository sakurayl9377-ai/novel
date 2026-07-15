part of 'chat_room_screen.dart';

abstract class _ChatRoomRoomState extends _ChatRoomComposerState {
  @override
  Future<void> _loadRoomSnapshot({required bool showError}) async {
    if (_isLoadingRoomSnapshot) return;
    final membershipRevision = _roomMembershipRevision;
    if (mounted) setState(() => _isLoadingRoomSnapshot = true);
    try {
      final auth = context.read<InteractionAuthProvider>();
      final found = await _service.fetchChatRoom(
        roomId: widget.roomId,
        token: auth.token,
      );
      if (!mounted || membershipRevision != _roomMembershipRevision) return;
      setState(() {
        _roomSnapshot = found;
        _isJoinedRoom = found.isJoined;
      });
    } catch (_) {
      if (mounted &&
          showError &&
          membershipRevision == _roomMembershipRevision) {
        _showMessage('聊天室信息加载失败');
      }
    } finally {
      if (mounted) setState(() => _isLoadingRoomSnapshot = false);
    }
  }

  @override
  ChatRoomInfo _roomInfoForDisplay() {
    return _roomSnapshot ??
        ChatRoomInfo(roomId: widget.roomId, name: widget.title);
  }

  Future<void> _openRoomInfoSheet() async {
    if (_roomSnapshot == null && !_isLoadingRoomSnapshot) {
      await _loadRoomSnapshot(showError: true);
    }
    if (!mounted) return;
    final currentUserId = context.read<InteractionAuthProvider>().user?.id ?? 0;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.58,
        minChildSize: 0.28,
        maxChildSize: 0.96,
        snap: true,
        snapSizes: const [0.42, 0.58, 0.96],
        builder: (context, scrollController) => _ChatRoomInfoSheet(
          room: _roomInfoForDisplay(),
          isLoading: _isLoadingRoomSnapshot,
          canLeave: _isJoinedRoom,
          currentUserId: currentUserId,
          scrollController: scrollController,
          onLeave: () {
            Navigator.pop(sheetContext);
            unawaited(_leaveCurrentRoom());
          },
          onSearch: () {
            Navigator.pop(sheetContext);
            unawaited(_openMessageSearchSheet());
          },
          onMention: (member) {
            Navigator.pop(sheetContext);
            _insertMention(member.nickname);
          },
          onOpenMember: (member) {
            Navigator.pop(sheetContext);
            unawaited(_openMemberProfile(member));
          },
        ),
      ),
    );
  }

  Future<void> _joinCurrentRoom() async {
    if (_isJoiningRoom) return;
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
      );
      if (!mounted || !context.read<InteractionAuthProvider>().isLoggedIn) {
        return;
      }
    }
    setState(() => _isJoiningRoom = true);
    try {
      final joined = await _service.joinChatRoom(
        token: context.read<InteractionAuthProvider>().token,
        roomId: widget.roomId,
      );
      if (!mounted) return;
      setState(() {
        _roomMembershipRevision += 1;
        _roomSnapshot = joined;
        _isJoinedRoom = true;
      });
      unawaited(_connect(announceEntrance: true));
      _showMessage('已加入聊天室');
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        error is InteractionServiceException ? error.message : '加入失败',
      );
    } finally {
      if (mounted) setState(() => _isJoiningRoom = false);
    }
  }

  Future<void> _leaveCurrentRoom() async {
    final auth = context.read<InteractionAuthProvider>();
    if (!auth.isLoggedIn) return;
    setState(() => _isJoiningRoom = true);
    try {
      final left = await _service.leaveChatRoom(
        token: auth.token,
        roomId: widget.roomId,
      );
      if (!mounted) return;
      setState(() {
        _roomMembershipRevision += 1;
        _roomSnapshot = left;
        _isJoinedRoom = false;
      });
      _disconnectChat();
      _showMessage('已退出聊天室');
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        error is InteractionServiceException ? error.message : '退出失败',
      );
    } finally {
      if (mounted) setState(() => _isJoiningRoom = false);
    }
  }

  Future<void> _openMessageSearchSheet() async {
    final token = context.read<InteractionAuthProvider>().token;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _ChatHistorySearchSheet(
        service: _service,
        roomId: widget.roomId,
        token: token,
      ),
    );
  }

  Future<void> _openUserProfile(ChatMessage message) async {
    await _openUserProfileById(
      userId: message.user.id,
      nickname: message.user.nickname,
      avatarUrl: message.user.avatarUrl,
    );
  }

  Future<void> _openMemberProfile(ChatRoomMember member) async {
    await _openUserProfileById(
      userId: member.id,
      nickname: member.nickname,
      avatarUrl: member.avatarUrl,
    );
  }

  Future<void> _openUserProfileById({
    required int userId,
    required String nickname,
    required String avatarUrl,
  }) async {
    final auth = context.read<InteractionAuthProvider>();
    UserProfile? profile;
    try {
      profile = await _service.fetchUserProfile(
        userId: userId,
        token: auth.token,
      );
    } catch (_) {
      if (mounted) _showMessage('用户资料加载失败');
      return;
    }
    if (!mounted) return;
    final loadedProfile = profile;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _UserProfileSheet(
        profile: loadedProfile,
        isSelf: auth.user?.id == loadedProfile.user.id,
        onPrivateChat: auth.user?.id == loadedProfile.user.id
            ? null
            : () {
                Navigator.pop(sheetContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PrivateChatScreen(
                      peer: InteractionUserBrief(
                        id: loadedProfile.user.id,
                        nickname: loadedProfile.user.nickname.isEmpty
                            ? nickname
                            : loadedProfile.user.nickname,
                        avatarUrl: loadedProfile.user.avatarUrl.isEmpty
                            ? avatarUrl
                            : loadedProfile.user.avatarUrl,
                      ),
                    ),
                  ),
                );
              },
        onFollowChanged: (follow) async {
          final next = await _service.followUser(
            token: auth.token,
            userId: loadedProfile.user.id,
            follow: follow,
          );
          if (mounted) _showMessage(follow ? '已关注' : '已取消关注');
          return next;
        },
      ),
    );
  }

  Future<void> _openMessageActions(ChatMessage message) async {
    _inputFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('引用回复'),
              onTap: () => Navigator.pop(context, 'reply'),
            ),
            ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: Text(
                '@${message.user.nickname.trim().isEmpty ? 'Ta' : message.user.nickname}',
              ),
              onTap: () => Navigator.pop(context, 'mention'),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: const Text('查看主页'),
              onTap: () => Navigator.pop(context, 'profile'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await _copyMessage(message);
      return;
    }
    if (action == 'reply') {
      _quoteMessage(message);
      return;
    }
    if (action == 'mention') {
      _insertMention(message.user.nickname);
      return;
    }
    if (action == 'profile') {
      await _openUserProfile(message);
    }
  }

  Future<void> _copyMessage(ChatMessage message) async {
    final text = _copyableMessageText(message);
    if (text.isEmpty) {
      _showMessage('这条消息没有可复制的内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _showMessage('已复制');
  }

  String _copyableMessageText(ChatMessage message) {
    final content = message.content.trim();
    if (content.isNotEmpty && content != '语音消息') return content;
    final share = message.share;
    final shareTitle = share['title']?.toString().trim() ?? '';
    if (shareTitle.isNotEmpty) return shareTitle;
    if (message.mediaUrl.trim().isNotEmpty) return message.mediaUrl.trim();
    return content;
  }

  void _quoteMessage(ChatMessage message) {
    setState(() => _pendingAttachment = _PendingChatAttachment.reply(message));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocusNode.requestFocus();
    });
  }

  @override
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  String _chatError(String error) {
    return switch (error) {
      'level_required_chat_image' => 'Lv3 解锁聊天室图片消息',
      'level_required_chat_sticker' => 'Lv4 解锁表情包快捷发送',
      'profile_required' => '请先设置头像和昵称后再发言',
      'media_url_invalid' => '请输入有效的图片 URL',
      'content_invalid' => '消息内容不能为空或过长',
      'chat_keyword_blocked' => '消息包含违规内容，已被拦截',
      'chat_keyword_temp_ban' => '违规次数过多，账号已封禁 1 天',
      'chat_keyword_permanent_ban' => '多次违规，账号已永久封禁',
      'account_banned' => '账号已被封禁',
      'chat_room_join_required' => '加入聊天室后才能发言',
      _ => '消息发送失败',
    };
  }
}
