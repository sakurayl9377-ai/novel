part of 'chat_room_screen.dart';

class _ChatMessageFrame extends StatelessWidget {
  const _ChatMessageFrame({
    required this.message,
    required this.user,
    required this.source,
    required this.isSentByMe,
    required this.animation,
    required this.onMessageLongPress,
    required this.onAvatarTap,
    required this.onAvatarLongPress,
    required this.child,
  });

  final chat_core.Message message;
  final chat_core.User? user;
  final ChatMessage? source;
  final bool isSentByMe;
  final Animation<double> animation;
  final VoidCallback onMessageLongPress;
  final VoidCallback onAvatarTap;
  final VoidCallback onAvatarLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final displayName = user?.name?.trim().isNotEmpty == true
        ? user!.name!.trim()
        : '用户';
    final avatar = _ChatAvatar(
      name: displayName,
      imageUrl: user?.imageSource?.trim() ?? '',
      assetPath: source?.user.avatarAsset ?? '',
      onTap: onAvatarTap,
      onLongPress: onAvatarLongPress,
    );
    final showAdminBadge =
        source?.user.badges.any((badge) => badge.isRainbowAdmin) == true;
    final content = Flexible(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: onMessageLongPress,
        child: Column(
          crossAxisAlignment: isSentByMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF7A8494),
                        fontSize: 12,
                        height: 1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (showAdminBadge) ...[
                    const SizedBox(width: 5),
                    const _RainbowAdminBadge(),
                  ],
                ],
              ),
            ),
            child,
            const SizedBox(height: 4),
            Text(
              _formatChatMessageTime(message.resolvedTime),
              style: TextStyle(
                color: const Color(0xFF8A94A6).withValues(alpha: 0.9),
                fontSize: 11,
                height: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );

    return SizeTransition(
      sizeFactor: animation,
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisAlignment: isSentByMe
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: isSentByMe
              ? [content, const SizedBox(width: 8), avatar]
              : [avatar, const SizedBox(width: 8), content],
        ),
      ),
    );
  }
}

class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar({
    required this.name,
    required this.imageUrl,
    this.assetPath = '',
    required this.onTap,
    required this.onLongPress,
  });

  final String name;
  final String imageUrl;
  final String assetPath;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    const size = 36.0;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: assetPath.isNotEmpty
              ? Image.asset(
                  assetPath,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, _, _) => Image.asset(
                    defaultInteractionAvatarAsset,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
                )
              : imageUrl.isEmpty
              ? Image.asset(
                  defaultInteractionAvatarAsset,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                )
              : Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Image.asset(
                    defaultInteractionAvatarAsset,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ChatTextMessage extends StatelessWidget {
  const _ChatTextMessage({
    required this.message,
    required this.source,
    required this.isSentByMe,
  });

  final chat_core.TextMessage message;
  final ChatMessage? source;
  final bool isSentByMe;

  @override
  Widget build(BuildContext context) {
    final isSticker = source?.type == 'sticker';
    final share = source?.share ?? const <String, dynamic>{};
    final file = source?.metadata['file'];
    final reply = source?.reply ?? const <String, dynamic>{};
    final chatBubble = isSticker ? '' : source?.chatBubble ?? '';
    final sticker = isSticker ? _stickerById(source?.content ?? '') : null;
    final bubbleColors = chatBubble.isEmpty
        ? null
        : _chatBubbleColors(chatBubble);
    final hasCustomBubble = bubbleColors != null;
    if (source?.type == 'share' && share.isNotEmpty) {
      return _ShareMessageCard(
        share: share,
        note: source?.content ?? '',
        isSentByMe: isSentByMe,
        chatBubble: source?.chatBubble ?? '',
      );
    }
    if (source?.type == 'file' && file is Map) {
      return _FileMessageCard(
        file: file.cast<String, dynamic>(),
        isSentByMe: isSentByMe,
      );
    }
    return Container(
      constraints: BoxConstraints(maxWidth: isSticker ? 112 : 230),
      padding: EdgeInsets.symmetric(
        horizontal: isSticker ? 10 : 13,
        vertical: isSticker ? 10 : 9,
      ),
      decoration: BoxDecoration(
        color: isSticker
            ? Colors.white
            : hasCustomBubble
            ? null
            : isSentByMe
            ? AppTheme.primaryColor
            : Colors.white,
        gradient: hasCustomBubble
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: bubbleColors,
              )
            : null,
        borderRadius: BorderRadius.circular(8),
        border: isSticker
            ? Border.all(color: AppTheme.dividerColor)
            : isSentByMe || hasCustomBubble
            ? null
            : Border.all(color: AppTheme.dividerColor),
        boxShadow: isSticker
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 14,
                  offset: const Offset(0, 7),
                ),
              ]
            : hasCustomBubble
            ? [
                BoxShadow(
                  color: bubbleColors.last.withValues(alpha: 0.22),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reply.isNotEmpty && !isSticker) ...[
            _ReplyQuoteBlock(reply: reply, light: isSentByMe),
            const SizedBox(height: 7),
          ],
          if (sticker != null)
            _ChatStickerPreview(sticker: sticker, size: 72)
          else
            Text(
              message.text,
              style: TextStyle(
                color: isSentByMe || hasCustomBubble
                    ? Colors.white
                    : AppTheme.textPrimary,
                fontSize: 16,
                height: 1.32,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatAudioMessage extends StatefulWidget {
  const _ChatAudioMessage({
    required this.message,
    required this.source,
    required this.isSentByMe,
    required this.service,
    required this.token,
    required this.onQuote,
  });

  final chat_core.AudioMessage message;
  final ChatMessage? source;
  final bool isSentByMe;
  final InteractionService service;
  final String token;
  final ValueChanged<ChatMessage> onQuote;

  @override
  State<_ChatAudioMessage> createState() => _ChatAudioMessageState();
}

class _ChatAudioMessageState extends State<_ChatAudioMessage> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  bool _useSpeaker = true;
  bool _isTranscribing = false;
  bool _isPreparingAudio = false;
  String _transcriptText = '';

  @override
  void initState() {
    super.initState();
    _transcriptText = _chatAudioTranscript(widget.message.text);
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
  }

  @override
  void didUpdateWidget(covariant _ChatAudioMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.text != widget.message.text ||
        oldWidget.message.source != widget.message.source) {
      _transcriptText = _chatAudioTranscript(widget.message.text);
      if (_isPlaying) {
        unawaited(_player.stop());
        _isPlaying = false;
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }
    if (_isPreparingAudio) return;
    setState(() => _isPreparingAudio = true);
    try {
      await _applyAudioRoute();
      await _player.stop();
      await _player.play(UrlSource(widget.message.source));
      if (mounted) setState(() => _isPlaying = true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('语音播放失败，请稍后重试')));
    } finally {
      if (mounted) setState(() => _isPreparingAudio = false);
    }
  }

  Future<void> _toggleAudioRoute() async {
    setState(() => _useSpeaker = !_useSpeaker);
    await _applyAudioRoute();
  }

  Future<void> _applyAudioRoute() {
    final route = _useSpeaker
        ? AudioContextConfigRoute.speaker
        : AudioContextConfigRoute.earpiece;
    return _player.setAudioContext(AudioContextConfig(route: route).build());
  }

  Future<void> _transcribe() async {
    if (_isTranscribing || widget.token.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _isTranscribing = true);
    try {
      final text = await widget.service.transcribeChatAudio(
        token: widget.token,
        mediaUrl: widget.message.source,
      );
      if (!mounted) return;
      setState(() => _transcriptText = text);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(text.isEmpty ? '没有识别到语音内容' : '已转成文字')),
        );
    } catch (error) {
      if (!mounted) return;
      final message = error is InteractionServiceException
          ? error.message
          : '语音转文字失败';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _isTranscribing = false);
    }
  }

  Future<void> _openAudioActions() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final source = widget.source;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF333333),
      showDragHandle: false,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
          child: Wrap(
            alignment: WrapAlignment.start,
            runSpacing: 10,
            children: [
              _AudioActionItem(
                icon: Icons.reply_rounded,
                label: '引用',
                onTap: source == null
                    ? null
                    : () => Navigator.pop(context, 'quote'),
              ),
              _AudioActionItem(
                icon: Icons.text_fields_rounded,
                label: '转文字',
                onTap: () => Navigator.pop(context, 'transcribe'),
              ),
              _AudioActionItem(
                icon: _useSpeaker
                    ? Icons.phone_in_talk_rounded
                    : Icons.volume_up_rounded,
                label: _useSpeaker ? '听筒播放' : '扬声器播放',
                onTap: () => Navigator.pop(context, 'route'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'quote' && source != null) {
      widget.onQuote(source);
      return;
    }
    if (action == 'transcribe') {
      await _transcribe();
      return;
    }
    if (action == 'route') {
      await _toggleAudioRoute();
    }
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _chatAudioDuration(
      widget.message.text,
    ).inSeconds.clamp(1, 60).toInt();
    final width = (74 + seconds * 2.7).clamp(92, 190).toDouble();
    final bubbleColor = widget.isSentByMe
        ? const Color(0xFF67F044)
        : Colors.white;
    final foreground = const Color(0xFF111827);
    final borderRadius = BorderRadius.circular(8);
    final orderedChildren = <Widget>[
      Text(
        '$seconds"',
        style: TextStyle(
          color: foreground,
          fontSize: 16,
          height: 1,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(width: 8),
      if (_isPreparingAudio || _isTranscribing)
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(
              foreground.withValues(alpha: 0.74),
            ),
          ),
        )
      else
        _ChatVoiceWaveIcon(
          active: _isPlaying,
          color: foreground.withValues(alpha: 0.82),
          reverse: !widget.isSentByMe,
        ),
    ];
    final audioBubble = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_toggle()),
        onLongPress: () {
          FocusManager.instance.primaryFocus?.unfocus();
          unawaited(_openAudioActions());
        },
        borderRadius: borderRadius,
        child: Container(
          width: width,
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: borderRadius,
            border: widget.isSentByMe
                ? null
                : Border.all(color: AppTheme.dividerColor),
            boxShadow: widget.isSentByMe
                ? [
                    BoxShadow(
                      color: const Color(0xFF42D633).withValues(alpha: 0.18),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: widget.isSentByMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: widget.isSentByMe
                ? orderedChildren
                : orderedChildren.reversed.toList(),
          ),
        ),
      ),
    );
    final transcript = _transcriptText.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.isSentByMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        audioBubble,
        if (transcript.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.dividerColor),
            ),
            child: Text(
              transcript,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                height: 1.35,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AudioActionItem extends StatelessWidget {
  const _AudioActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return SizedBox(
      width: 88,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: enabled ? Colors.white : Colors.white38,
                size: 27,
              ),
              const SizedBox(height: 7),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? Colors.white : Colors.white38,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatVoiceWaveIcon extends StatefulWidget {
  const _ChatVoiceWaveIcon({
    required this.active,
    required this.color,
    required this.reverse,
  });

  final bool active;
  final Color color;
  final bool reverse;

  @override
  State<_ChatVoiceWaveIcon> createState() => _ChatVoiceWaveIconState();
}

class _ChatVoiceWaveIconState extends State<_ChatVoiceWaveIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _ChatVoiceWaveIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bars = [7.0, 13, 18, 12];
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final value = widget.active ? _controller.value : 0.34;
        final children = [
          for (var i = 0; i < bars.length; i++)
            Container(
              width: 3,
              height:
                  bars[i] * (0.74 + ((i.isEven ? value : 1 - value) * 0.32)),
              margin: const EdgeInsets.symmetric(horizontal: 1.4),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
        ];
        return SizedBox(
          width: 24,
          height: 22,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: widget.reverse ? children.reversed.toList() : children,
          ),
        );
      },
    );
  }
}
