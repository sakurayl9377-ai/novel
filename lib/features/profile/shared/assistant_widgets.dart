part of '../profile_screen.dart';

class _LevelAvatar extends StatelessWidget {
  const _LevelAvatar({required this.user, required this.size});

  final InteractionUser? user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = user?.avatarUrl ?? '';
    final level = (user?.growth.level ?? 1).clamp(1, 7).toInt();
    return _FramedAvatar(avatarUrl: avatarUrl, level: level, size: size);
  }
}

class _MiniAssistantSkin {
  const _MiniAssistantSkin({
    required this.id,
    required this.label,
    required this.imageAsset,
    required this.bodyAsset,
    required this.colors,
    required this.icon,
  });

  final String id;
  final String label;
  final String imageAsset;
  final String bodyAsset;
  final List<Color> colors;
  final IconData icon;
}

class _MiniAssistantDock extends StatelessWidget {
  const _MiniAssistantDock({
    required this.skin,
    required this.botName,
    required this.animation,
    required this.isDragging,
    required this.onTap,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPanCancel,
  });

  final _MiniAssistantSkin skin;
  final String botName;
  final Animation<double> animation;
  final bool isDragging;
  final VoidCallback onTap;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;
  final VoidCallback onPanCancel;

  @override
  Widget build(BuildContext context) {
    final name = botName.trim().isEmpty ? '小樱' : botName.trim();
    final dragProgress = isDragging ? 1.0 : 0.0;
    return Semantics(
      button: true,
      label: name,
      child: GestureDetector(
        onTap: onTap,
        onPanStart: onPanStart,
        onPanUpdate: onPanUpdate,
        onPanEnd: onPanEnd,
        onPanCancel: onPanCancel,
        behavior: HitTestBehavior.translucent,
        child: SizedBox(
          width: _miniAssistantDockWidth,
          height: _miniAssistantDockHeight,
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              final bob = math.sin(animation.value * math.pi * 2) * 4;
              final tilt =
                  math.sin(animation.value * math.pi * 2 + 0.8) * 0.035;
              return Transform.translate(
                offset: Offset(0, bob),
                child: Transform.scale(
                  scale: 1 + dragProgress * 0.045,
                  alignment: Alignment.centerRight,
                  child: Transform.rotate(angle: tilt, child: child),
                ),
              );
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  right: 54,
                  top: 28,
                  child: Opacity(
                    opacity: 0.9,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            skin.colors.first.withValues(alpha: 0.92),
                            skin.colors.last.withValues(alpha: 0.78),
                          ],
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: skin.colors.first.withValues(alpha: 0.24),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: SizedBox(
                        width: 30,
                        height: 30,
                        child: Icon(
                          isDragging
                              ? Icons.open_with_rounded
                              : Icons.chat_bubble_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: 126,
                  height: 150,
                  child: Image.asset(
                    skin.bodyAsset,
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomCenter,
                    errorBuilder: (_, _, _) => Image.asset(
                      skin.imageAsset,
                      fit: BoxFit.contain,
                      alignment: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniAssistantPanel extends StatefulWidget {
  const _MiniAssistantPanel({
    required this.user,
    required this.botName,
    required this.canChangeSkin,
    required this.initialSkinIndex,
    required this.onLoadMessages,
    required this.onSendMessage,
    required this.onSkinChanged,
    required this.onOpenChatRoom,
    required this.onOpenDressUp,
  });

  final InteractionUser? user;
  final String botName;
  final bool canChangeSkin;
  final int initialSkinIndex;
  final Future<List<ChatBotDirectMessage>> Function() onLoadMessages;
  final Future<ChatBotDirectReply> Function(String content) onSendMessage;
  final Future<bool> Function(int index) onSkinChanged;
  final VoidCallback onOpenChatRoom;
  final VoidCallback onOpenDressUp;

  @override
  State<_MiniAssistantPanel> createState() => _MiniAssistantPanelState();
}

class _MiniAssistantPanelState extends State<_MiniAssistantPanel> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _messageScrollController = ScrollController();
  late int _skinIndex;
  late final List<_MiniAssistantMessage> _messages;
  bool _isLoadingHistory = true;
  bool _isSavingSkin = false;
  bool _isSending = false;

  String get _botName =>
      widget.botName.trim().isEmpty ? '小樱' : widget.botName.trim();

  String get _helloText {
    final nickname = widget.user?.nickname.trim();
    final name = nickname == null || nickname.isEmpty ? '你' : nickname;
    return '$name，我在这里待命。想找聊天室，或者随手记一句都可以。';
  }

  @override
  void initState() {
    super.initState();
    _skinIndex = widget.initialSkinIndex
        .clamp(0, _assistantSkins.length - 1)
        .toInt();
    _messages = [_MiniAssistantMessage(text: _helloText, fromUser: false)];
    unawaited(_loadHistory());
  }

  @override
  void dispose() {
    _controller.dispose();
    _messageScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await widget.onLoadMessages();
    if (!mounted) return;
    final messages = history
        .where(
          (item) => item.content.trim().isNotEmpty || item.share.isNotEmpty,
        )
        .map(_MiniAssistantMessage.fromDirectMessage)
        .toList();
    setState(() {
      _isLoadingHistory = false;
      if (messages.isNotEmpty) {
        _messages
          ..clear()
          ..addAll(messages);
      }
    });
    _scrollMessagesToBottom(animated: false);
  }

  Future<void> _selectSkin(int index) async {
    if (!widget.canChangeSkin || _isSavingSkin) return;
    final previous = _skinIndex;
    setState(() {
      _skinIndex = index;
      _isSavingSkin = true;
    });
    final saved = await widget.onSkinChanged(index);
    if (!mounted) return;
    setState(() {
      _isSavingSkin = false;
      if (!saved) _skinIndex = previous;
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;
    _controller.clear();
    setState(() {
      _isSending = true;
      _messages.add(_MiniAssistantMessage(text: text, fromUser: true));
    });
    _scrollMessagesToBottom();
    final reply = await widget.onSendMessage(text);
    if (!mounted) return;
    setState(() {
      _isSending = false;
      _messages.add(
        _MiniAssistantMessage(
          text: reply.reply.isEmpty ? '我在呢。' : reply.reply,
          fromUser: false,
          share: reply.share,
        ),
      );
    });
    _scrollMessagesToBottom();
  }

  void _scrollMessagesToBottom({bool animated = true, int attempts = 4}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_messageScrollController.hasClients) {
        final target = _messageScrollController.position.maxScrollExtent;
        if (animated) {
          _messageScrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        } else {
          _messageScrollController.jumpTo(target);
        }
      }
      if (attempts > 1) {
        Future<void>.delayed(const Duration(milliseconds: 32), () {
          _scrollMessagesToBottom(animated: animated, attempts: attempts - 1);
        });
      }
    });
  }

  Widget _buildDragHeader(_MiniAssistantSkin skin) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 44,
            height: 5,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2937).withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: skin.colors.last.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                skin.imageAsset,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _botName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    skin.label,
                    style: TextStyle(
                      color: skin.colors.first,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            if (widget.canChangeSkin)
              IconButton(
                tooltip: '换装',
                onPressed: widget.onOpenDressUp,
                icon: const Icon(Icons.checkroom_outlined),
              ),
          ],
        ),
        if (widget.canChangeSkin) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _assistantSkins.length,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final item = _assistantSkins[index];
                final selected = index == _skinIndex;
                return ChoiceChip(
                  selected: selected,
                  label: Text(item.label),
                  avatar: CircleAvatar(
                    backgroundColor: Colors.white.withValues(alpha: 0.75),
                    backgroundImage: AssetImage(item.imageAsset),
                  ),
                  selectedColor: item.colors.last.withValues(alpha: 0.55),
                  onSelected: _isSavingSkin
                      ? null
                      : (_) => unawaited(_selectSkin(index)),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final skin =
        _assistantSkins[_skinIndex
            .clamp(0, _assistantSkins.length - 1)
            .toInt()];
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: Material(
        color: const Color(0xFFFAFAFF),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: _buildDragHeader(skin),
              ),
              const Divider(height: 1, color: AppTheme.dividerColor),
              Expanded(child: _buildMessageList(skin)),
              _buildComposer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(_MiniAssistantSkin skin) {
    return Scrollbar(
      controller: _messageScrollController,
      child: ListView(
        controller: _messageScrollController,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          if (_isLoadingHistory)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          for (final message in _messages)
            _MiniAssistantBubble(message: message, skin: skin),
          if (_isSending)
            _MiniAssistantBubble(
              message: const _MiniAssistantMessage(
                text: '我想一下，很快回来。',
                fromUser: false,
              ),
              skin: skin,
            ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFFAFAFF),
        border: Border(top: BorderSide(color: AppTheme.dividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: widget.onOpenChatRoom,
                icon: const Icon(Icons.forum_outlined, size: 18),
                label: const Text('找聊天室'),
              ),
              if (widget.canChangeSkin)
                OutlinedButton.icon(
                  onPressed: _isSavingSkin
                      ? null
                      : () => unawaited(
                          _selectSkin(
                            (_skinIndex + 1) % _assistantSkins.length,
                          ),
                        ),
                  icon: const Icon(Icons.palette_outlined, size: 18),
                  label: Text(_isSavingSkin ? '保存中' : '换肤'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => unawaited(_send()),
                  decoration: const InputDecoration(
                    hintText: '和她说一句',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: '发送',
                onPressed: _isSending ? null : () => unawaited(_send()),
                icon: _isSending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniAssistantBubble extends StatelessWidget {
  const _MiniAssistantBubble({required this.message, required this.skin});

  final _MiniAssistantMessage message;
  final _MiniAssistantSkin skin;

  @override
  Widget build(BuildContext context) {
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 260),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: message.fromUser ? AppTheme.primaryColor : skin.colors.last,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message.text,
            style: TextStyle(
              color: message.fromUser ? Colors.white : AppTheme.textPrimary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          if (message.share.isNotEmpty) ...[
            const SizedBox(height: 8),
            _MiniAssistantShareCard(share: message.share),
          ],
        ],
      ),
    );
    if (message.fromUser) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: skin.colors.last.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset(
            skin.imageAsset,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(child: bubble),
      ],
    );
  }
}

class _MiniAssistantMessage {
  const _MiniAssistantMessage({
    required this.text,
    required this.fromUser,
    this.share = const {},
  });

  factory _MiniAssistantMessage.fromDirectMessage(
    ChatBotDirectMessage message,
  ) {
    return _MiniAssistantMessage(
      text: message.content,
      fromUser: message.fromUser,
      share: message.share,
    );
  }

  final String text;
  final bool fromUser;
  final Map<String, dynamic> share;
}

class _MiniAssistantShareCard extends StatelessWidget {
  const _MiniAssistantShareCard({required this.share});

  final Map<String, dynamic> share;

  @override
  Widget build(BuildContext context) {
    final title = _profileStringOf(share['title']).isEmpty
        ? '去看看'
        : _profileStringOf(share['title']);
    final subtitle = _profileStringOf(share['subtitle']).isEmpty
        ? '小樱帮你找到了'
        : _profileStringOf(share['subtitle']);
    final cover = _profileStringOf(share['coverUrl']);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openMiniAssistantShare(context, share),
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: cover.isEmpty
                  ? Container(
                      width: 44,
                      height: 44,
                      color: const Color(0xFFF0F6FF),
                      child: const Icon(
                        Icons.menu_book_outlined,
                        color: AppTheme.primaryColor,
                      ),
                    )
                  : Image.network(
                      cover,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 44,
                        height: 44,
                        color: const Color(0xFFF0F6FF),
                        child: const Icon(
                          Icons.menu_book_outlined,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
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
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}

void _openMiniAssistantShare(BuildContext context, Map<String, dynamic> share) {
  final type = _profileStringOf(share['type']);
  final itemId = _profileStringOf(share['itemId']);
  final title = _profileStringOf(share['title']);
  if (type == LibraryItemType.novel.value) {
    final query = _profileStringOf(share['query']).isNotEmpty
        ? _profileStringOf(share['query'])
        : title.isNotEmpty
        ? title
        : itemId;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          autofocus: false,
          initialKeyword: query,
          autoOpenFirst: share['autoOpenFirst'] == true,
        ),
      ),
    );
    return;
  }
  if (type == LibraryItemType.anime.value) {
    final id = int.tryParse(itemId) ?? 0;
    if (id > 0) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AnimeDetailScreen(animeId: id, title: title),
        ),
      );
      return;
    }
  }
  if (type == LibraryItemType.manga.value && itemId.isNotEmpty) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MangaDetailScreen(mangaId: itemId, title: title),
      ),
    );
  }
}

String _profileStringOf(dynamic value) {
  return value?.toString().trim() ?? '';
}
