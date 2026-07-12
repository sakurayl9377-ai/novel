part of 'chat_room_screen.dart';

class _WechatChatComposer extends StatelessWidget {
  const _WechatChatComposer({
    required this.controller,
    required this.inputFocusNode,
    required this.canChat,
    required this.hasDraft,
    required this.voiceInputMode,
    required this.isRecordingVoice,
    required this.isSendingVoice,
    required this.voiceRecordSeconds,
    required this.voiceReleaseAction,
    required this.pendingAttachment,
    required this.onClearPending,
    required this.onEnsureCanChat,
    required this.onSend,
    required this.onSticker,
    required this.onMore,
    required this.onToggleVoiceMode,
    required this.onVoiceRecordStart,
    required this.onVoiceRecordActionChanged,
    required this.onVoiceRecordEnd,
    required this.mentionSuggestions,
    required this.onMentionSelected,
  });

  final TextEditingController controller;
  final FocusNode inputFocusNode;
  final bool canChat;
  final bool hasDraft;
  final bool voiceInputMode;
  final bool isRecordingVoice;
  final bool isSendingVoice;
  final int voiceRecordSeconds;
  final _VoiceReleaseAction voiceReleaseAction;
  final _PendingChatAttachment? pendingAttachment;
  final VoidCallback onClearPending;
  final VoidCallback onEnsureCanChat;
  final VoidCallback onSend;
  final VoidCallback onSticker;
  final VoidCallback onMore;
  final VoidCallback onToggleVoiceMode;
  final Future<void> Function() onVoiceRecordStart;
  final ValueChanged<_VoiceReleaseAction> onVoiceRecordActionChanged;
  final Future<void> Function(_VoiceReleaseAction action) onVoiceRecordEnd;
  final List<ChatRoomMember> mentionSuggestions;
  final ValueChanged<ChatRoomMember> onMentionSelected;

  @override
  Widget build(BuildContext context) {
    final showSend = hasDraft && !voiceInputMode;
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: const BoxDecoration(
            color: Color(0xFFF7F8FA),
            border: Border(top: BorderSide(color: AppTheme.dividerColor)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!voiceInputMode && mentionSuggestions.isNotEmpty) ...[
                _MentionSuggestionsBar(
                  members: mentionSuggestions,
                  onSelected: onMentionSelected,
                ),
                const SizedBox(height: 8),
              ],
              if (pendingAttachment != null) ...[
                _PendingAttachmentBar(
                  attachment: pendingAttachment!,
                  onClear: onClearPending,
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  _ChatToolbarIcon(
                    tooltip: voiceInputMode ? '切回键盘' : '语音',
                    icon: isSendingVoice
                        ? Icons.hourglass_top_rounded
                        : voiceInputMode
                        ? Icons.keyboard_alt_outlined
                        : Icons.keyboard_voice_outlined,
                    iconColor: isRecordingVoice
                        ? const Color(0xFFE84B5C)
                        : const Color(0xFF526071),
                    onPressed: isSendingVoice ? null : onToggleVoiceMode,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: voiceInputMode
                        ? _HoldToTalkButton(
                            canChat: canChat,
                            isRecording: isRecordingVoice,
                            isSending: isSendingVoice,
                            action: voiceReleaseAction,
                            onEnsureCanChat: onEnsureCanChat,
                            onStart: onVoiceRecordStart,
                            onActionChanged: onVoiceRecordActionChanged,
                            onEnd: onVoiceRecordEnd,
                          )
                        : GestureDetector(
                            onTap: canChat ? null : onEnsureCanChat,
                            child: TextField(
                              controller: controller,
                              focusNode: inputFocusNode,
                              readOnly: !canChat,
                              minLines: 1,
                              maxLines: 4,
                              textInputAction: TextInputAction.send,
                              decoration: InputDecoration(
                                hintText: canChat ? '输入消息' : '设置头像昵称后发言',
                                filled: true,
                                fillColor: Colors.white,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFE2E5EA),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFE2E5EA),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(
                                    color: AppTheme.primaryColor,
                                  ),
                                ),
                              ),
                              onSubmitted: (_) => onSend(),
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  _ChatToolbarIcon(
                    tooltip: '表情',
                    icon: Icons.add_reaction_outlined,
                    onPressed: onSticker,
                  ),
                  const SizedBox(width: 4),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: showSend
                        ? SizedBox(
                            key: const ValueKey('send'),
                            height: 42,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              onPressed: onSend,
                              icon: const Icon(Icons.send_rounded, size: 17),
                              label: const Text('发送'),
                            ),
                          )
                        : _ChatToolbarIcon(
                            key: const ValueKey('plus'),
                            tooltip: '更多',
                            icon: Icons.add_circle_outline_rounded,
                            onPressed: onMore,
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MentionSuggestionsBar extends StatelessWidget {
  const _MentionSuggestionsBar({
    required this.members,
    required this.onSelected,
  });

  final List<ChatRoomMember> members;
  final ValueChanged<ChatRoomMember> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: members.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final member = members[index];
          return ActionChip(
            avatar: _TinyAvatar(
              name: member.nickname,
              imageUrl: member.avatarUrl,
            ),
            label: Text(
              member.nickname.isEmpty ? '用户' : member.nickname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => onSelected(member),
          );
        },
      ),
    );
  }
}

class _HoldToTalkButton extends StatelessWidget {
  const _HoldToTalkButton({
    required this.canChat,
    required this.isRecording,
    required this.isSending,
    required this.action,
    required this.onEnsureCanChat,
    required this.onStart,
    required this.onActionChanged,
    required this.onEnd,
  });

  final bool canChat;
  final bool isRecording;
  final bool isSending;
  final _VoiceReleaseAction action;
  final VoidCallback onEnsureCanChat;
  final Future<void> Function() onStart;
  final ValueChanged<_VoiceReleaseAction> onActionChanged;
  final Future<void> Function(_VoiceReleaseAction action) onEnd;

  @override
  Widget build(BuildContext context) {
    final label = isSending
        ? '发送中...'
        : isRecording
        ? switch (action) {
            _VoiceReleaseAction.cancel => '松开 取消',
            _VoiceReleaseAction.transcribe => '松开 转文字',
            _VoiceReleaseAction.send => '松开 发送',
          }
        : '按住 说话';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: canChat ? null : onEnsureCanChat,
      onLongPressStart: (_) {
        if (!canChat) {
          onEnsureCanChat();
          return;
        }
        if (!isSending) unawaited(onStart());
      },
      onLongPressMoveUpdate: (details) {
        if (!isRecording) return;
        onActionChanged(
          _voiceActionForPosition(context, details.globalPosition),
        );
      },
      onLongPressEnd: (details) {
        if (!isRecording) return;
        final nextAction = _voiceActionForPosition(
          context,
          details.globalPosition,
        );
        unawaited(onEnd(nextAction));
      },
      onLongPressCancel: () {
        if (isRecording) unawaited(onEnd(_VoiceReleaseAction.cancel));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isRecording
              ? const Color(0xFFE8EAEE)
              : canChat
              ? Colors.white
              : const Color(0xFFF0F2F5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isRecording
                ? const Color(0xFFC8CDD6)
                : const Color(0xFFE2E5EA),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: canChat ? AppTheme.textPrimary : AppTheme.textHint,
            fontSize: 17,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _JoinChatRoomBar extends StatelessWidget {
  const _JoinChatRoomBar({
    required this.isLoading,
    required this.canEnter,
    required this.minLevel,
    required this.onJoin,
  });

  final bool isLoading;
  final bool canEnter;
  final int minLevel;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final label = canEnter
        ? '加入聊天室'
        : minLevel > 0
        ? 'Lv$minLevel 可加入'
        : '暂不可加入';
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppTheme.dividerColor)),
        ),
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: isLoading || !canEnter ? null : onJoin,
            icon: isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: Text(label),
          ),
        ),
      ),
    );
  }
}

class _VoiceRecordingOverlay extends StatelessWidget {
  const _VoiceRecordingOverlay({required this.seconds, required this.action});

  final int seconds;
  final _VoiceReleaseAction action;

  @override
  Widget build(BuildContext context) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    final isCancel = action == _VoiceReleaseAction.cancel;
    final isTranscribe = action == _VoiceReleaseAction.transcribe;
    final accentColor = isCancel
        ? const Color(0xFFFF5A66)
        : isTranscribe
        ? const Color(0xFF38BDF8)
        : const Color(0xFF67F044);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      color: Colors.black.withValues(alpha: 0.62),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: MediaQuery.sizeOf(context).height * 0.18,
            left: 0,
            right: 0,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 210,
                  height: 96,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withValues(alpha: 0.28),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Center(
                    child: isCancel
                        ? const Icon(
                            Icons.close_rounded,
                            size: 42,
                            color: Colors.white,
                          )
                        : isTranscribe
                        ? const Icon(
                            Icons.text_fields_rounded,
                            size: 40,
                            color: Colors.white,
                          )
                        : const _VoiceWaveformBars(),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -1),
                  child: ClipPath(
                    clipper: _VoiceBubbleTailClipper(),
                    child: Container(width: 28, height: 22, color: accentColor),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$minutes:$rest',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 22,
            right: 22,
            bottom: 108,
            child: Row(
              children: [
                Expanded(
                  child: _VoiceDropZone(
                    label: '取消',
                    active: action == _VoiceReleaseAction.cancel,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: _VoiceDropZone(
                    label: '滑到这里 转文字',
                    active: action == _VoiceReleaseAction.transcribe,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 34,
            child: Text(
              isCancel
                  ? '松开 取消'
                  : isTranscribe
                  ? '松开 转文字'
                  : '松开 发送',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceDropZone extends StatelessWidget {
  const _VoiceDropZone({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: 78,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: active ? 0.28 : 0.14),
        borderRadius: const BorderRadius.all(Radius.elliptical(90, 36)),
        border: Border.all(
          color: Colors.white.withValues(alpha: active ? 0.5 : 0.1),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: active ? 17 : 16,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _VoiceWaveformBars extends StatefulWidget {
  const _VoiceWaveformBars();

  @override
  State<_VoiceWaveformBars> createState() => _VoiceWaveformBarsState();
}

class _VoiceWaveformBarsState extends State<_VoiceWaveformBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 760),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bars = [10.0, 18, 28, 38, 48, 56, 46, 34, 24, 42, 54, 48, 34, 22, 14];
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final value = _controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < bars.length; i++)
              Container(
                width: 4,
                height:
                    bars[i] *
                    (0.72 + (((i.isEven ? value : 1 - value) * 0.36))),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C7D2B).withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _VoiceBubbleTailClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _ChatEntranceNotice {
  const _ChatEntranceNotice({required this.user, required this.serial});

  final InteractionUserBrief user;
  final int serial;
}

class _ChatEntranceBanner extends StatelessWidget {
  const _ChatEntranceBanner({required this.notice});

  final _ChatEntranceNotice notice;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, (1 - value) * -18),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFFD36E), Color(0xFFFF8AB6), Color(0xFF6C86FF)],
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF7BAA).withValues(alpha: 0.22),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            InteractionAvatar(
              label: notice.user.nickname,
              imageUrl: notice.user.avatarUrl,
              size: 28,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                'Lv7 ${notice.user.nickname} 闪耀进入聊天室',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  shadows: [Shadow(color: Colors.black26, blurRadius: 6)],
                ),
              ),
            ),
            const Icon(Icons.auto_awesome_rounded, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _ChatToolbarIcon extends StatelessWidget {
  const _ChatToolbarIcon({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.iconColor,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 23,
        child: SizedBox(
          width: 38,
          height: 42,
          child: Icon(
            icon,
            color: iconColor ?? const Color(0xFF526071),
            size: 28,
          ),
        ),
      ),
    );
  }
}

class _PendingAttachmentBar extends StatelessWidget {
  const _PendingAttachmentBar({
    required this.attachment,
    required this.onClear,
  });

  final _PendingChatAttachment attachment;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final share = attachment.share;
    final reply = attachment.reply;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E5EA)),
      ),
      child: Row(
        children: [
          if (share != null)
            _ShareCover(url: share.coverUrl, size: 34)
          else
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.format_quote_rounded,
                color: AppTheme.primaryColor,
                size: 19,
              ),
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  share == null ? '引用 ${reply?.nickname ?? ''}' : '分享收藏',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textHint,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  attachment.fallbackText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

class _ChatPanelAction extends StatelessWidget {
  const _ChatPanelAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 50,
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F7FF),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F4)),
            ),
            child: Icon(icon, color: AppTheme.primaryColor, size: 25),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
